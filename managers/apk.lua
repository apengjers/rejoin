local Logger = require("core.logger")
local Shell = require("utils.shell")

local APKManager = {}

-- Resolve the default launchable activity component for a package (best-effort).
-- Returns the component string like "com.roblox.client/.Activity" or nil on failure.
function APKManager.resolveLaunchComponent(packageName)
    -- cmd package resolve-activity --brief returns the package/activity component on the last line
    local cmd = string.format("cmd package resolve-activity --brief %s", packageName)
    local ok, out = Shell.exec(cmd)
    if ok and out then
        for line in out:gmatch("[^\r\n]+") do
            local comp = line:match("(%S+%/%S+)")
            if comp then
                return comp
            end
        end
    end
    return nil
end

-- Launch an APK by package name for Termux/Android.
--
-- Order of attempts:
--   1) `am start -a MAIN -c LAUNCHER -p <pkg>`  -- targets the package explicitly and
--      starts its own task/launcher activity. Works for cloned apps (each clone is a
--      distinct package) and does NOT depend on `cmd package resolve-activity`, which is
--      often unavailable in a Termux (non-adb, non-root) shell.
--   2) `monkey -p <pkg> -c LAUNCHER 1`          -- legacy fallback.
--   3) resolve-activity + `am start -n <component>` -- best-effort fallback.
--
-- Returns (success, output_or_err).
function APKManager.launch(packageName)
    Logger.info("APKManager: launching package: " .. tostring(packageName))

    -- 1) Primary: am start MAIN/LAUNCHER targeting the package explicitly.
    local cmd = string.format("am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p %s", packageName)
    Logger.info("APKManager: exec: " .. cmd)
    local ok, out = Shell.exec(cmd)
    local failedHint = { "Error", "Failure", "Exception", "does not exist", "is not allowed", "Activity not started" }
    local failed = false
    if ok and out then
        for _, h in ipairs(failedHint) do
            if out:find(h, 1, true) then failed = true break end
        end
        if not failed then
            Logger.info("APKManager: am start accepted for " .. tostring(packageName))
            return true, out
        end
    else
        failed = true
    end
    Logger.warn("APKManager: am start launch failed/not accepted for " .. tostring(packageName) .. ": " .. tostring(out))

    -- 2) Fallback: monkey launches the main activity of a package by name (no component needed)
    cmd = string.format("monkey -p %s -c android.intent.category.LAUNCHER 1", packageName)
    Logger.info("APKManager: fallback exec: " .. cmd)
    ok, out = Shell.exec(cmd)
    if ok and out then
        -- monkey exits 0 even on some errors; only treat as success on injected events
        if out:find("Events injected", 1, true) then
            Logger.info("APKManager: monkey launch injected events for " .. tostring(packageName))
            return true, out
        end
        Logger.warn("APKManager: monkey reported an error for " .. tostring(packageName) .. ": " .. tostring(out))
    else
        Logger.warn("APKManager: monkey launch failed/empty for " .. tostring(packageName))
    end

    -- 3) Fallback: resolve the launchable activity then `am start` (best-effort)
    local component = APKManager.resolveLaunchComponent(packageName)
    if component then
        Logger.info("APKManager: fallback resolved launch component: " .. tostring(component))
        local ok2, out2 = Shell.exec(string.format("am start -n %s", component))
        if ok2 and out2 and out2:find("Error", 1, true) == nil then
            return true, out2
        end
        Logger.warn("APKManager: fallback am start failed for " .. tostring(packageName) .. ": " .. tostring(out2))
    end

    return false, out
end

function APKManager.forceStop(packageName)
    Logger.info("APKManager: force stopping: " .. tostring(packageName))
    local cmd = string.format("am force-stop %s", packageName)
    local ok, out = Shell.exec(cmd)
    return ok, out
end

-- Escape regex metacharacters so a package name is matched literally in a POSIX ERE
-- (as consumed by `pgrep -f`). Produces `\.` etc. (backslash-dot), NOT `%.` (percent-dot).
local function escapeRegex(s)
    return s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "\\%1")
end

-- Check whether a package has a running process. Tries pidof, then pgrep, then ps.
-- Matching is anchored to the START of the process command. A clone's MAIN process runs
-- under its own exact package name (e.g. com.apengjers.v3), so we match that name EXACTLY —
-- NOT sub-processes like `com.apengjers.v3:p0` (background services that keep running after
-- the UI is swiped away, which previously left `isRunning` true -> status stuck at "ingame"
-- -> the closed app was never recovered/open again).
-- Returns true if any method finds a matching process, false otherwise.
function APKManager.isRunning(packageName)
    if not packageName or packageName == "" then return false end
    local pkg = packageName:gsub("['\" ]", "")
    if pkg == "" then return false end

    -- Match the exact main process name only (no trailing `:` sub-process).
    local pattern = "^" .. escapeRegex(pkg) .. "$"

    -- 1) pidof (exact process-name match; busybox sometimes missing it)
    local ok, out = Shell.exec(string.format("pidof %s", pkg))
    if ok and out and out ~= "" and out ~= "(dry-run)" then
        return true
    end

    -- 2) pgrep -f with a pattern matching this clone's exact process command
    ok, out = Shell.exec(string.format("pgrep -f '%s'", pattern))
    if ok and out and out ~= "" and out ~= "(dry-run)" then
        return true
    end

    -- 3) ps -A fallback (compare the process COMMAND exactly, since ps lines are columnar
    --    and the ERE pattern above would not match Lua's pattern syntax)
    ok, out = Shell.exec("ps -A")
    if ok and out and out ~= "(dry-run)" then
        for line in (out or ""):gmatch("[^\r\n]+") do
            local cmd = line:match("(%S+)$")
            if cmd then
                if cmd == pkg then
                    return true
                end
            end
        end
    end

    return false
end

-- ---------------------------------------------------------------------------
-- RSS/memory-based "active" detection.
--
-- On this device `dumpsys activity`/`dumpsys window` does NOT list the floating-window
-- clones at all (even when fully running), so UI visibility can't be used. The signal
-- that actually separates a running clone from a force-close stub is resident memory:
--    * running clone    ~1 GB    (RSS from `ps -A`, kB)
--    * force-close stub ~188 MB   (observed when the floating window was closed)
--    * earliest running example seen ~235 MB (older build)
-- So we treat a clone as ACTIVE only when its process exists AND its RSS is at or above
-- a threshold (config.minRss, default 300 MB). A low-RSS stub therefore reads as
-- "not active" -> recovery relaunches it.
--
-- getRSSinKB(pkg): RSS in kilobytes from `ps -A`, or -1 if no process / not parseable.
-- isActive(pkg):  process exists AND RSS >= threshold. Returns boolean.
-- ---------------------------------------------------------------------------

local function rssThreshold()
    local ok, cfg = pcall(require, "core.config")
    if ok and cfg then
        local g = cfg.get and cfg.get() or {}
        local v = tonumber(g and g.minRss)
        if v and v > 0 then return v * 1024 end -- config stored in MB -> kB
    end
    return 300 * 1024 -- default 300 MB (in kB)
end

function APKManager.getRSSinKB(packageName)
    if not packageName or packageName == "" then return -1 end
    local pkg = packageName:gsub("['\" ]", "")
    if pkg == "" then return -1 end
    local ok, out = Shell.exec("ps -A")
    if not ok or not out or out == "(dry-run)" then return -1 end
    for line in out:gmatch("[^\r\n]+") do
        local fields = {}
        for f in line:gmatch("%S+") do fields[#fields + 1] = f end
        if #fields >= 9 and fields[#fields] == pkg then
            local rss = tonumber(fields[5])
            if rss then return rss end
            return -1
        end
    end
    return -1
end

function APKManager.isActive(packageName)
    if not packageName or packageName == "" then return false end
    if not APKManager.isRunning(packageName) then return false end
    local rss = APKManager.getRSSinKB(packageName)
    if rss < 0 then return false end
    return rss >= rssThreshold()
end


-- Used by "Launch All" to detect how many clones have actually come up: every Roblox
-- clone runs a process named `com.roblox.client`, so waiting for the count to reach the
-- number of clones launched gives a reliable per-launch progress signal even when the
-- per-package process name differs from the package (App Cloner renames packages only).
-- Returns a number (>= 0). In dry-run returns 1 (as if one process is running).
function APKManager.countProcess(name)
    if not name or name == "" then return 0 end

    -- 1) pgrep -f <name>: one PID per line; count non-empty lines (works on busybox).
    local ok, out = Shell.exec(string.format("pgrep -f %s", name))
    if ok and out and out ~= "(dry-run)" and out ~= "" then
        local n = 0
        for _ in (out.."\n"):gmatch("[^\r\n]+") do
            n = n + 1
        end
        return n
    end
    if ok and out and out == "(dry-run)" then
        return 1
    end

    -- 2) pidof <name>: a space-separated list of PIDs; count tokens.
    ok, out = Shell.exec(string.format("pidof %s", name))
    if ok and out and out ~= "" and out ~= "(dry-run)" then
        local n = 0
        for _ in (out.." "):gmatch("%S+") do
            n = n + 1
        end
        return n
    end

    -- 3) ps -A fallback: count lines whose COMMAND starts with the token.
    ok, out = Shell.exec("ps -A")
    if ok and out and out ~= "(dry-run)" then
        local n = 0
        for line in (out or ""):gmatch("[^\r\n]+") do
            local cmd = line:match("(%S+)$")
            if cmd and (cmd == name or cmd:sub(1, #name + 1) == name .. ":") then
                n = n + 1
            end
        end
        return n
    end

    return 0
end

-- Count how many of the given packages currently have a running process.
-- Used by "Launch All" to decide when each launched clone is actually up, so it can
-- move on to the next one. Unlike countProcess (which matches a single base name),
-- this matches each clone's own package name, which is more accurate because every
-- App Cloner clone keeps its own process name (e.g. com.apengjers.v3).
function APKManager.countRunning(packages)
    if not packages then return 0 end
    local n = 0
    for _, pkg in ipairs(packages) do
        if APKManager.isRunning(pkg) then
            n = n + 1
        end
    end
    return n
end

return APKManager
