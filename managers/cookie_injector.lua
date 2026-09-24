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
-- the same base directory. Requires `sqlite3` on the device (`pkg install sqlite`).
--
-- Safety: the app is force-stopped first (a running WebView holds the DB / may rewrite
-- it), the DB is backed up before writing, and every write is verified afterwards.
-- Login/other cookies are left untouched apart from the .ROBLOSECURITY row.

local CookieInjector = {}

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
    return (out or ""):gsub("\n+$", "")
end

local function existsFile(path)
    local out = exec(string.format("[ -f %s ] && echo AE_YES || echo AE_NO", quote(path)))
    if not out then return nil end
    return out:find("AE_YES", 1, true) ~= nil
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

-- Build (columns, values) for an INSERT, restricted to columns present in the schema.
-- Falls back to the full list if the schema probe fails.
local function buildInsertSpec(db, token)
    local tokenLit = "'" .. token:gsub("'", "''") .. "'"
    local present = nil
    local out = exec(string.format("sqlite3 %s \"SELECT name FROM pragma_table_info('cookies');\"", quote(db)))
    if out then
        present = {}
        for line in (out .. "\n"):gmatch("(.-)\n") do
            line = line:gsub("%s+$", "")
            if line ~= "" then present[line] = true end
        end
    end

    local cols, vals = {}, {}
    for _, c in ipairs(COLUMNS) do
        local hasCol = (present == nil) or present[c.col]
        if hasCol then
            cols[#cols + 1] = c.col
            vals[#vals + 1] = (c.col == "value") and tokenLit or c.lit
        end
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

    -- 3) sqlite3 must exist.
    if not exec("command -v sqlite3") then
        return false, "sqlite3 tidak terpasang. Jalankan: pkg install sqlite"
    end

    -- 4) Backup first (restore point if the token needs to be removed later).
    local stamp = os.date("%Y%m%d-%H%M%S")
    local backup = db .. ".bak-" .. stamp
    exec("cp -a " .. quote(db) .. " " .. quote(backup))
    Logger.info("CookieInjector: backup -> " .. backup)

    -- 5) INSERT OR REPLACE restricted to the DB's actual columns.
    local cols, vals = buildInsertSpec(db, token)
    if not cols[1] then
        return false, "Schema cookies tidak terbaca: " .. tostring(db)
    end
    local sql = string.format(
        "INSERT OR REPLACE INTO cookies (%s) VALUES (%s);",
        table.concat(cols, ", "), table.concat(vals, ", ")
    )
    local insertOut = exec("sqlite3 " .. quote(db) .. " '" .. sql:gsub("'", "'\\''") .. "'")
    Logger.info("CookieInjector: sqlite3 output: " .. tostring(insertOut or "(none)"))

    -- 6) Fold any WAL data into the main DB.
    exec("sqlite3 " .. quote(db) .. " 'PRAGMA wal_checkpoint(TRUNCATE);'")

    -- 7) Verify the token is actually stored.
    local verify = exec(string.format(
        "sqlite3 %s \"SELECT length(value) FROM cookies WHERE name='.ROBLOSECURITY' AND host_key LIKE '%%roblox.com%%';\"",
        quote(db)
    ))
    Auth.resetCache()
    if not verify or tonumber(verify:gsub("%s+", "")) == nil or tonumber(verify:gsub("%s+", "")) == 0 then
        return false, "Injeksi mungkin gagal (verifikasi: value tidak terbaca). Backup: " .. backup
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