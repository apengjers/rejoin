local Logger = require("core.logger")
local Shell = require("utils.shell")
local Config = require("core.config")

-- Clears an app's cache right after a cold start (force-stop -> launch) so each clone
-- boots fresh instead of piling up temp/WebView data that bloats storage and RAM.
--
-- Strategy (root-only):
--   * `pm clear-cache` clears the app's native/ART caches (the same thing Android's
--     "Clear cache" button does) without touching logins/data.
--   * `clearWebView` additionally wipes the WebView cache dirs (Chromium HTTP cache,
--     service worker, V8 code cache, GPU cache) - the heaviest bloat on Roblox clones.
--
-- SAFE BY DESIGN: we NEVER touch `/cache`'s Cookies DB (.ROBLOSECURITY lives there),
-- Local Storage, shared_prefs or databases - deleting those would log the clone out.
-- All cleared dirs are recreated automatically by the OS/app on next launch.
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

-- WebView cache directories (recreated automatically). Every path is a pure cache,
-- never login data.
local WEBVIEW_DIRS = {
    "app_webview/Default/Cache",
    "app_webview/Default/Service Worker",
    "app_webview/Default/Code Cache",
    "app_webview/Default/GPUCache",
}

-- Clear one clone's cache with a single su shell call. Best-effort: never throws.
function CacheCleaner.applyForInstance(instance)
    local cfg = CacheCleaner.getConfig()
    if not cfg.enabled then return false end
    local pkg = instance and instance.package
    if not pkg or pkg == "" then return false end

    local base = "/data/data/" .. pkg
    local parts = { "pm clear-cache " .. pkg .. " 2>/dev/null" }
    if cfg.clearWebView then
        for _, dir in ipairs(WEBVIEW_DIRS) do
            parts[#parts + 1] = "rm -rf " .. quote(base .. "/" .. dir) .. " 2>/dev/null"
        end
    end

    local cmd = table.concat(parts, "; ")
    local ok = pcall(function() return Shell.exec(cmd) end)
    Logger.info(string.format("CacheCleaner: cleared cache for %s (clearWebView=%s)", pkg, tostring(cfg.clearWebView)))
    return ok
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