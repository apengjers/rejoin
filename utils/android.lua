local Logger = require("core.logger")
local Shell = require("utils.shell")

local Android = {}

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function Android.forceStop(packageName)
    Logger.info("Android: force stopping " .. tostring(packageName))
    Shell.exec(string.format("am force-stop %s", packageName))
end

function Android.launch(packageName)
    Logger.info("Android: launching " .. tostring(packageName))
    -- am start MAIN/LAUNCHER targeting the package explicitly first: it starts the
    -- package's own launcher task and does not depend on `cmd package resolve-activity`
    -- (often unavailable in a Termux non-adb/non-root shell). monkey is the fallback.
    local cmd = string.format("am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p %s", packageName)
    local ok, out = Shell.exec(cmd)
    if ok and out then
        local failed = false
        for _, h in ipairs({ "Error", "Failure", "Exception", "does not exist", "Activity not started" }) do
            if out:find(h, 1, true) then failed = true break end
        end
        if not failed then
            Logger.info("Android: am start accepted for " .. tostring(packageName))
            return true
        end
    end

    cmd = string.format("monkey -p %s -c android.intent.category.LAUNCHER 1", packageName)
    ok, out = Shell.exec(cmd)
    if ok and out and out:find("Events injected", 1, true) then
        Logger.info("Android: monkey launch injected events for " .. tostring(packageName))
        return true
    end
    cmd = string.format("cmd package resolve-activity --brief %s", packageName)
    local rok, rout = Shell.exec(cmd)
    local component = nil
    if rok and rout then
        for line in rout:gmatch("[^\r\n]+") do
            local comp = line:match("(%S+%/%S+)")
            if comp then component = comp break end
        end
    end
    if component then
        Logger.info("Android: fallback resolved component: " .. tostring(component))
        Shell.exec(string.format("am start -n %s", component))
    end
    return false
end

-- Open a URL. When packageName is provided, the VIEW intent is delivered to that
-- clone package (-p <pkg>). On-device probing showed this per-clone form
--     am start -a VIEW -d 'roblox://placeId=<id>' -p <clone>
-- both auto-joins the map AND uses the right clone/account, whereas the untargeted
-- form only reaches a single default handler and -n <pkg>/...ActivityProtocolLaunch
-- only showed the game page.
--
-- A failed targeted launch must not open the default clone/account.
function Android.openURL(url, packageName)
    Logger.info("Android: opening URL " .. tostring(url) .. " (pkg=" .. tostring(packageName) .. ")")

    local function accepted(ok, out)
        if not ok or not out then return false end
        for _, hint in ipairs({ "Error", "Failure", "Exception", "Activity not started" }) do
            if out:find(hint, 1, true) then return false end
        end
        return true
    end

    -- 1) Targeted clone package.
    if packageName and packageName ~= "" then
        local ok, out = Shell.exec(string.format("am start -a android.intent.action.VIEW -d %s -p %s", quote(url), quote(packageName)))
        if accepted(ok, out) then
            Logger.info("Android: openURL via targeted package (" .. tostring(packageName) .. ")")
            return true, out
        end
        Logger.warn("Android: targeted openURL failed for " .. tostring(packageName) .. ": " .. tostring(out))
        return false, out
    end

    -- 2) Untargeted.
    local ok, out = Shell.exec(string.format("am start -a android.intent.action.VIEW -d %s", quote(url)))
    return accepted(ok, out), out
end

return Android
