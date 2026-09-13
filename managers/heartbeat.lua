local Logger = require("core.logger")
local Shell = require("utils.shell")

-- Heartbeat monitoring (HTTP-based).
--
-- Roblox clones (Delta AutoExecute) POST "still alive" signals to a tiny Python
-- server on 127.0.0.1 that Rejoin spawns/stops alongside the monitor. The server
-- writes a state file (one `key=epoch` per line) that we read here each monitor
-- cycle — no network calls from the Lua side, no cjson dependency.
--
-- Identity: heartbeats are keyed by `instance.heartbeatKey` when set, else by the
-- cloned account's username (Username.get). That maps a signal back to exactly one
-- package, so a missing signal freezes/relaunches only the right clone.

local Heartbeat = {}

local conf = {
    enabled = false,
    host    = "127.0.0.1",
    port    = 8080,
    endpoint = "/heartbeat",
    timeout = 30,
    statePath = "data/heartbeat_state.txt",
}

local CACHE_TTL = 5       -- seconds between state-file reads
local stateCache = { at = 0, data = nil }
local pidPath = ""

local function rootAbs(p)
    if not p or p == "" then return p end
    if p:match("^/") then return p end
    local home = os.getenv("HOME") or ""
    if home == "" then return p end
    return home .. "/rejoin/" .. p
end

function Heartbeat.isEnabled()
    return conf.enabled
end

function Heartbeat.configure(c)
    c = c or {}
    conf.enabled = c.enabled == true
    conf.host     = c.host or "127.0.0.1"
    conf.port     = tonumber(c.port) or 8080
    conf.endpoint = c.endpoint or "/heartbeat"
    conf.timeout  = tonumber(c.timeout) or 30
    conf.statePath = c.statePath or "data/heartbeat_state.txt"
    pidPath = rootAbs("data/heartbeat_server.pid")
end

local function readState()
    local now = os.time()
    if stateCache.at ~= 0 and (now - stateCache.at) < CACHE_TTL then
        return stateCache.data
    end
    local data = {}
    local f = io.open(conf.statePath, "r")
    if f then
        local s = f:read("*a")
        f:close()
        for line in (s or ""):gmatch("[^\r\n]+") do
            local k, v = line:match("^([^=]+)=(%d+)$")
            if k and v then data[k] = tonumber(v) end
        end
    end
    stateCache = { at = now, data = data }
    return data
end

local User = nil
local function resolveKey(inst)
    if not inst then return nil end
    if inst.heartbeatKey and inst.heartbeatKey ~= "" then
        return inst.heartbeatKey
    end
    if not User then pcall(function() User = require("managers.username") end) end
    if User then
        local ok, u = pcall(function() return User.get(inst) end)
        if ok and u and u ~= "" then return u end
    end
    return nil
end

-- Evaluate one instance: returns (alive, stale, seen).
--   alive   = heartbeat present and younger than timeout
--   stale   = heartbeat seen before but older than timeout
--   seen    = this instance's key has EVER appeared in the state file
-- When not enabled, or the key was never seen, returns false/false/false so the
-- caller falls back to the normal RSS/proc logic.
function Heartbeat.evaluate(inst)
    if not conf.enabled then return false, false, false end
    local key = resolveKey(inst)
    if not key then return false, false, false end
    local state = readState()
    local last = state[key]
    if not last then return false, false, false end
    local age = os.time() - last
    if age <= conf.timeout then
        return true, false, true
    end
    return false, true, true
end

-- Convenience: is this instance heartbeat-alive right now?
function Heartbeat.alive(inst)
    local a, _, seen = Heartbeat.evaluate(inst)
    return conf.enabled and seen and a
end

-- Start the Python heartbeat server in the background (spawned via su, so use
-- absolute paths — su's cwd is /, not $HOME/rejoin). Kills any stale pid first.
function Heartbeat.start()
    if not conf.enabled then return end
    if pidPath ~= "" then
        local f = io.open(pidPath, "r")
        if f then
            local pid = f:read("*a"):match("%d+")
            f:close()
            if pid then pcall(function() Shell.exec("kill " .. pid .. " 2>/dev/null") end) end
        end
    end

    local script = rootAbs("scripts/heartbeat_server.py")
    local state  = rootAbs(conf.statePath)
    local logAbs = rootAbs("data/heartbeat_server.log")
    local cmd = string.format(
        "(P=\"$(command -v python || command -v python3)\"; [ -n \"$P\" ] && { nohup \"$P\" '%s' --state '%s' --port %d > '%s' 2>&1 & echo $! > '%s'; })",
        script, state, conf.port, logAbs, pidPath)
    local ok, _, out = pcall(function() return Shell.exec(cmd) end)

    os.execute("sleep 1")
    local started = false
    local f = io.open(pidPath, "r")
    if f then
        started = (f:read("*a"):match("%d+") ~= nil)
        f:close()
    end
    if not started then
        Logger.warn("Heartbeat: server gagal start (cek data/heartbeat_server.log)")
        return false
    end
    Logger.info(string.format("Heartbeat: server jalan di %s:%d (state=%s)",
        conf.host, conf.port, conf.statePath))
    return true
end

-- Stop the Python heartbeat server (called when the monitor stops).
function Heartbeat.stop()
    if pidPath == "" then return end
    local f = io.open(pidPath, "r")
    if not f then return end
    local pid = f:read("*a"):match("%d+")
    f:close()
    if pid then
        pcall(function() Shell.exec("kill " .. pid .. " 2>/dev/null") end)
        Logger.info("Heartbeat: server dihentikan (pid " .. pid .. ")")
    end
end

return Heartbeat