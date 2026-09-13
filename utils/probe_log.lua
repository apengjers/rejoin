-- probe_log.lua
-- Automatic per-cycle launch/monitor diagnostics written to `launch.log`.
--
-- Whenever the app is launched via Menu 1 (Launch All + Monitor), the monitor loop
-- records one line per instance per cycle so that, after a bug (e.g. a clone staying
-- "running" after a force-close), we can just read launch.log instead of running
-- manual diagnostic tools by hand. Lines are written and flushed immediately (open
-- + append + close each time) so nothing is lost if the process is killed.

local APK = require("managers.apk")
local Shell = require("utils.shell")

local ProbeLog = {}

local path = "launch.log"
local enabled = true

function ProbeLog.configure(conf)
    conf = conf or {}
    enabled = conf.launchLogEnabled ~= false
    if conf.launchLogPath and conf.launchLogPath ~= "" then
        path = conf.launchLogPath
    end
end

-- (Re)create the log with a header. Called at monitor start so each session has a
-- fresh, bounded file.
function ProbeLog.init()
    if not enabled then return end
    local f = io.open(path, "w")
    if not f then return end
    f:write("-- rejoin auto-probe log " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    f:close()
end

-- Append a single line (plain text), flushing immediately.
function ProbeLog.line(str)
    if not enabled then return end
    if not str or str == "" then return end
    local f = io.open(path, "a")
    if not f then return end
    f:write(str .. "\n")
    f:close()
end

local function trim(s)
    return (s or ""):gsub("%s+$", "")
end

-- Record one line per configured instance: who, current status, process evidence and
-- the ACTIVE decision (RSS vs threshold). This is the evidence we need the next time a
-- close-1 bug is reproduced.
function ProbeLog.scan(instances, statuses)
    if not enabled then return end
    instances = instances or {}
    local thrMb = 50
    local okCfg, cfg = pcall(function() return require("core.config").get() end)
    if okCfg and cfg and tonumber(cfg.minRss) and tonumber(cfg.minRss) > 0 then
        thrMb = tonumber(cfg.minRss)
    end
    for i, inst in ipairs(instances) do
        local pkg = inst.package
        if pkg and pkg ~= "" then
            local okRow, errRow = pcall(function()
                local name = tostring(inst.name or (inst.id or i))
                local st = statuses and statuses[(inst.id or i)]

                local okRun, running = pcall(function() return APK.isRunning(pkg) end)
                local okAct, active = pcall(function() return APK.isActive(pkg) end)
                local pidOut = ""
                local okPid, _, pidRes = pcall(function() return Shell.exec("pidof " .. pkg) end)
                if okPid and pidRes and pidRes ~= "" and pidRes ~= "(dry-run)" then
                    pidOut = trim(pidRes)
                end
                local rss = APK.getRSSinKB(pkg)
                if rss and rss < 0 then rss = "?" end

                ProbeLog.line(string.format(
                    "[%s] %s | pkg=%s | status=%s | running=%s | isActive=%s | pid=%s | rss=%s KB | thr=%d MB",
                    os.date("%H:%M:%S"),
                    name,
                    pkg,
                    tostring(st or "?"),
                    tostring(okRun and running or "?"),
                    tostring(okAct and active or "?"),
                    (pidOut ~= "" and pidOut) or "-",
                    tostring(rss),
                    thrMb
                ))
            end)
            if not okRow then
                ProbeLog.line(string.format("[%s] scan_error [%s] %s",
                    os.date("%H:%M:%S"), tostring(inst.id or i), tostring(errRow)))
            end
        end
    end
end

return ProbeLog