local Logger = require("core.logger")
local Shell = require("utils.shell")
local Timer = require("utils.timer")
local APK = require("managers.apk")
local Auth = require("managers.auth")

-- Injects a `.ROBLOSECURITY` token into a clone's WebView cookie DB (SQLite), so the
-- chosen account becomes logged in on that clone without going through the browser.
--
-- Target DB: <Auth.getBaseDir()>/app_webview/Default/Cookies. If the default path is
-- missing (modded/"Lite" clones keep it elsewhere) we search a few levels deep under
-- the same base directory.
--
-- sqlite3 note: the `su` shell resets PATH, so a Termux-installed sqlite3 is usually
-- NOT reachable as plain `sqlite3`. We resolve it explicitly (full Termux path +
-- LD_LIBRARY_PATH) and run every command through that resolved runner.
--
-- Safety: the app is force-stopped first (a running WebView holds the DB / may rewrite
-- it), the DB is backed up before writing, and every write is verified afterwards.
-- Login/other cookies are left untouched apart from the .ROBLOSECURITY row.

local CookieInjector = {}

-- Termux default prefix (PATH + lib dir for the dynamically-linked sqlite3).
local TERMUX_PREFIX = "/data/data/com.termux/files/usr"
local TERMUX_SQLITE = TERMUX_PREFIX .. "/bin/sqlite3"

-- Non-empty printable token (trimmed, no line breaks / control chars).
local function validToken(token)
    if not token or type(token) ~= "string" then return false end
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    if token == "" or #token > 2048 then return false end
    if token:find("[\n\r\0'\" ]") then return false end
    return true
end

local function quote(path)
    path = path:gsub("'", "'\\''")
    return "'" .. path .. "'"
end

-- Run a shell command (root, timeouts applied) and return its trimmed output, or nil
-- if the exec itself failed.
local function exec(cmd)
    local ok, _, out = pcall(function() return Shell.exec(cmd) end)
    if not ok or not out then return nil end
    return out:gsub("\n+$", "")
end

local function existsFile(path)
    local out = exec(string.format("[ -f %s ] && echo AE_YES || echo AE_NO", quote(path)))
    if not out then return nil end
    return out:find("AE_YES", 1, true) ~= nil
end

-- Whether the pre-inject FULL native reset (pm clear + seed launch) is enabled.
-- Default ON: mirrors the known-good "fresh clone" condition. Override off via
-- `wipeBeforeInject = false` in config/config.lua when the clone data must be kept.
local function wantWipe()
    local ok, cfg = pcall(require, "core.config")
    if ok and cfg and cfg.get then
        local g = cfg.get()
        if g and g.wipeBeforeInject ~= nil then return g.wipeBeforeInject == true end
    end
    return true
end

-- WebKit/Chrome stores UTC timestamps as microseconds since 1601-01-01 (our era means
-- we must add the 1970-1601 offset to a unix epoch before scaling to µs).
local WEBKIT_EPOCH_OFFSET = 11644473600 -- seconds between 1601-01-01 and 1970-01-01

local function webkitNow()
    return tostring((os.time() + WEBKIT_EPOCH_OFFSET) * 1000000)
end

-- Resolve a runnable `curl` (Termux install preferred; the `su` shell has no PATH).
local function resolveCurl()
    local candidates = { TERMUX_PREFIX .. "/bin/curl", "/system/bin/curl", "curl" }
    for _, c in ipairs(candidates) do
        if c == "curl" then
            local sys = exec("[ -x /system/bin/curl ] && echo AE_YES || echo AE_NO")
            if sys and sys:find("AE_YES", 1, true) then return "curl" end
        else
            local out = exec(string.format("[ -x %s ] && echo AE_YES || echo AE_NO", quote(c)))
            if out and out:find("AE_YES", 1, true) then return c end
        end
    end
    return nil
end

-- Resolve a runnable `sqlite3` prefix for this device. The `su` shell does not inherit
-- the Termux PATH, and Shell's `timeout` wrapper would treat a leading `VAR=val` as an
-- argument to timeout (not the inner command), so we probe real candidate runners with
-- a `SELECT 1;` and return the first one that answers from the target DB.
local function resolveSqlite3(db)
    local runners = {}
    -- 1) Termux via `env` (env is a real /system/bin binary, so `timeout` can exec it).
    table.insert(runners, string.format(
        "env PATH=%s/bin:/system/bin:/system/xbin LD_LIBRARY_PATH=%s/lib %s",
        TERMUX_PREFIX, TERMUX_PREFIX, TERMUX_SQLITE
    ))
    -- 2) Termux absolute path (Termux binaries carry a baked-in RUNPATH).
    table.insert(runners, TERMUX_SQLITE)
    -- 3) A ROM that ships its own sqlite3 in the su PATH.
    local sys = exec("[ -x /system/bin/sqlite3 ] && echo AE_YES || echo AE_NO")
    if sys and sys:find("AE_YES", 1, true) then
        table.insert(runners, "sqlite3")
    end

    for _, runner in ipairs(runners) do
        local out = exec(string.format("%s %s \"SELECT 1;\"", runner, quote(db)))
        if out and out:gsub("%s+", "") == "1" then
            Logger.info("CookieInjector: using sqlite runner: " .. runner)
            return runner
        end
    end
    return nil
end

-- Every file named "Cookies" under base (covers app_webview/<profile>/... plus any
-- modded layout). Returns nil when the base dir is unreachable, an (possibly empty)
-- array otherwise. Sorted so the Default profile comes first (injected first).
local function locateCookieDbs(base)
    local out = exec(string.format("find %s -maxdepth 6 -type f -name Cookies 2>/dev/null", quote(base)))
    if not out then return nil end
    local dbs, seen = {}, {}
    for line in (out .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("%s+$", "")
        if line ~= "" and existsFile(line) and not seen[line] then
            seen[line] = true
            dbs[#dbs + 1] = line
        end
    end
    table.sort(dbs)
    return dbs
end

-- Row shape matching the row a real in-app WebView login writes (verified against the
-- working login row dumped from a logged-in clone: host_key keeps the leading dot,
-- expires_utc is WebKit-epoch microseconds far in the future, samesite=-1 is
-- UNSPECIFIED, source_scheme=2 is HttpsOrigin, top_frame_site_key stays empty so the
-- cookie is legacy/unpartitioned and matches any top frame).
local COLUMNS = {
    { col = "creation_utc",    lit = "0" },
    { col = "host_key",        lit = "'.roblox.com'" },
    { col = "name",            lit = "'.ROBLOSECURITY'" },
    { col = "value",           lit = nil }, -- filled with the escaped token
    { col = "path",            lit = "'/'" },
    { col = "expires_utc",     lit = "14380828598000000" }, -- ~year 2056 (WebKit µs)
    { col = "is_secure",       lit = "1" },
    { col = "is_httponly",     lit = "1" },
    { col = "last_access_utc", lit = "0" },
    { col = "priority",        lit = "1" },
    { col = "has_expires",     lit = "1" },
    { col = "is_persistent",   lit = "1" },
    { col = "samesite",        lit = "-1" }, -- UNSPECIFIED
    { col = "top_frame_site_key", lit = "''" }, -- legacy/unpartitioned => matches any top frame
    { col = "source_scheme",      lit = "2" },  -- HttpsOrigin
    { col = "source_port",        lit = "443" },
}

-- Parse `PRAGMA table_info(cookies);` output (lines like `0|host_key|TEXT|1||0`) into
-- { name = {type, notnull, dflt} }. Returns nil when nothing usable was produced.
local function pragmaColumns(out)
    if not out or out == "" then return nil end
    local cols, hasValue = {}, false
    for line in (out .. "\n"):gmatch("(.-)\n") do
        local name, typ, notnull, dflt = line:match("^%d+|([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
        if name then
            cols[name] = { type = typ or "", notnull = (notnull == "1"), dflt = dflt or "" }
            if name == "value" then hasValue = true end
        end
    end
    if not hasValue then return nil end
    return cols
end

-- Type-sized empty literal for an obligatory column that has no default.
local function emptyLiteral(typ)
    typ = (typ or ""):upper()
    if typ:find("TEXT") or typ:find("CHAR") or typ:find("CLOB") then return "''" end
    if typ:find("BLOB") then return "X''" end
    return "0"
end

-- Build (columns, values) for an INSERT that matches the DB's real schema: known
-- cookies columns get their explicit literal, any extra NOT NULL column without a
-- default gets a type-safe empty literal, the rest are omitted (SQLite uses its own
-- defaults). Falls back to the static COLUMNS list when the schema probe fails.
local function buildInsertSpec(runner, db, token, nowLit)
    local tokenLit = "'" .. token:gsub("'", "''") .. "'"

    local schema = pragmaColumns(exec(
        string.format("%s %s \"PRAGMA table_info(cookies);\"", runner, quote(db))
    ))
    if schema then
        local overrides = {}
        for _, c in ipairs(COLUMNS) do
            overrides[c.col] = (c.col == "value") and tokenLit or c.lit
        end
        -- Realistic creation/last-access timestamps (mirrors what a real login writes).
        overrides["creation_utc"] = nowLit
        overrides["last_access_utc"] = nowLit

        local cols, vals = {}, {}
        local needHost, needName, needPath = false, false, false
        for col, info in pairs(schema) do
            if overrides[col] then
                cols[#cols + 1] = col
                vals[#vals + 1] = overrides[col]
                if col == "host_key" then needHost = true end
                if col == "name" then needName = true end
                if col == "path" then needPath = true end
            elseif info.notnull and info.dflt == "" then
                cols[#cols + 1] = col
                vals[#vals + 1] = emptyLiteral(info.type)
            end
        end
        if needHost and needName and needPath and cols[1] then
            return cols, vals
        end
    end
    Logger.warn("CookieInjector: schema cookies tidak terbaca/valid untuk " .. tostring(db) .. ", pakai daftar kolom statis")

    -- Fallback: the full static list (all columns exist on modern Android WebView).
    local cols, vals = {}, {}
    for _, c in ipairs(COLUMNS) do
        if c.col == "creation_utc" or c.col == "last_access_utc" then
            cols[#cols + 1] = c.col
            vals[#vals + 1] = nowLit
        else
            cols[#cols + 1] = c.col
            vals[#vals + 1] = (c.col == "value") and tokenLit or c.lit
        end
    end
    return cols, vals
end

-- Verify a token is still accepted by Roblox before we write anything to the app.
-- Returns (ok, message); ok == true also when curl is unavailable (verify skipped,
-- so an offline device can still inject).
function CookieInjector.verifyRemote(token)
    if not validToken(token) then return false, "Token tidak valid format" end
    local curlBin = resolveCurl()
    if not curlBin then
        return false, "curl tidak ditemukan (pkg install curl) - tidak bisa verifikasi token, inject dibatalkan"
    end

    -- Single curl call: body + HTTP code both on stdout (`-w '\n%{http_code}'`), so no
    -- temp file race (a previous version wrote `-o ...$$.json` then cat it from a NEW
    -- su shell, where `$$` is a different PID -> body always "empty").
    local out = exec(string.format(
        "%s -s -w '\n%%{http_code}' -H 'Cookie: .ROBLOSECURITY=%s' https://users.roblox.com/v1/users/authenticated",
        curlBin, token
    ))
    if not out then
        return false, "Verifikasi remote gagal (curl tidak menghasilkan output - cek jaringan)."
    end

    local body, codeStr = out:match("^(.-)\n(%d+)$")
    if not body then
        body, codeStr = out, out:match("(%d+)$")
    end
    local code = tonumber(codeStr)
    local snippet = (body or ""):gsub("%s+", " "):sub(1, 160)
    if snippet == "" then snippet = "(kosong)" end

    if code == 200 and body and body:find('"name"') and not body:find('"errors"') then
        Logger.info("CookieInjector: token VALID remote (code 200)")
        return true, "Token valid"
    end
    -- Fail closed: anything else is not a valid session. Show what Roblox actually
    -- answered (a dead/rotated token is exactly the silent-login-fail trap we hit).
    return false, string.format(
        "Token DITOLAK/tidak valid di sisi Roblox (HTTP %s). Kemungkinan sesi sudah mati/di-revoke keamanan Roblox. Export ulang dari Chrome lalu verifikasi: curl -s -H \"Cookie: .ROBLOSECURITY=<tok>\" https://users.roblox.com/v1/users/authenticated (harus balas {\"sub\":...,\"name\":...}). Body server: %s",
        tostring(codeStr == "" and "(tak terbaca)" or codeStr), snippet
    )
end

-- Inject `token` into `instance`'s cookie DB. Returns (ok, message).
function CookieInjector.inject(instance, token)
    if not validToken(token) then
        return false, "Token tidak valid (kosong / mengandung karakter control / >2048 char)"
    end

    -- 0) Fail fast when the session is already dead server-side (the silent-login-fail
    --    trap from before), BEFORE force-stopping the app or touching any data. Wrapped
    --    in pcall so any unexpected verify crash can never take down the whole CLI.
    local okRemote, msgRemote = true, "verifikasi remote dilewati (error internal)"
    local okP, a, b = pcall(CookieInjector.verifyRemote, token)
    if okP then
        okRemote, msgRemote = a, b
    else
        Logger.warn("CookieInjector: verifyRemote error: " .. tostring(a))
    end
    if not okRemote then
        Logger.warn("CookieInjector: inject batal - " .. msgRemote)
        return false, msgRemote
    end

    local pkg = instance and instance.package
    if not pkg then return false, "Instance tidak punya package" end
    local base = Auth.getBaseDir(instance)
    if not base then return false, "Tidak bisa tentukan base dir instance" end

    -- 1) FULL native reset (pm clear) + seed launch. A clone that has been logged
    --    in/out many times can carry stale native login anchors (shared_prefs, files,
    --    databases, device-bound session state) that make the relaunched app IGNORE a
    --    perfectly valid injected cookie. `pm clear` returns it to fresh-install state,
    --    then a short SEED launch recreates a pristine WebView cookie store for us to
    --    inject into. This mirrors the known-good "fresh clone" condition.
    APK.forceStop(pkg)
    Timer.sleep(1)
    if wantWipe() then
        Logger.warn("CookieInjector: [RESET] pm clear " .. pkg .. " (hapus state native lama)")
        local clearMsg = exec("pm clear " .. tostring(pkg))
        if not clearMsg then
            return false, "pm clear tidak menghasilkan output (root OK?) - inject dibatalkan."
        end
        if not clearMsg:find("Success", 1, true) then
            Logger.warn("CookieInjector: pm clear output: " .. clearMsg)
            return false, "pm clear gagal (" .. clearMsg:gsub("%s+", " ") .. ") - inject dibatalkan."
        end
        Logger.info("CookieInjector: pm clear OK -> " .. clearMsg)
        Logger.info("CookieInjector: [SEED] launch singkat utk buat ulang cookie store WebView...")
        APK.launch(pkg)
        Timer.sleep(8)
        APK.forceStop(pkg)
        Timer.sleep(1)
        base = Auth.getBaseDir(instance)
    end

    -- 2) Enumerate EVERY Cookies DB under the base dir (a Lite/mod clone can keep its
    --    live WebView profile under a non-"Default" directory; writing only the first
    --    DB found would "succeed" but touch a store the app never reads).
    local dbs = locateCookieDbs(base)
    if dbs == nil then
        return false, "Base dir '" .. base .. "' tidak bisa dibaca (periksa izin root)."
    end
    if #dbs == 0 then
        return false, "Cookies DB tidak ditemukan di '" .. base .. "'. Setelah pm clear seed launch harus bikin store - kalau kosong, seed gagal / cookiePath salah."
    end
    Logger.info("CookieInjector: target " .. #dbs .. " Cookies DB: " .. table.concat(dbs, ", "))

    -- 3) sqlite3 must be resolvable (same runner is used for every DB found).
    local runner = resolveSqlite3(dbs[1])
    if not runner then
        return false, "sqlite3 tidak terpasang / tidak dapat dijalankan. Install: pkg install sqlite (Termux)"
    end

    local stamp = os.date("%Y%m%d-%H%M%S")
    local nowLit = webkitNow()
    local written, failures = {}, {}
    for _, db in ipairs(dbs) do
        -- 4) Backup first (restore point if the token needs to be removed later).
        local backup = db .. ".bak-" .. stamp
        exec("cp -a " .. quote(db) .. " " .. quote(backup))
        Logger.info("CookieInjector: backup -> " .. backup)

        -- 4b) Drop stale WebView transaction files left behind by a force-stopped app.
        -- Chromium re-opens its cookie store in WAL mode and would replay these on
        -- relaunch, shadowing the row we are about to write. Safe to remove while the
        -- app is dead; they are recreated on next open.
        for _, suffix in ipairs({ "-wal", "-shm", "-journal" }) do
            local side = db .. suffix
            local existed = existsFile(side)
            exec("rm -f " .. quote(side))
            Logger.info("CookieInjector: " .. (existed and "hapus stale " or "tidak ada ") .. side)
        end

        -- 5) Remove any stale/half-written `.ROBLOSECURITY` rows first, then INSERT a
        --    single clean row (faulty old rows use host_key="roblox.com" / a non-empty
        --    top_frame_site_key and would only confuse cookie matching).
        local delOut = exec(runner .. " " .. quote(db) .. " \"DELETE FROM cookies WHERE name='.ROBLOSECURITY' AND host_key LIKE '%.roblox.com%';\"")
        if delOut and delOut ~= "" then Logger.info("CookieInjector: delete output: " .. delOut) end
        local cols, vals = buildInsertSpec(runner, db, token, nowLit)
        Logger.info("CookieInjector: kolom yang diisi di " .. db .. " -> " .. table.concat(cols, ","))
        local sql = string.format(
            "INSERT OR REPLACE INTO cookies (%s) VALUES (%s);",
            table.concat(cols, ", "), table.concat(vals, ", ")
        )
        local insertOut = exec(runner .. " " .. quote(db) .. " '" .. sql:gsub("'", "'\\''") .. "'")
        if insertOut and insertOut ~= "" then
            Logger.warn("CookieInjector: sqlite3 output: " .. insertOut)
        else
            Logger.info("CookieInjector: sqlite3 output: (none)")
        end

        -- 6) Fold any WAL data into the main DB. `0|-1|-1` = connection opened the store
        -- outside WAL mode (no files to fold) -> no-op; `1|..` = busy -> one retry.
        local function checkpointIt()
            return exec(runner .. " " .. quote(db) .. " 'PRAGMA wal_checkpoint(FULL);'")
        end
        local walOut = checkpointIt()
        local busy, logFrames = (walOut or ""):match("^(.-)|(.-)|.-$")
        if busy == "1" then
            exec("sleep 0.2")
            walOut = checkpointIt()
            busy, logFrames = (walOut or ""):match("^(.-)|(.-)|.-$")
        end
        if walOut and walOut ~= "" then
            if logFrames == "-1" then
                Logger.info("CookieInjector: wal_checkpoint: " .. walOut .. " -> tidak ada WAL (no-op)")
            elseif busy == "1" then
                Logger.warn("CookieInjector: wal_checkpoint: " .. walOut .. " -> BUSY (WAL belum dilipat)")
            else
                Logger.info("CookieInjector: wal_checkpoint: " .. walOut .. " -> WAL dilipat ke DB utama")
            end
        end

        -- 7) Verify exactly one clean `.ROBLOSECURITY` row is stored AND that its value
        --    survived the shell-roundtrip intact (a truncated/mangled value still ends
        --    up non-empty, which the old `>0` check let through).
        local verify = exec(string.format(
            "%s %s \"SELECT length(value) || '|' || COUNT(*) FROM cookies WHERE name='.ROBLOSECURITY' AND host_key LIKE '%%.roblox.com%%' GROUP BY length(value);\"",
            runner, quote(db)
        ))
        if not verify then
            failures[#failures + 1] = db .. " - verifikasi tidak terbaca (backup: " .. backup .. ")"
        else
            local len, cnt = verify:match("^(%d+)|(%d+)%s*$")
            len = tonumber(len)
            cnt = tonumber(cnt)
            if len == nil or len == 0 or cnt ~= 1 then
                failures[#failures + 1] = db .. " - value tidak tersimpan / baris bukan 1 (verify: " .. tostring(verify) .. ", backup: " .. backup .. ")"
            elseif len ~= #token then
                failures[#failures + 1] = string.format(
                    "%s - INJECT TERPOTONG/RUSAK: tersimpan %d char, asal %d (verify: %s, backup: %s)",
                    db, len, #token, tostring(verify), backup
                )
            else
                written[#written + 1] = db
                Logger.info(string.format(
                    "CookieInjector: DB OK -> %s (len=%d, count=%d)",
                    db, len, cnt
                ))
            end
        end
    end
    Auth.resetCache()

    if #written == 0 then
        return false, "Tidak ada Cookies DB yang berhasil di-inject. Detail:\n- " .. table.concat(failures, "\n- ")
    end

    Logger.info(string.format(
        "CookieInjector: injected %d-char .ROBLOSECURITY into %s across %d Cookies DB",
        #token, pkg, #written
    ))
    local detail = string.format(
        "OK: cookie di-inject ke %s (%d char) di %d Cookies DB.\nDB: %s",
        pkg, #token, #written, table.concat(written, " | ")
    )
    if #failures > 0 then
        detail = detail .. "\n[WARN] Gagal sebagian:\n- " .. table.concat(failures, "\n- ")
    end
    return true, detail
end

-- Debug: dump every cookie row of EVERY Cookies DB under the instance. The
-- `.ROBLOSECURITY` value is shown as its length only (no token leak). Returns
-- (ok, message).
function CookieInjector.dump(instance)
    local pkg = instance and instance.package
    if not pkg then return false, "Instance tidak punya package" end
    local base = Auth.getBaseDir(instance)
    if not base then return false, "Tidak bisa tentukan base dir instance" end

    local dbs = locateCookieDbs(base)
    if dbs == nil then
        return false, "Base dir '" .. base .. "' tidak bisa dibaca (periksa izin root)."
    end
    if #dbs == 0 then
        return false, "Cookies DB tidak ditemukan di '" .. base .. "'. Kalau clone mod/Lite, set per-instance 'cookiePath' di config."
    end

    local runner = resolveSqlite3(dbs[1])
    if not runner then
        return false, "sqlite3 tidak terpasang / tidak dapat dijalankan. Install: pkg install sqlite (Termux)"
    end

    -- Column order from the real schema.
    local colOrder = {}
    local schemaOut = exec(string.format("%s %s \"PRAGMA table_info(cookies);\"", runner, quote(dbs[1])))
    for line in (schemaOut or ""):gmatch("(.-)\n") do
        local name = line:match("^%d+|([^|]+)")
        if name then colOrder[#colOrder + 1] = name end
    end
    if #colOrder == 0 then
        return false, "Tidak bisa baca schema cookies. Output: " .. tostring(schemaOut or "(none)")
    end

    local selectList = {}
    for _, c in ipairs(colOrder) do
        if c == "value" then
            selectList[#selectList + 1] = "length(value) AS value_len"
        else
            selectList[#selectList + 1] = c
        end
    end
    local sql = "SELECT " .. table.concat(selectList, ", ") .. " FROM cookies;"

    local parts = {}
    for _, db in ipairs(dbs) do
        local rowsOut = exec(string.format("%s %s \".mode line\" \"%s\"", runner, quote(db), sql))
        parts[#parts + 1] = "=== " .. db .. " ==="
        if not rowsOut or rowsOut == "" then
            parts[#parts + 1] = "(kosong / tanpa baris)"
        else
            parts[#parts + 1] = rowsOut
        end
    end
    Auth.resetCache()
    Logger.info("CookieInjector: dumped " .. tostring(instance and instance.package or "?") .. " cookie DBs:")
    return true, table.concat(parts, "\n")
end

-- List every Cookies DB under the instance (modded clones may keep a live profile
-- outside app_webview/Default). Returns nil (unreadable) or an array of paths.
function CookieInjector.listDbs(instance)
    local base = Auth.getBaseDir(instance)
    if not base then return nil end
    return locateCookieDbs(base)
end

-- Post-launch probe: READ-ONLY, no network. For every Cookies DB prints the injected
-- row's `len|valuePrefix|count` and whether the stored value still equals the injected
-- token. A DIFFERENT prefix is strong evidence the app's WebView already authenticated
-- (Roblox rotated the session -> login). A SAME prefix is INCONCLUSIVE: a successful
-- device may not rotate within 8s (proven on working device). Also greps the instance
-- data dir (excluding our `.bak-*` backup copies) for any OTHER file holding the token.
-- NOTE: never call this at the same time as a live verifyRemote against the same token
-- while the app is running -- two clients authenticating one session in a row is exactly
-- what triggers Roblox's session-hijack detection (instant logout).
function CookieInjector.probeToken(instance, token)
    local base = Auth.getBaseDir(instance)
    if not base then return "(base dir tidak terbaca)", "NEED_MANUAL_CHECK" end
    local lines = {}
    local dbs = locateCookieDbs(base)
    local tokPrefix = token and token:sub(1, 6) or ""
    local seenRotated, seenSame, seenMissing = false, false, false
    if dbs and #dbs > 0 then
        local runner = resolveSqlite3(dbs[1])
        for _, db in ipairs(dbs) do
            local status = "(sqlite runner tidak ada)"
            if runner then
                local v = exec(string.format(
                    "%s %s \"SELECT length(value) || '##' || substr(value,1,6) || '##' || COUNT(*) FROM cookies WHERE name='.ROBLOSECURITY' AND host_key LIKE '%%.roblox.com%%' GROUP BY length(value), substr(value,1,6);\"",
                    runner, quote(db)
                ))
                v = v and v:gsub("%s+$", "") or ""
                local lenPart, pfx, cntPart = v:match("^(%d+)##(.-)##(%d+)$")
                if lenPart and pfx and cntPart then
                    if pfx == tokPrefix then
                        seenSame = true
                        status = "len=" .. lenPart .. ", prefix=" .. pfx .. "=token, count=" .. cntPart .. " (SAMA dgn inject -> belum rotasi 8s; TIDAK KONKLUSIF - device yg berhasil bisa tanpa rotasi cepat)"
                    else
                        seenRotated = true
                        status = "len=" .. lenPart .. ", prefix=" .. pfx .. "!=token, count=" .. cntPart .. " (BERBEDA -> WebView SUDAH authenticate, Roblox rotasi = app LOGIN terkonfirmasi)"
                    end
                else
                    seenMissing = true
                    status = "tidak ada baris / " .. tostring(v == "" and "(kosong)" or v)
                end
            end
            lines[#lines + 1] = db .. " -> " .. status
        end
    elseif dbs then
        seenMissing = true
        lines[#lines + 1] = "(tidak ada Cookies DB)"
    else
        lines[#lines + 1] = "(base dir tidak bisa dibaca)"
    end

    -- Live store-open check: a PRIMED WebView creates `<db>-wal` the moment its network
    -- / cookie service actually opens the store (Chromium runs cookies in WAL). Absent
    -- post-launch = the app never touched this cookie store -> it can't be a login issue
    -- in the DB, it is happening before the store is even read.
    lines[#lines + 1] = "Live store (apakah WebView app benar-benar membuka cookie store):"
    for _, db in ipairs(dbs) do
        local walPath = db .. "-wal"
        local walSize = existsFile(walPath) and exec("wc -c < " .. quote(walPath) .. " 2>/dev/null") or "0"
        walSize = tostring(walSize or "0"):gsub("%s+", "")
        local state = existsFile(walPath)
            and ("-wal ADA, size=" .. walSize .. " -> WebView MEMBUKA store (cookie dibaca app)")
            or "-wal TIDAK ADA -> WebView BELUM menyentuh cookie store"
        lines[#lines + 1] = "  " .. db .. " " .. state
    end

    local prefix = token and token:sub(1, 30) or ""
    if prefix ~= "" then
        local g = exec(string.format("grep -a -r -l -F %s %s 2>/dev/null | head -n 20", quote(prefix), quote(base)))
        local others = {}
        if g then
            for line in (g .. "\n"):gmatch("(.-)\n") do
                line = line:gsub("%s+$", "")
                if line ~= "" and not line:find(".bak-", 1, true) then
                    others[#others + 1] = line
                end
            end
        end
        if #others > 0 then
            lines[#lines + 1] = "File lain yang berisi token:"
            for _, l in ipairs(others) do
                lines[#lines + 1] = "  " .. l
            end
        else
            lines[#lines + 1] = "File lain berisi token: (tidak ada -> HANYA Cookies DB)"
        end
    end

    -- Verdict: any rotated row wins (auth proven). Otherwise the strongest status left.
    local verdict
    if seenRotated then
        verdict = "LOGIN_CONFIRMED -> rotasi terdeteksi = WebView SUDAH authenticate; akun HARUSNYA sudah masuk."
    elseif seenSame then
        verdict = "COOKIE_OK_NO_USE -> row utuh & belum rotasi 8s (TIDAK KONKLUSIF; device yg berhasil bisa login tanpa rotasi cepat). Cek: buka app & lihat avatar/username."
    elseif seenMissing then
        verdict = "COOKIE_CLEARED -> baris .ROBLOSECURITY hilang/absen dari DB (app menghapus cookie saat boot)."
    else
        verdict = "NEED_MANUAL_CHECK -> state tak terduga; tutup app lalu cek menu 7>3."
    end
    return table.concat(lines, "\n"), verdict
end

-- Schema/version diagnostic for one Cookies DB (used by `--doctor` to compare two devices).
function CookieInjector.dbInfo(db)
    local runner = resolveSqlite3(db)
    if not runner then return "sqlite runner tidak ada" end
    local ver = exec(runner .. " " .. quote(db) .. " 'PRAGMA user_version;'")
    local jmode = exec(runner .. " " .. quote(db) .. " 'PRAGMA journal_mode;'")
    local walSize = "0"
    if existsFile(db .. "-wal") then walSize = exec("wc -c < '" .. (db:gsub("'", "'\\''")) .. "-wal' 2>/dev/null") end
    local cols = {}
    local schemaOut = exec(string.format("%s %s \"PRAGMA table_info(cookies);\"", runner, quote(db)))
    for l in (schemaOut or ""):gmatch("(.-)\n") do
        local name, typ = l:match("^%d+|([^|]+)|([^|]*)")
        if name then cols[#cols + 1] = name .. ":" .. typ end
    end
    return string.format("user_version=%s | journal_mode=%s | wal_size=%s | cols=%d [%s]", tostring(ver or "?"), tostring(jmode or "?"), tostring(walSize or "0"), #cols, table.concat(cols, ","))
end

return CookieInjector