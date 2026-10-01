local Logger = require("core.logger")
local Shell = require("utils.shell")
local Config = require("core.config")
local Runtime = require("core.runtime")

-- Only disposable cache directories are targeted. Cookies, Local Storage,
-- shared_prefs, databases and files are deliberately outside this list.
local CacheCleaner = {}

local BASE_DIRS = { "cache", "code_cache" }
local WEBVIEW_DIRS = {
    "app_webview/Default/Cache",
    "app_webview/Default/Service Worker",
    "app_webview/Default/Code Cache",
    "app_webview/Default/GPUCache",
}

local function config()
    local ok, conf = pcall(Config.get)
    return ok and type(conf) == "table" and conf or {}
end

function CacheCleaner.getConfig()
    local cc = config().cacheCleaner
    if type(cc) ~= "table" then cc = {} end
    return { enabled = cc.enabled ~= false, clearWebView = cc.clearWebView ~= false }
end

local function validPackage(pkg)
    return type(pkg) == "string" and pkg:match("^[%a_][%w_%.]*$") ~= nil
        and pkg:find(".", 1, true) ~= nil and pkg:find("..", 1, true) == nil
        and pkg:sub(-1) ~= "."
end

local function quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function targets(pkg)
    local paths = {}
    local function add(base, names)
        for _, name in ipairs(names) do
            paths[#paths + 1] = quote(base .. "/" .. name)
        end
    end
    add("/data/data/" .. pkg, BASE_DIRS)
    if CacheCleaner.getConfig().clearWebView then
        add("/data/data/" .. pkg, WEBVIEW_DIRS)
    end
    add("/sdcard/Android/data/" .. pkg, { "cache" })
    return table.concat(paths, " ")
end

local function processState(pkg)
    -- Termux without root may hide other apps' processes, so "not seen" is not
    -- proof that a clone is stopped.
    if config().useRoot == false then return nil, nil, "root_required" end
    local ok, out = Shell.exec("ps -A")
    if not ok or not out or out == "(dry-run)" then return nil, nil, "process_scan_failed" end
    local running, rssKiB, sawProcess = false, nil, false
    for line in out:gmatch("[^\r\n]+") do
        local fields = {}
        for field in line:gmatch("%S+") do fields[#fields + 1] = field end
        if tonumber(fields[2]) then sawProcess = true end
        local name = fields[#fields]
        if name == pkg or (name and name:sub(1, #pkg + 1) == pkg .. ":") then
            running = true
            if name == pkg then rssKiB = tonumber(fields[5]) end
        end
    end
    if not sawProcess then return nil, nil, "process_scan_failed" end
    return running, rssKiB
end

-- Returns { running, rssMiB, cacheKiB } or nil, reason. A failed process probe
-- is unknown, never interpreted as "stopped".
function CacheCleaner.inspectForInstance(instance)
    local pkg = instance and instance.package
    if not validPackage(pkg) then return nil, "invalid_package" end
    local running, rssKiB, err = processState(pkg)
    if running == nil then return nil, err end
    local ok, out = Shell.exec("du -sk " .. targets(pkg) .. " 2>/dev/null | awk '{s+=$1} END{print s+0}'")
    local cacheKiB = ok and tonumber((out or ""):match("^%s*(%d+)%s*$")) or nil
    return { running = running, rssMiB = rssKiB and math.floor(rssKiB / 1024) or nil,
        cacheKiB = cacheKiB }
end

-- Recovery calls this only after a successful force-stop. Manual calls first
-- verify the process is stopped; the shell checks again immediately before rm.
function CacheCleaner.applyForInstance(instance, options)
    options = options or {}
    if not options.manual and not CacheCleaner.getConfig().enabled then return false, "disabled" end
    local pkg = instance and instance.package
    if not validPackage(pkg) then return false, "invalid_package" end
    if Runtime.isDryRun() then return false, "dry_run" end

    local running, _, err = processState(pkg)
    if running == nil then return false, err end
    if running then return false, "running" end

    local paths = targets(pkg)
    local du = "du -sk " .. paths .. " 2>/dev/null | awk '{s+=$1} END{print s+0}'"
    local cmd = "processes=$(ps -A) || exit 41; "
        .. "if printf '%s\\n' \"$processes\" | awk -v pkg=" .. quote(pkg)
        .. " '{name=$NF; if (name==pkg || index(name,pkg \":\")==1) exit 1}'; "
        .. "then :; else echo RUNNING; exit 42; fi; "
        .. "before=$(" .. du .. "); rm -rf " .. paths .. " || exit 43; "
        .. "after=$(" .. du .. "); echo before=$before after=$after"
    -- Shell.exec prefixes `timeout`; wrap compound statements as one command.
    local ok, out = Shell.exec("sh -c " .. quote(cmd))
    if not ok then
        local reason = out and out:find("RUNNING", 1, true) and "running" or "clear_failed"
        Logger.warn("CacheCleaner[" .. pkg .. "]: " .. reason)
        return false, reason
    end
    local before, after = (out or ""):match("before=(%d+)%s+after=(%d+)")
    if not before or not after then return false, "invalid_result" end
    local freedKiB = math.max(0, tonumber(before) - tonumber(after))
    Logger.info(string.format("CacheCleaner[%s]: freed=%d KiB", pkg, freedKiB))
    return true, nil, freedKiB
end

function CacheCleaner.applyAll(options)
    local conf = config()
    if type(conf.instances) ~= "table" then return 0, 0, 0 end
    local cleared, skipped, failed = 0, 0, 0
    for _, inst in pairs(conf.instances) do
        if type(inst) == "table" then
            local ok, reason = CacheCleaner.applyForInstance(inst, options)
            if ok then cleared = cleared + 1
            elseif reason == "running" or reason == "disabled" then skipped = skipped + 1
            else failed = failed + 1 end
        end
    end
    return cleared, skipped, failed
end

return CacheCleaner
