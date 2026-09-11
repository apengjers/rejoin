local Logger = require("core.logger")
local File = require("utils.file")
local Shell = require("utils.shell")

local Username = {}

local cache = {}
local TTL_OK   = 600  -- seconds before re-resolving a successful result
local TTL_FAIL = 60   -- seconds before retrying after a failure / nil
local LOG_PATH = "data/username_scan.log"

local function trim(s)  return (s or ""):match("^%s*(.-)%s*$") end

local function logLine(str)
    if not str or str == "" then return end
    local f = io.open(LOG_PATH, "a")
    if f then f:write(str .. "\n"); f:close() end
end

-- Extract the .ROBLOSECURITY token from the clone's data dir (root required).
-- The token value is `_|WARNING:-DO-NOT-SHARE!<random>`, so we grab from "WARNING:" on.
local function extractToken(base)
    local cmd = "grep -a -r -o -E 'WARNING:-DO-NOT-SHARE![A-Za-z0-9_=:.-]{10,}' '" .. base .. "' 2>/dev/null | head -1"
    local ok, _, raw = pcall(function() return Shell.exec(cmd) end)
    if not ok or not raw or raw == "" or raw == "(dry-run)" then return nil end
    return raw:match("(WARNING%-DO%-NOT%-SHARE%![A-Za-z0-9_=:%.:%-]+)")
end

-- Resolve the username from the Roblox public authenticated-user API.
local function resolveViaApi(token)
    local cmd = "curl -s --max-time 3 -H 'Cookie: .ROBLOSECURITY=" .. token .. "' https://users.roblox.com/v1/users/authenticated"
    local ok, _, out = pcall(function() return Shell.exec(cmd) end)
    if not ok or not out or out == "" or out == "(dry-run)" then return nil end
    return out:match('"name"%s*:%s*"([^"]*)"') or out:match('"displayName"%s*:%s*"([^"]*)"')
end

-- Fallback: scan known light dirs for username/account keys.
local function resolveLocal(base)
    local q = "[\"']"
    local cmd = "grep -a -r -i -E '(userName|username|displayName|accountName|playerName)[[:space:]]*[:=][[:space:]]*"
        .. q .. "?[A-Za-z0-9_]{3,32}" .. q .. "?' --include='*.xml' --include='*.json' --include='*.txt' --include='*.log' '"
        .. base .. "/shared_prefs' '" .. base .. "/files' 2>/dev/null | head -1"
    local ok, _, out = pcall(function() return Shell.exec(cmd) end)
    if not ok or not out or out == "" or out == "(dry-run)" then return nil end
    local _, val = out:match('(username|userName|displayName|accountName|playerName)%s*[:=]%s*["\']?([A-Za-z0-9_]{3,32})')
    return val
end

-- Reset the username cache and (re)create the evidence log.
function Username.reset()
    cache = {}
    local f = io.open(LOG_PATH, "w")
    if f then
        f:write("-- username scan evidence log " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        f:close()
    end
end

-- Resolve the Roblox username for a single instance. Returns a string or nil.
function Username.get(instance)
    if not instance then return nil end
    local pkg = instance.package
    if not pkg then return nil end

    local cached = cache[pkg]
    if cached then
        if os.time() - cached.at < (cached.username and TTL_OK or TTL_FAIL) then
            return cached.username
        end
    end

    -- Manual override via a file whose first line is the username.
    if instance.usernamePath and instance.usernamePath ~= "" then
        local content = File.read(instance.usernamePath)
        local u = content and trim(content:match("^[^\n]+"))
        if u and #u > 0 then
            cache[pkg] = { username = u, at = os.time() }
            return u
        end
    end

    local username = nil
    local base = "/data/data/" .. pkg
    local ev = string.format("[%s] pkg=%s", os.date("%H:%M:%S"), pkg)

    local token = extractToken(base)
    ev = ev .. " token=" .. tostring(token and #token or 0)
    if token then
        local apiUser = resolveViaApi(token)
        ev = ev .. " api=" .. tostring(apiUser)
        username = apiUser
    end

    if not username then
        local localUser = resolveLocal(base)
        ev = ev .. " local=" .. tostring(localUser)
        username = localUser
    end

    logLine(ev)
    cache[pkg] = { username = username, at = os.time() }
    return username
end

-- Warm the cache for all instances (non-blocking per individual error).
function Username.prefetch(instances)
    for _, inst in ipairs(instances or {}) do
        pcall(function() Username.get(inst) end)
    end
end

return Username