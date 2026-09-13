local Logger = require("core.logger")
local Shell = require("utils.shell")

-- Auth / account-login detection.
--
-- Roblox (incl. Lite/Floating mod clones) stores its session cookie as a
-- `.ROBLOSECURITY` token somewhere under the app's data directory. For a stock
-- install that is the WebView cookie DB at
--   /data/data/<package>/app_webview/Default/Cookies   (a SQLite file)
-- but modded/"Lite" clones can keep it in a different place (databases, shared_prefs,
-- app_flutter, ...). Rather than pin one path, we SCAN the clone's data directory
-- recursively (root) for the token.
--
-- A clone that has NEVER been logged in has no `.ROBLOSECURITY` token anywhere, so we
-- can tell "not logged in" apart from "force-close stub". When `isLoggedIn == false`
-- the monitor/recovery must NEVER force-relaunch the clone (low RSS is expected while
-- sitting on the login screen).
--
-- Returns:
--   true  -> an account is logged in (a session token is present)
--   false -> definitely NOT logged in (no token found anywhere under the data dir)
--   nil   -> could not determine (e.g. root read failed). Callers fall back to the
--            restart-safe behavior (treat as logged in / relaunch normally).
--
-- The scan is cached per instance for a short TTL so we do not grep every monitor cycle.
-- `cookiePath`, if set on an instance, overrides the base directory to scan.

local Auth = {}

-- Cache: pkg -> { result, at }  (result one of true/false/nil)
local cache = {}
local TTL = 30 -- seconds

local function defaultBaseDir(pkg)
    return "/data/data/" .. pkg
end

local function baseDir(instance)
    if instance and instance.cookiePath and instance.cookiePath ~= "" then
        return instance.cookiePath
    end
    if instance and instance.package then
        return defaultBaseDir(instance.package)
    end
    return nil
end

-- Grep recursively (as root) for the token under `base`. Returns the number of lines
-- matched, or nil if the probe itself failed (dir missing / not readable / grep error).
local function countToken(base)
    -- `grep -a -r -l` prints the file paths that contain the token; `-l` means we only
    -- get file names (one per line) so the count is the number of files with the token.
    local cmd = string.format("grep -a -r -l '.ROBLOSECURITY' '%s' 2>/dev/null", base)
    -- Shell.exec returns (ok, output); pcall returns (true, ok, output) so capture the
    -- THIRD value (the actual output string), not the second (Shell's ok boolean).
    local ok, _, out = pcall(function() return Shell.exec(cmd) end)
    if not ok or not out or out == "(dry-run)" then return nil end
    -- Empty output = no matches found (dir exists and was scanned OK). We cannot tell a
    -- truly empty result from "grep failed" via output alone, so first verify the base
    -- dir is readable; if it is, empty means "no session".
    return out
end

local function baseDirExists(base)
    local cmd = string.format("[ -d '%s' ] && echo AE_DIR || echo AE_NODIR", base)
    -- See countToken: capture the THIRD pcall value (the output string).
    local ok, _, out = pcall(function() return Shell.exec(cmd) end)
    if not ok or not out or out == "(dry-run)" then return nil end
    if out:find("AE_DIR", 1, true) then return true end
    if out:find("AE_NODIR", 1, true) then return false end
    return nil
end

function Auth.isLoggedIn(instance)
    local pkg = instance and instance.package
    if not pkg then return nil end
    local base = baseDir(instance)
    if not base then return nil end

    -- Cache check.
    local cached = cache[pkg]
    local now = os.time()
    if cached and now - cached.at < TTL then
        return cached.result
    end

    local result
    do
        local exists = baseDirExists(base)
        if exists == false then
            -- Data dir does not exist => the app has never stored anything => not logged in.
            result = false
        elseif exists == nil then
            -- Could not even probe the dir => indeterminate.
            result = nil
        else
            local hits = countToken(base)
            if hits == nil then
                -- grep probe failed => indeterminate.
                result = nil
            elseif hits ~= "" then
                result = true
            else
                result = false
            end
        end
    end

    cache[pkg] = { result = result, at = now }
    Logger.debug(string.format("Auth.isLoggedIn(%s): base=%s -> %s", pkg, base, tostring(result)))
    return result
end

-- Clear the cache (e.g. after a login/logout or on monitor start).
function Auth.resetCache()
    cache = {}
end

return Auth
