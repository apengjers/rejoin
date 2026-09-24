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

-- Resolve a runnable `sqlite3` prefix for this device (the `su` shell does not inherit
-- the Termux PATH). Returns a command prefix string, or nil when sqlite3 is not found.
local function resolveSqlite3()
    -- 1) Present directly in the su environment.
    local which = exec("command -v sqlite3")
    if which and which ~= "" then
        return "sqlite3"
    end
    -- 2) Standard Termux install.
    local ok = exec(string.format("[ -x %s ] && echo AE_YES || echo AE_NO", quote(TERMUX_SQLITE)))
    if ok and ok:find("AE_YES", 1, true) then
        return string.format("PATH=%s/bin:$PATH LD_LIBRARY_PATH=%s/lib sqlite3", TERMUX_PREFIX, TERMUX_PREFIX)
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
}

-- Parse `PRAGMA table_info(cookies);` output (lines like `0|host_key|TEXT|1||0`) into a
-- set of column names. Returns nil when nothing usable was produced.
local function pragmaColumns(out)
    if not out or out == "" then return nil end
    local cols = {}
    for line in (out .. "\n"):gmatch("(.-)\n") do
        local _, _, name = line:find("^%d+|([^|]+)")
        if name then cols[name] = true end
    end
    -- Validate: a real cookies schema must at least expose the value column.
    if not cols.value then return nil end
    return cols
end

-- Build (columns, values) for an INSERT. Tries the DB's real schema first; falls back
-- to the full static COLUMNS list when the schema probe fails or looks unusable.
local function buildInsertSpec(runner, db, token)
    local tokenLit = "'" .. token:gsub("'", "''") .. "'"

    local present = pragmaColumns(exec(
        string.format("%s %s \"PRAGMA table_info(cookies);\"", runner, quote(db))
    ))
    if present then
        local cols, vals = {}, {}
        for _, c in ipairs(COLUMNS) do
            if present[c.col] then
                cols[#cols + 1] = c.col
                vals[#vals + 1] = (c.col == "value") and tokenLit or c.lit
            end
        end
        if cols[1] then
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
    local runner = resolveSqlite3()
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