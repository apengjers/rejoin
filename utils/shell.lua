local Logger = require("core.logger")
local Runtime = require("core.runtime")

local Shell = {}

-- Per-command timeout (seconds). `io.popen` blocks forever with no timeout, so a hung
-- su/dumpsys call would freeze the whole tool (Termux would stop accepting input).
-- The timeout is applied with toybox/coreutils `timeout`, falling back to no-wait if
-- it's unavailable. Overridable via config.shellTimeout.
local function cmdTimeout()
    local conf = nil
    local ok = pcall(function() conf = require("core.config").get() end)
    if ok and conf and tonumber(conf.shellTimeout) and tonumber(conf.shellTimeout) > 0 then
        return tonumber(conf.shellTimeout)
    end
    return 10
end

-- Whether a `timeout` tool is available (cached). If missing we run without one so a
-- command still executes on restricted shells where `timeout` isn't installed.
local timeoutCheckDone = false
local timeoutAvailable = false
local function hasTimeoutTool()
    if not timeoutCheckDone then
        timeoutCheckDone = true
        local f = io.popen("command -v timeout 2>/dev/null")
        if f then
            local out = f:read("*l") or ""
            f:close()
            timeoutAvailable = (out ~= "")
        end
    end
    return timeoutAvailable
end

-- Apply a timeout to a command. Runs `timeout <secs> <cmd>` when the tool exists.
local function applyTimeout(cmd)
    if hasTimeoutTool() then
        return "timeout " .. cmdTimeout() .. " " .. cmd
    end
    return cmd
end

-- Whether commands should run with root (`su -c '...'`). Reads `useRoot` from the
-- project config; defaults to true because the supported setup is a rooted device
-- (Magisk). On a non-root device set `useRoot = false` in config/config.lua.
local function rootEnabled()
    local ok, conf = pcall(function() return require("core.config").get() end)
    if ok and conf and conf.useRoot ~= nil then
        return conf.useRoot == true
    end
    return true
end

-- Wrap a shell command in `su -c '...'` so ps/pidof/pgrep/am/logcat run as root. A
-- rooted device running Termux as a NORMAL user cannot see other apps' processes
-- (Android 11+), which previously made every process probe return empty and broke
-- per-instance health/Launch All detection. Running as root fixes that.
local function runWithRoot(cmd)
    if not rootEnabled() then
        return cmd
    end
    local inner = cmd:gsub("'", "'\\''")
    return "su -c '" .. inner .. "'"
end

-- Execute a command and return (ok, output). Uses io.popen to capture stdout.
-- If runtime dry-run is enabled, log the command and return a simulated success output.
function Shell.exec(cmd)
    if not cmd then return false, "no_cmd" end
    if Runtime.isDryRun() then
        Logger.debug("[dry-run] Shell.exec")
        -- Simulate outputs for common probes
        if cmd:match("^pidof %S+") then
            -- simulate process not running by default (empty output)
            return true, ""
        end
        return true, "(dry-run)"
    end

    local full = runWithRoot(applyTimeout(cmd))
    -- Commands may contain session cookies or SQL values. Never write them to logs.
    Logger.debug("Shell.exec")
    local f = io.popen(full .. " 2>&1")
    if not f then return false, "popen_failed" end
    local out = f:read("*a") or ""
    local ok, _, code = f:close()
    -- Preserve the exit status so callers can distinguish empty output from failure.
    return ok == true, (out:gsub("\n+$", "")), code
end

return Shell
