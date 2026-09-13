-- debug_probe.lua
-- Diagnose why an instance stays "Running" (or why recovery only reopens some).
-- Usage (Termux, repo dir):
--   lua debug_probe.lua
--
-- Prints, for every configured clone, the raw evidence used by isRunning/recovery:
--   * APK.isRunning(pkg) result
--   * pidof / pgrep -f / ps -A evidence (each runs as root via Shell.exec)
--   * the clone's RSS + process state from `ps`
--   * APK.isActive(pkg) decision vs the configured RSS threshold
--
-- This tells us whether a "closed" clone still shows a process and whether it is
-- classified as ACTIVE (real memory) or as a force-close stub.
--
-- NOTE: dumpsys activity/window calls were removed — on this device they never list the
-- App Cloner floating-window clones and the heavy `dumpsys` calls hung the terminal.

pcall(require, "core.logger")

local Config = require("core.config")
local APK = require("managers.apk")
local InstanceManager = require("managers.instance")

InstanceManager.load(Config.get())

local _cfg = Config.get() or {}
local minRssMb = tonumber(_cfg.minRss) or 300
local rssThreshKb = minRssMb * 1024

local instances = InstanceManager.getAll()
if not instances or #instances == 0 then
    print("No instances configured.")
    os.exit(0)
end

local function run(cmd)
    local ok, out = (require("utils.shell")).exec(cmd)
    out = (out or ""):gsub("\n+$", "")
    return ok, out
end

-- Extract a package's RSS (KB) and process state from `ps -A` (as root).
-- ps columns: USER PID PPID VSZ RSS WCHAN ADDR S COMMAND
local function psInfo(pkg)
    local ok, out = run("ps -A")
    if not ok or not out then return nil, nil end
    for line in out:gmatch("[^\r\n]+") do
        local fields = {}
        for f in line:gmatch("%S+") do fields[#fields + 1] = f end
        if #fields >= 9 then
            local cmd = fields[#fields]
            -- match COMMAND exactly == pkg
            if cmd == pkg then
                return fields[5], fields[8]
            end
        end
    end
    return nil, nil
end

print("==================================================================")
print("launch.md-style probe (all commands run as root)")
print("==================================================================")

for i, inst in ipairs(instances) do
    local id = inst.id or i
    local pkg = inst.package or "?"
    local name = tostring(inst.name or id)

    print("")
    print(string.format("----- #%d  %s  (%s) -----", i, name, pkg))

    local ok, res = pcall(function() return APK.isRunning(pkg) end)
    print(string.format("APK.isRunning(%s)  =>  %s", pkg, tostring(ok and res)))

    local pidof, pidofOut = run("pidof " .. pkg)
    print("pidof " .. pkg .. "  =>  " .. (pidofOut or "(none)"))

    local pattern = "^" .. pkg:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "\\%1") .. "$"
    local pgr, pgrOut = run("pgrep -f '" .. pattern .. "'")
    print("pgrep -f '" .. pattern .. "'  =>  " .. (pgrOut or "(none)"))

    local rss, st = psInfo(pkg)
    print(string.format("ps state=%s rss=%s", tostring(st), tostring(rss and (rss .. " KB") or "?")))

    local okA, resA = pcall(function() return APK.isActive(pkg) end)
    print(string.format("isActive=%s (RSS threshold %d MB)", tostring(okA and resA), minRssMb))
end
