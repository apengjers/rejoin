local Logger = require("core.logger")
local File = require("utils.file")
local Config = require("core.config")
local Shell = require("utils.shell")

-- Script Manager.
--
-- The user writes `.lua` scripts from Termux; Rejoin stores them GLOBALLY (shared by
-- every instance) under the deploy folder (`conf.autoExecuteDeployPath`, default
-- `data/autoexecute`) and, on request, copies them into the app's autoexecute folder
-- via `conf.appAutoExecutePath` (e.g. `/sdcard/Delta/Autoexecute`).
--
-- Rejoin is only a SCRIPT MANAGER: the user writes all the actual logic (detection /
-- response / farming) inside each script. Deployment is manual (from the menu).
--
-- The target folder is shared across all instances; each script `<name>.lua` is
-- copied as-is to `<appAutoExecutePath>/<name>.lua`.

local AutoExecute = {}

-- Where global scripts live on the Termux side.
function AutoExecute.dir()
    local conf = Config.get() or {}
    return conf.autoExecuteDeployPath or "data/autoexecute"
end

-- List global scripts (names of `*.lua`) in the deploy folder.
function AutoExecute.list()
    local dir = AutoExecute.dir()
    local names, err = File.listDir(dir, "lua")
    if not names then return nil, err end
    local out = {}
    for _, n in ipairs(names) do
        local p = dir .. "/" .. n
        local size = 0
        local content = File.read(p)
        if content then size = #content end
        table.insert(out, { name = n, size = size, path = p })
    end
    return out
end

-- Save (create or overwrite) a global script.
function AutoExecute.save(name, content)
    name = name and name:gsub("[^%w%._%-]", "_") or ""
    name = name:gsub("%.lua$", "")
    if name == "" then return false, "invalid_name" end
    local file = AutoExecute.dir() .. "/" .. name .. ".lua"
    local ok, err = File.write(file, content)
    if not ok then return false, err end
    return true, file
end

-- Read a global script's content back.
function AutoExecute.read(name)
    name = name and name:gsub("%.lua$", "") or ""
    if name == "" then return nil, "invalid_name" end
    return File.read(AutoExecute.dir() .. "/" .. name .. ".lua")
end

-- Remove a global script. Returns (true) or (false, err).
function AutoExecute.remove(name)
    name = name and name:gsub("%.lua$", "") or ""
    if name == "" then return false, "invalid_name" end
    local file = AutoExecute.dir() .. "/" .. name .. ".lua"
    if not File.exists(file) then return false, "not_found" end
    local ok = os.remove(file)
    if not ok then return false, "remove_failed" end
    return true
end

-- Resolve the target autoexecute path from config.
-- The user MUST set config.appAutoExecutePath (used for every instance; shared path).
-- Returns (destBase, effective) or (nil, errMsg).
local function appDestBase()
    local conf = Config.get() or {}
    local base = conf.appAutoExecutePath
    if not base or base == "" then
        return nil, "appAutoExecutePath is empty (set it in config/config.lua)"
    end
    return base, true
end

-- Copy one script into the app's autoexecute folder. Returns (true, dest) or (false, err).
-- Ensures the destination directory exists (mkdir -p) before copying. The actual cp is
-- handled by Shell.exec which wraps with su -c automatically when useRoot is enabled.
local function suCopyIntoApp(src, dest)
    -- Create destination directory if it doesn't exist (no-op if already there).
    local dir = dest:match("(.+)/[^/]+$")
    if dir then
        pcall(function() return Shell.exec(string.format("mkdir -p '%s'", dir)) end)
    end
    -- Single cp attempt — Shell.exec handles su -c wrapping when useRoot=true.
    local ok, _ = pcall(function() return Shell.exec(string.format("cp '%s' '%s'", src, dest)) end)
    if ok and File.exists(dest) then
        return true, dest
    end
    return false, "copy_failed"
end

-- Deploy a single global script to every configured instance.
function AutoExecute.deployOne(name)
    name = name and name:gsub("%.lua$", "") or ""
    if name == "" then return false, "invalid_name" end
    local src = AutoExecute.dir() .. "/" .. name .. ".lua"
    if not File.exists(src) then return false, "not_found" end

    local base, err = appDestBase()
    if not base then return false, err or "no_app_path" end

    local conf = Config.get() or {}
    local okCount, errors = 0, {}
    for _, inst in ipairs(conf.instances or {}) do
        local dest = base .. "/" .. name .. ".lua"
        local ok, e = suCopyIntoApp(src, dest)
        if ok then
            okCount = okCount + 1
            Logger.info(string.format("AutoExecute: deployed %s -> %s (%s)", name, dest, tostring(inst.package)))
        else
            table.insert(errors, string.format("%s: %s", tostring(inst.package or "?"), tostring(e)))
        end
    end
    if okCount == 0 then
        return false, table.concat(errors, "; ")
    end
    return true, { ok = okCount, errors = errors }
end

-- Deploy every global script to every configured instance.
function AutoExecute.deployAll()
    local list, err = AutoExecute.list()
    if not list then return false, err or "no_scripts" end
    if #list == 0 then return false, "no_scripts" end
    local ok, res = true, { okCount = 0, errors = {} }
    for _, s in ipairs(list) do
        local name = s.name:gsub("%.lua$", "")
        local okOne, resOne = AutoExecute.deployOne(name)
        if okOne then
            res.okCount = res.okCount + (resOne and resOne.ok or 1)
        else
            ok = false
            table.insert(res.errors, string.format("%s: %s", name, tostring(resOne)))
        end
    end
    return ok, res
end

return AutoExecute
