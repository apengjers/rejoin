-- Recover terminal mode left by a previous interrupted cookie paste before any
-- logs or menu text. A redirected/headless stdin makes stty fail harmlessly.
local ttyReady = os.execute("stty sane 2>/dev/null")
if ttyReady == true or ttyReady == 0 then
    os.execute("stty echo icanon opost onlcr 2>/dev/null")
    io.write("\r\27[2J\27[H")
    io.flush()
end

local Logger = require("core.logger")
local State = require("core.state")

Logger.info(State.get())

State.set("MENU")

Logger.info(State.get())

-- Parse simple CLI flags
local args = arg or {}
local headless = false
local skipWizard = false
local startMonitorFlag = false
local autoLaunchFlag = false
local configSource = nil
local dryRun = false
local clearCacheFlag = false
local doctorFlag = false
for i = 1, #args do
    local a = args[i]
    if a == "--headless" or a == "--no-interactive" then headless = true end
    if a == "--no-wizard" then skipWizard = true end
    if a == "--start-monitor" then startMonitorFlag = true end
    if a == "--auto-launch" then autoLaunchFlag = true end
    if a == "--dry-run" then dryRun = true end
    if a == "--clear-cache" then clearCacheFlag = true end
    if a == "--doctor" then doctorFlag = true end
    if a == "--config" then
        local nextArg = args[i+1]
        if nextArg and nextArg:sub(1,2) ~= "--" then
            configSource = nextArg
        end
    end
end

-- Set runtime dry-run early
local Runtime = require("core.runtime")
if dryRun then
    Runtime.setDryRun(true)
    Logger.info("Runtime: dry-run mode enabled")
end

-- Ensure configuration exists (setup will copy template -> config if needed)
local Setup = require("core.setup")
local ok, created_or_err = Setup.ensureConfig(configSource)
if not ok then
    Logger.error("Failed to ensure config: " .. tostring(created_or_err))
else
    if created_or_err == true and not skipWizard and not headless then
        -- config was just created from template; run the interactive setup wizard
        local Wizard = require("core.setup_wizard")
        local wok, werr = Wizard.run()
        if not wok then
            Logger.warn("Setup wizard did not complete: " .. tostring(werr))
            Logger.info("You can edit config/config.lua manually or re-run the wizard later.")
        end
    end
end

local Config = require("core.config")

-- Initialize logger path from loaded config
local conf = Config.get() or {}
if conf.logPath then
    Logger.setLogPath(conf.logPath)
end

local data = conf

local InstanceManager = require("managers.instance")
InstanceManager.load(Config.get())

-- One-shot: environment doctor -- run on EACH device, diff outputs to find the
-- dependency/fingerprint difference causing "inject [OK] tapi app ga login" on one
-- device but not the other. Exits after printing.
if doctorFlag then
    local Doctor = require("managers.doctor")
    local report = Doctor.run()
    print("\n===== DOCTOR REPORT (jalankan di KEDUA device, diff outputnya) =====")
    print(report)
    print("====================================================================")
    os.exit(0)
end

-- One-shot: clear cache for all configured clones (apps must be closed first), exit.
if clearCacheFlag then
    local CacheCleaner = require("managers.cache_cleaner")
    local n = CacheCleaner.applyAll()
    print(string.format("Cleared cache for %d instance(s). Apps harus dalam keadaan berhenti (force-stop).", n))
    Logger.info(string.format("Main: --clear-cache applied to %d instance(s)", n))
    os.exit(0)
end

-- Headless mode: optionally start monitor immediately
if headless and startMonitorFlag then
    Logger.info("Headless mode: starting monitor")
    local Monitor = require("managers.monitor")
    -- --auto-launch behaves like Menu 1: launch all clones (Starting -> Running) with
    -- optimizer applied, then monitor. Without it, only the monitor runs (no launch).
    local opts = autoLaunchFlag and { autoLaunch = true } or nil
    Monitor.start(Config.get(), opts)
    os.exit(0)
end

-- Interactive menu loop
local function prompt(msg)
    io.write(msg)
    io.flush()
    local line = io.read()
    -- Ctrl+C / EOF while in the menu returns nil; treat it as a clean hard stop.
    if line == nil then
        print("\nInterrupted by Ctrl+C; exiting.")
        os.exit(0)
    end
    return line
end

while true do
    print('\nMain Menu:\n  1) Launch All + Monitor\n  2) Instances Manager\n  3) Settings\n  4) View Logs\n  5) Start Monitor\n  6) AutoExecute Manager\n  7) Inject Cookie\n  8) Dump Cookies (debug)\n  9) Exit\n  (tekan Ctrl+C untuk berhenti)\n')
    local choice = prompt("Choose: ") or ""
    choice = choice:match("^%s*(.-)%s*$")
    if choice == "1" then
        local list = InstanceManager.getAll()
        if #list == 0 then
            print("No instances configured.")
        else
            -- Launch clones one at a time (Starting -> Running) inside the live monitor
            -- dashboard; the monitor then watches/recovers them.
            local Monitor = require("managers.monitor")
            Monitor.start(Config.get(), { autoLaunch = true })
            if Monitor.interrupted() then
                print("Monitor stopped by Ctrl+C; exiting.")
                os.exit(0)
            end
            break
        end
    elseif choice == "2" then
        local InstancesCLI = require("core.instances_cli")
        InstancesCLI.run()
    elseif choice == "3" then
        local SettingsCLI = require("core.settings_cli")
        SettingsCLI.run()
    elseif choice == "4" then
        local LogsCLI = require("core.logs_cli")
        LogsCLI.run()
    elseif choice == "5" then
        local Monitor = require("managers.monitor")
        print("(tekan Ctrl+C untuk berhenti monitor)")
        Monitor.start(Config.get())
        if Monitor.interrupted() then
            print("Monitor stopped by Ctrl+C; exiting.")
            os.exit(0)
        end
    elseif choice == "6" then
        local AutoExecuteCLI = require("core.autoexecute_cli")
        AutoExecuteCLI.run()
    elseif choice == "7" then
        local InjectCookieCLI = require("core.inject_cookie_cli")
        InjectCookieCLI.run()
    elseif choice == "8" then
        local DumpCookiesCLI = require("core.dump_cookies_cli")
        DumpCookiesCLI.run()
    elseif choice == "9" then
        print("Exiting main")
        break
    else
        print("Unknown choice")
    end
end
