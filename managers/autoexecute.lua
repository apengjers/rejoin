local Logger = require("core.logger")
local File = require("utils.file")
local Config = require("core.config")

-- AutoExecute manager — manages configuration.
--
-- The user writes `.lua` scripts that Delta executes on launch. Rejoin manages them
-- DIRECTLY inside the app's autoexecute folder (`conf.appAutoExecutePath`, e.g.
-- `/sdcard/Delta/Autoexecute`). No separate staging folder, no deploy step:
-- Add / Edit / Delete write straight to that folder via absolute paths.
--
-- Before reads/writes the target folder is ensured to exist (mkdir -p), so the
-- manager works even when the folder hasn't been created yet.

local AutoExecute = {}

-- Absolute path of the app autoexecute folder managed by this module.
local function appDir()
    local conf = Config.get() or {}
    local dir = conf.appAutoExecutePath
    if not dir or dir == "" then
        return nil, "appAutoExecutePath is empty (set it in config/config.lua)"
    end
    -- Expect absolute paths. Relative paths break when commands later run through
    -- su -c (whose working dir is /, not the Lua cwd).
    if not dir:match("^/") then
        Logger.warn("AutoExecute: appAutoExecutePath should be absolute (got: " .. tostring(dir) .. ")")
    end
    return dir
end

-- Resolve the managed app folder (helper that errors cleanly).
local function resolveDir(errLabel)
    local dir, err = appDir()
    if not dir then return nil, err or "no_app_path" end
    -- Ensure the folder exists so every operation below can assume it.
    pcall(function()
        local Shell = require("utils.shell")
        Shell.exec(string.format("mkdir -p '%s'", dir))
    end)
    return dir
end

-- List scripts (names of *.lua) in the app autoexecute folder.
function AutoExecute.list()
    local dir, err = resolveDir()
    if not dir then return nil, err end
    local names, lerr = File.listDir(dir, "lua")
    if not names then return nil, lerr end
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

-- Save (create or overwrite) a script directly into the app folder.
function AutoExecute.save(name, content)
    name = name and name:gsub("[^%w%._%-]", "_") or ""
    name = name:gsub("%.lua$", "")
    if name == "" then return false, "invalid_name" end
    local dir, err = resolveDir()
    if not dir then return false, err end
    local file = dir .. "/" .. name .. ".lua"
    local ok, werr = File.write(file, content)
    if not ok then return false, werr or "write_failed" end
    Logger.info(string.format("AutoExecute: saved %s", file))
    return true, file
end

-- Read a script's content back.
function AutoExecute.read(name)
    name = name and name:gsub("%.lua$", "") or ""
    if name == "" then return nil, "invalid_name" end
    local dir, err = resolveDir()
    if not dir then return nil, err end
    return File.read(dir .. "/" .. name .. ".lua")
end

-- Remove a script from the app folder. Returns (true) or (false, err).
function AutoExecute.remove(name)
    name = name and name:gsub("%.lua$", "") or ""
    if name == "" then return false, "invalid_name" end
    local dir, err = resolveDir()
    if not dir then return false, err end
    local file = dir .. "/" .. name .. ".lua"
    if not File.exists(file) then return false, "not_found" end
    local ok = os.remove(file)
    if not ok then return false, "remove_failed" end
    Logger.info(string.format("AutoExecute: removed %s", file))
    return true
end

return AutoExecute