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
    if token:find("[\n\r\0]") then return false end
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

-- First file named "Cookies" found under base (app_webview/Default first, then a
-- shallow search for modded layouts). Returns nil when nothing is found.
local function locateCookieDb(base)
    local default = base .. "/app_webview/Default/Cookies"
    local ok = existsFile(default)
    if ok then return default end
    if ok == nil then return nil end -- base unreadable -> indeterminate

    local out = exec(string.format("find %s -maxdepth 5 -type f -name Cookies 2>/dev/null | head -n 1", quote(base)))
    if out and out ~= "" then return out end
    return nil
end

-- Row shape (subset that exists across WebView versions; checked against the schema).
local COLUMNS = {
    { col = "creation_utc",    lit = "0" },
    { col = "host_key",        lit = "'roblox.com'" },
    { col = "name",            lit = "'.ROBLOSECURITY'" },
    { col = "value",           lit = nil }, -- filled with the escaped token
    { col = "path",            lit = "'/'" },
    { col = "expires_utc",     lit = "4102444800000000" }, -- year 2100 (WebKit µs)
    { col = "is_secure",       lit = "1" },
    { col = "is_httponly",     lit = "1" },
    { col = "last_access_utc", lit = "0" },
    { col = "priority",        lit = "1" },
    { col = "has_expires",     lit = "1" },
    { col = "is_persistent",   lit = "1" },
    { col = "samesite",        lit = "2" },
    { col = "top_frame_site_key", lit = "'https://roblox.com'" }, -- Chrome 123+ NOT NULL
    { col = "source_scheme",      lit = "'secure'" },             -- Chrome 123+ NOT NULL
}

-- Parse `PRAGMA table_info(cookies);` output (lines like `0|host_key|TEXT|1||0`) into
-- { name = {type, notnull, dflt} }. Returns nil when nothing usable was produced.
local function pragmaColumns(out)
    if not out or out == "" then return nil end
    local cols, hasValue = {}, false
    for line in (out .. "\n"):gmatch("(.-)\n") do
        local name, typ, notnull, dflt = line:match("^%d+|([^|]+)|([^|]*)|([^|]*)|([^|]*)$")
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
local function buildInsertSpec(runner, db, token)
    local tokenLit = "'" .. token:gsub("'", "''") .. "'"

    local schema = pragmaColumns(exec(
        string.format("%s %s \"PRAGMA table_info(cookies);\"", runner, quote(db))
    ))
    if schema then
        local overrides = {}
        for _, c in ipairs(COLUMNS) do
            overrides[c.col] = (c.col == "value") and tokenLit or c.lit
        end

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
        cols[#cols + 1] = c.col
        vals[#vals + 1] = (c.col == "value") and tokenLit or c.lit
    end
    return cols, vals
end

-- Inject `token` into `instance`'s cookie DB. Returns (ok, message).
function CookieInjector.inject(instance, token)
    if not validToken(token) then
        return false, "Token tidak valid (kosong / mengandung karakter control / >2048 char)"
    end

    local pkg = instance and instance.package
    if not pkg then return false, "Instance tidak punya package" end
    local base = Auth.getBaseDir(instance)
    if not base then return false, "Tidak bisa tentukan base dir instance" end

    -- 1) Stop the app so the cookie DB is not held open / rewritten by WebView.
    APK.forceStop(pkg)
    Timer.sleep(1)

    -- 2) Locate the Cookies DB.
    local db = locateCookieDb(base)
    if not db then
        return false, "Cookies DB tidak ditemukan di '" .. base .. "'. Kalau clone mod/Lite, set per-instance 'cookiePath' di config."
    end
    Logger.info("CookieInjector: target DB " .. db)

    -- 3) sqlite3 must be resolvable (Termux install usually needs PATH/LD_LIBRARY_PATH).
    local runner = resolveSqlite3(db)
    if not runner then
        return false, "sqlite3 tidak terpasang / tidak dapat dijalankan. Install: pkg install sqlite (Termux)"
    end

    -- 4) Backup first (restore point if the token needs to be removed later).
    local stamp = os.date("%Y%m%d-%H%M%S")
    local backup = db .. ".bak-" .. stamp
    exec("cp -a " .. quote(db) .. " " .. quote(backup))
    Logger.info("CookieInjector: backup -> " .. backup)

    -- 5) INSERT OR REPLACE restricted to the DB's actual columns.
    local cols, vals = buildInsertSpec(runner, db, token)
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

    -- 6) Fold any WAL data into the main DB.
    exec(runner .. " " .. quote(db) .. " 'PRAGMA wal_checkpoint(TRUNCATE);'")

    -- 7) Verify the token is actually stored.
    local verify = exec(string.format(
        "%s %s \"SELECT length(value) FROM cookies WHERE name='.ROBLOSECURITY' AND host_key LIKE '%%roblox.com%%';\"",
        runner, quote(db)
    ))
    Auth.resetCache()
    if not verify then
        return false, "Injeksi mungkin gagal (verifikasi tidak terbaca). Output: " .. tostring(insertOut or "(none)") .. " | Backup: " .. backup
    end
    local len = tonumber((verify:gsub("%s+", "")))
    if len == nil or len == 0 then
        return false, "Injeksi mungkin gagal (value tidak tersimpan). Output: " .. tostring(insertOut or "(none)") .. " | Backup: " .. backup
    end

    Logger.info(string.format(
        "CookieInjector: injected %d-char .ROBLOSECURITY into %s (db=%s, backup=%s)",
        #token, pkg, db, backup
    ))
    return true, string.format(
        "OK: cookie di-inject ke %s (%d char). DB: %s | Backup: %s",
        pkg, #token, db, backup
    )
end

return CookieInjector