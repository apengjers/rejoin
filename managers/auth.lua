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
--   true  -> an account is logged in (API confirmed, or a real token + API unreachable)
--   false -> NOT logged in (no real token, token rejected, OR the probe itself failed).
--            A failed/indeterminate probe is treated as NOT logged in so the monitor
--            never force-relaunches a clone it cannot confirm (safe for login screens);
--            a loud Logger.warn makes broken probes visible.
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

-- Grep recursively (as root) for a real `.ROBLOSECURITY` token under `base`.
-- true  -> at least one valid token found (marker format or the cookie name).
-- false -> scanned OK but nothing found -> definitely not logged in.
-- nil   -> the probe itself failed (dir missing / not readable / grep error).
local function hasTokenLike(base)
    local cmd = string.format(
        "grep -a -r -l -E 'WARNING:-DO-NOT-SHARE![A-Za-z0-9_=:.-]{10,}|ROBLOSECURITY' '%s' 2>/dev/null",
        base)
    -- Shell.exec returns (ok, output); pcall returns (true, ok, output) so capture the
    -- THIRD value (the actual output string), not the second (Shell's ok boolean).
    local ok, _, out = pcall(function() return Shell.exec(cmd) end)
    if not ok or not out or out == "(dry-run)" then return nil end
    return out ~= ""
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
        -- 1. Probe the base dir.
        local exists = baseDirExists(base)
        if exists == false then
            -- Data dir does not exist => the app has never stored anything => not logged in.
            result = false
        elseif exists == nil then
            -- Could not even probe the dir => indeterminate. Policy: treat as NOT logged
            -- in (a clone we cannot confirm is never force-relaunched).
            Logger.warn(string.format("Auth.isLoggedIn(%s): cannot probe data dir; treating as NOT logged in (no relaunch)", pkg))
            result = false
        else
            -- 2. Look for a REAL session token (marker format or the cookie name).
            local found = hasTokenLike(base)
            if found == false then
                -- Scanned OK, no token anywhere => definitely not logged in.
                result = false
            elseif found == nil then
                -- Grep probe failed => indeterminate. Same policy as above.
                Logger.warn(string.format("Auth.isLoggedIn(%s): token probe failed; treating as NOT logged in (no relaunch)", pkg))
                result = false
            else
                -- 3. Cross-check against the Roblox API: it is the final arbiter of
                --    whether the cookie is a real, valid session.
                local User = require("managers.username")
                local _, state = User.apiName(instance)
                if state == "ok" then
                    result = true      -- API authenticated -> definitely logged in
                elseif state == "unauth" then
                    result = false     -- cookie rejected / no real token -> not logged in
                else
                    -- API unreachable -> inconclusive. Keep the safer "logged in" default
                    -- so recovery still runs for a clone we cannot disprove (avoids a
                    -- genuinely frozen clone never being relaunched).
                    result = true
                    Logger.debug(string.format("Auth.isLoggedIn(%s): API unreachable; assuming logged in", pkg))
                end
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
