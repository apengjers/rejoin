local Logger = {}

Logger.levels = {
    INFO = "INFO",
    WARN = "WARN",
    ERROR = "ERROR",
    DEBUG = "DEBUG"
}

local function getTime()
    return os.date("%H:%M:%S")
end

local FileUtil = require("utils.file")

local defaultLogPath = "data/rejoin.log"
local logFilePath = defaultLogPath

-- Try to read log path from config file without requiring core.config to avoid circular dependency.
-- This reads config/config.lua if present and extracts logPath field.
local function loadLogPathFromConfig()
    local confPath = "config/config.lua"
    if FileUtil.exists(confPath) then
        local ok, conf = pcall(dofile, confPath)
        if ok and type(conf) == "table" and conf.logPath then
            return tostring(conf.logPath)
        end
    end
    return nil
end

-- Minimum level that gets printed to the console. DEBUG is hidden unless the config
-- sets `logLevel = "DEBUG"` (so the monitor doesn't flood with `su -c ...` / process
-- probe lines every cycle). Read directly from the config file to avoid a circular
-- dependency on core.config.
local function loadLogLevelFromConfig()
    local confPath = "config/config.lua"
    if FileUtil.exists(confPath) then
        local ok, conf = pcall(dofile, confPath)
        if ok and type(conf) == "table" and conf.logLevel then
            return tostring(conf.logLevel):upper()
        end
    end
    return nil
end

local logLevel = loadLogLevelFromConfig() or "INFO"

-- When false, log lines are written to the file only (not the console). Used while a
-- full-screen monitor dashboard is being drawn, so stray log lines don't push the
-- dashboard around. Defaults to true (normal behavior outside monitoring).
local consoleVisible = true

-- Longest log line echoed to the console. A single huge line (e.g. a shell command
-- embedding a pasted token when logLevel=DEBUG) can stall Termux's rendering and
-- swallow subsequent keystrokes. The log file always keeps the full line.
local CONSOLE_MAX = 200

local levelsOrder = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
}

local function ensureLogDir()
    local dir = logFilePath:match("^(.*)[/\\]")
    if dir and dir ~= "" then
        pcall(function()
            -- try to use lfs or mkdir -p
            local lfs_ok, lfs = pcall(require, "lfs")
            if lfs_ok and lfs and lfs.mkdir then
                local cur = ""
                for part in dir:gmatch("[^/\\]+") do
                    cur = (cur == "") and part or (cur .. "/" .. part)
                    if lfs.attributes(cur) == nil then
                        pcall(lfs.mkdir, cur)
                    end
                end
            else
                os.execute("mkdir -p '" .. dir .. "'")
            end
        end)
    end
end

local function appendLogToFile(line)
    ensureLogDir()
    local f, err = io.open(logFilePath, "a")
    if not f then return false, err end
    f:write(line .. "\n")
    f:close()
    return true
end

-- initialize logFilePath from config if available
local fromConfig = loadLogPathFromConfig()
if fromConfig then logFilePath = fromConfig end

local function consoleSafe(line)
    if #line <= CONSOLE_MAX then return line end
    return line:sub(1, CONSOLE_MAX) .. " ..."
end

local function log(level, message)
    local levelOrder = levelsOrder[level] or levelsOrder.INFO
    local minOrder = levelsOrder[logLevel] or levelsOrder.INFO
    -- Hide messages below the configured console level (DEBUG hidden unless requested).
    if levelOrder < minOrder then
        return
    end
    local line = string.format("[%s] [%s] %s", getTime(), level, tostring(message))
    -- Always write to the file; only echo to the console when it's not hidden behind a
    -- full-screen dashboard (consoleVisible == false while monitoring).
    if consoleVisible then
        print(consoleSafe(line))
    end
    pcall(function() appendLogToFile(line) end)
end

function Logger.info(message)
    log(Logger.levels.INFO, message)
end

function Logger.warn(message)
    log(Logger.levels.WARN, message)
end

function Logger.error(message)
    log(Logger.levels.ERROR, message)
end

function Logger.debug(message)
    log(Logger.levels.DEBUG, message)
end

function Logger.getLogPath()
    return logFilePath
end

-- Force the console verbosity from a config value ("DEBUG".."ERROR"), so a save via
-- the Settings menu takes effect without a restart.
function Logger.setLevel(level)
    if level and type(level) == "string" then
        local lvl = level:upper()
        if levelsOrder[lvl] then
            logLevel = lvl
        end
    end
end

function Logger.setLogPath(path)
    if path and type(path) == "string" and path ~= "" then
        logFilePath = path
    end
end

function Logger.setConsoleVisible(visible)
    consoleVisible = visible == true
end

return Logger