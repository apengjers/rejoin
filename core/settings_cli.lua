local Logger = require("core.logger")
local Config = require("core.config")

local CLI = {}

local function prompt(msg)
    io.write(msg)
    io.flush()
    return io.read()
end

local function printSettings(conf)
    print("Current Settings:")
    print("  monitorInterval = " .. tostring(conf.monitorInterval))
    print("  recoveryDelay = " .. tostring(conf.recoveryDelay))
    print("  recoveryRetries = " .. tostring(conf.recoveryRetries))
    print("  checkTimeout = " .. tostring(conf.checkTimeout))
    print("  debug = " .. tostring(conf.debug))
    print("  logLevel = " .. tostring(conf.logLevel or "INFO"))
    print("  appAutoExecutePath = " .. tostring(conf.appAutoExecutePath or ""))
    print("  logPath = " .. tostring(conf.logPath))
    print("  clonePackagePrefix = " .. tostring(conf.clonePackagePrefix or ""))
    print("  freezeTimeout = " .. tostring(conf.freezeTimeout))
    print("  gracePeriod = " .. tostring(conf.gracePeriod))
    print("  anrCheckEnabled = " .. tostring(conf.anrCheckEnabled and true or false))
    print("  launchWaitInterval = " .. tostring(conf.launchWaitInterval))
    print("  launchWaitTimeout = " .. tostring(conf.launchWaitTimeout))
    print("  launchSettleDelay = " .. tostring(conf.launchSettleDelay))
    print("  useRoot = " .. tostring(conf.useRoot == nil and true or conf.useRoot))
end

function CLI.run()
    local conf = Config.get() or {}
    conf.monitorInterval = conf.monitorInterval or 5
    conf.recoveryDelay = conf.recoveryDelay or 3
    conf.recoveryRetries = conf.recoveryRetries or 3
    conf.checkTimeout = conf.checkTimeout or 15
    conf.debug = conf.debug == nil and true or conf.debug
    conf.logLevel = conf.logLevel or "INFO"
    conf.appAutoExecutePath = conf.appAutoExecutePath or ""
    conf.autoExecuteDeployPath = nil
    conf.logPath = conf.logPath or "data/rejoin.log"
    conf.clonePackagePrefix = conf.clonePackagePrefix or ""
    conf.freezeTimeout = conf.freezeTimeout or 300
    conf.gracePeriod = conf.gracePeriod or 30
    conf.anrCheckEnabled = conf.anrCheckEnabled ~= false
    conf.launchWaitInterval = conf.launchWaitInterval or 3
    conf.launchWaitTimeout = conf.launchWaitTimeout or 30
    conf.launchSettleDelay = conf.launchSettleDelay or 5
    if conf.useRoot == nil then conf.useRoot = true end

    while true do
        print('\nSettings Menu:\n  1) View settings\n  2) Edit monitorInterval\n  3) Edit recoveryDelay\n  4) Edit recoveryRetries\n  5) Edit checkTimeout\n  6) Toggle debug\n  7) Edit appAutoExecutePath\n  8) Edit logPath\n  9) Edit clonePackagePrefix\n 10) Edit freezeTimeout\n 11) Edit gracePeriod\n 12) Toggle anrCheckEnabled\n 13) Edit launch wait settings\n 14) Edit logLevel\n 15) Save and Exit\n 16) Exit without saving\n')
        local choice = prompt("Choose: ") or ""
        choice = choice:match("^%s*(.-)%s*$")
        if choice == "1" then
            printSettings(conf)
        elseif choice == "2" then
            local v = prompt("monitorInterval (seconds): [" .. tostring(conf.monitorInterval) .. "] ")
            local n = tonumber(v)
            if n then conf.monitorInterval = n else print("Invalid number") end
        elseif choice == "3" then
            local v = prompt("recoveryDelay (seconds): [" .. tostring(conf.recoveryDelay) .. "] ")
            local n = tonumber(v)
            if n then conf.recoveryDelay = n else print("Invalid number") end
        elseif choice == "4" then
            local v = prompt("recoveryRetries: [" .. tostring(conf.recoveryRetries) .. "] ")
            local n = tonumber(v)
            if n then conf.recoveryRetries = n else print("Invalid number") end
        elseif choice == "5" then
            local v = prompt("checkTimeout (seconds): [" .. tostring(conf.checkTimeout) .. "] ")
            local n = tonumber(v)
            if n then conf.checkTimeout = n else print("Invalid number") end
        elseif choice == "6" then
            conf.debug = not conf.debug
            print("debug = " .. tostring(conf.debug))
        elseif choice == "7" then
            local v = prompt("appAutoExecutePath (folder AutoExecute, contoh: /sdcard/Delta/Autoexecute): [" .. tostring(conf.appAutoExecutePath or "") .. "] ")
            if v and v ~= "" then conf.appAutoExecutePath = v end
        elseif choice == "8" then
            local v = prompt("logPath: [" .. tostring(conf.logPath) .. "] ")
            if v and v ~= "" then conf.logPath = v end
        elseif choice == "9" then
            local v = prompt("clonePackagePrefix (empty to disable): [" .. tostring(conf.clonePackagePrefix) .. "] ")
            if v and v ~= "" then conf.clonePackagePrefix = v end
        elseif choice == "10" then
            local v = prompt("freezeTimeout (seconds before relaunch): [" .. tostring(conf.freezeTimeout) .. "] ")
            local n = tonumber(v)
            if n and n > 0 then conf.freezeTimeout = n else print("Invalid number") end
        elseif choice == "11" then
            local v = prompt("gracePeriod (seconds after launch): [" .. tostring(conf.gracePeriod) .. "] ")
            local n = tonumber(v)
            if n and n > 0 then conf.gracePeriod = n else print("Invalid number") end
        elseif choice == "12" then
            conf.anrCheckEnabled = not (conf.anrCheckEnabled and true or false)
            print("anrCheckEnabled = " .. tostring(conf.anrCheckEnabled and true or false))
        elseif choice == "13" then
            local v = prompt("launchWaitInterval (poll, seconds): [" .. tostring(conf.launchWaitInterval) .. "] ")
            local n = tonumber(v)
            if n and n > 0 then conf.launchWaitInterval = n else print("Invalid number") end
            v = prompt("launchWaitTimeout (seconds before giving up): [" .. tostring(conf.launchWaitTimeout) .. "] ")
            n = tonumber(v)
            if n and n > 0 then conf.launchWaitTimeout = n else print("Invalid number") end
            v = prompt("launchSettleDelay (pause after open, seconds): [" .. tostring(conf.launchSettleDelay) .. "] ")
            n = tonumber(v)
            if n and n >= 0 then conf.launchSettleDelay = n else print("Invalid number") end
            v = prompt("useRoot (run commands as root / su -c, true/false): [" .. tostring(conf.useRoot == nil and true or conf.useRoot) .. "] ")
            if v and v ~= "" then
                if v == "true" or v == "1" or v:lower() == "y" or v:lower() == "yes" then
                    conf.useRoot = true
                elseif v == "false" or v == "0" or v:lower() == "n" or v:lower() == "no" then
                    conf.useRoot = false
                else
                    print("Invalid value (use true/false)")
                end
            end
        elseif choice == "14" then
            local v = prompt("logLevel (DEBUG/INFO/WARN/ERROR): [" .. tostring(conf.logLevel or "INFO") .. "] ")
            if v and v ~= "" then
                local lvl = v:upper()
                if lvl == "DEBUG" or lvl == "INFO" or lvl == "WARN" or lvl == "ERROR" then
                    conf.logLevel = lvl
                else
                    print("Invalid level (use DEBUG/INFO/WARN/ERROR)")
                end
            end
        elseif choice == "15" then
            local ok, err = Config.save(conf)
            if ok then
                print("Settings saved")
                -- update logger path if changed
                local Logger = require("core.logger")
                if conf.logPath then Logger.setLogPath(conf.logPath) end
                if conf.logLevel then Logger.setLevel(conf.logLevel) end
            else
                print("Failed to save: " .. tostring(err))
            end
            break
        elseif choice == "16" then
            print("Aborting without saving")
            break
        else
            print("Unknown choice")
        end
    end
end

return CLI