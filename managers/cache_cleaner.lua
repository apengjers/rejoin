local Logger = require("core.logger")
local Shell = require("utils.shell")
local Config = require("core.config")

-- Clears an app's cache the same way Android's Settings "Clear cache" button does
-- (internal cache + code_cache + WebView caches + external cache), so each clone boots
-- fresh instead of piling up temp/WebView data that bloats storage and RAM.
--
-- NOTE: there is NO `pm clear-cache` command in Android (Settings uses an internal
-- binder API, not `pm`), so we wipe the cache directories directly with `rm -rf` after
-- the app has been force-stopped. Android recreates the dirs with the right
-- owner/permissions on next app start.
--
-- SAFE BY DESIGN: never touches cookies (.ROBLOSECURITY), Local Storage, shared_prefs,
-- databases or files/ - deleting those would log the clone out / break game data.
--
-- IMPORTANT: only call after the app has been force-stopped (see recovery.lua), so no
-- running process holds open files. Warm-start paths never clear.

local CacheCleaner = {}

local function safeConfig()
    local ok, conf = pcall(function() return Config.get() end)
    if not ok or type(conf) ~= "table" then return {} end
    return conf or {}
end

-- Current cache-cleaner config: { enabled, clearWebView }.
function CacheCleaner.getConfig()
    local cc = safeConfig().cacheCleaner
    if type(cc) ~= "table" then cc = {} end
    return {
        enabled = cc.enabled ~= false,
        clearWebView = cc.clearWebView ~= false,
    }
end

-- Quote a path for the shell so spaces (e.g. "Service Worker") survive su -c wrapping.
local function quote(path)
    path = path:gsub("'", "'\\''")
    return "'" .. path .. "'"
end

-- Internal cache dirs (cleared by Settings' "Clear cache"; recreated automatically).
local BASE_DIRS = { "cache", "code_cache" }
-- WebView cache directories (also pure cache, never login data).
local WEBVIEW_DIRS = {
    "app_webview/Default/Cache",
    "app_webview/Default/Service Worker",
    "app_webview/Default/Code Cache",
    "app_webview/Default/GPUCache",
}
-- External cache dirs (second half of Settings' "Cache" number).
local EXTERNAL_DIRS = { "cache" }

-- Build (paths-for-du, dirs-for-rm) for one clone package.
local function buildTargets(pkg)
    local cfg = CacheCleaner.getConfig()
    local data = "/data/data/" .. pkg
    local ext = "/sdcard/Android/data/" .. pkg
    local paths, dirs = {}, {}
    local function add(base, names)
        for _, n in ipairs(names) do
            paths[#paths + 1] = quote(base .. "/" .. n)
            dirs[#dirs + 1] = quote(base .. "/" .. n)
        end
    end
    add(data, BASE_DIRS)
    if cfg.clearWebView then
        add(data, WEBVIEW_DIRS)
    end
    add(ext, EXTERNAL_DIRS)
    return paths, dirs
end

-- Clear one clone's cache with a single su shell call and log measured bytes
-- before/after (proof the wipe actually worked). Best-effort: never throws.
function CacheCleaner.applyForInstance(instance)
    local cfg = CacheCleaner.getConfig()
    if not cfg.enabled then return false end
    local pkg = instance and instance.package
    if not pkg or pkg == "" then return false end

    local paths, dirs = buildTargets(pkg)
    if #dirs == 0 then return false end

    local joinedPaths = table.concat(paths, " ")
    local joinedDirs = table.concat(dirs, " ")
    local du = "du -sb " .. joinedPaths .. " 2>/dev/null | awk '{s+=$1} END{print s+0}'"
    local cmd = string.format(
        "before=$(%s); %s; after=$(%s); echo \"before=\"$before\" after=\"$after",
        du, "rm -rf " .. joinedDirs, du
    )

    local out = ""
    pcall(function()
        local _, o = Shell.exec(cmd)
        out = (o or ""):gsub("\n+$", "")
    end)

    Logger.info(string.format("CacheCleaner[%s]: %s", pkg, out ~= "" and out or "(no output)"))
    return true
end

-- Clear cache for all configured instances.
function CacheCleaner.applyAll()
    local ok, conf = pcall(function() return Config.get() end)
    if not ok or not conf or type(conf.instances) ~= "table" then return 0 end
    if not CacheCleaner.getConfig().enabled then return 0 end

    local applied = 0
    for _, inst in ipairs(conf.instances) do
        if CacheCleaner.applyForInstance(inst) then applied = applied + 1 end
    end
    return applied
end

return CacheCleaner