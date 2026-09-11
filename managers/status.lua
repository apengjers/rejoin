local Logger = require("core.logger")
local APK = require("managers.apk")
local Auth = require("managers.auth")
local Username = require("managers.username")
local Shell = require("utils.shell")

local Status = {}

-- Per-instance runtime state.
-- instanceId -> {
--   status        = "offline"|"starting"|"ingame"|"stuck"|"freeze"|"nologin"|"recovery"
--   healthySince  = timestamp when the process was first seen running
--   stuckSince    = timestamp when stuck/freeze was first detected (5-min timeout base)
--   anrSeen       = last logcat sequence id that reported an ANR for this package
-- }
local states = {}

-- Defaults / config gate for freeze detection.
local freezeTimeout = 300  -- seconds (RSS-low/proc-stub or ANR -> wait, then relaunch)
local gracePeriod = 30     -- seconds after healthy before judging ingame vs stuck
local anrEnabled = true

function Status.configure(conf)
    conf = conf or {}
    freezeTimeout = tonumber(conf.freezeTimeout) or 300
    gracePeriod = tonumber(conf.gracePeriod) or 30
    anrEnabled = conf.anrCheckEnabled ~= false -- default true
end

function Status.reset()
    states = {}
end

-- Mark an instance as currently being recovered (so the monitor shows "recovery").
function Status.beginRecovery(id)
    local s = states[id] or {}
    s.status = "recovery"
    s.stuckSince = nil
    states[id] = s
end

function Status.endRecovery(id)
    local s = states[id]
    if s and s.status == "recovery" then
        s.status = nil
        -- A successful recovery means the app is genuinely running again; skip the
        -- "starting" grace period so it shows Running immediately on the next check.
        s.forceRunning = true
    end
end

-- Force-hold an instance in "starting" while it is being launched/loaded (used by the
-- Menu 1 sequential launch flow). Cleared with Status.endStarting when it is up.
function Status.beginStarting(id)
    local s = states[id] or {}
    s.startingOverride = true
    s.status = "starting"
    s.stuckSince = nil
    states[id] = s
end

function Status.endStarting(id)
    local s = states[id]
    if s then
        s.startingOverride = nil
    end
end

-- Mark an instance as currently being reset (force-stopped / relaunched / joined), so the
-- monitor shows "Resetting" until the operation finishes. Mirrors recovery handling.
function Status.beginResetting(id)
    local s = states[id] or {}
    s.status = "resetting"
    s.stuckSince = nil
    states[id] = s
end

function Status.endResetting(id)
    local s = states[id]
    if s and s.status == "resetting" then
        s.status = nil
    end
end

-- Read ANR lines from logcat and return a set of package names that (recently) ANR'd.
-- Best-effort: returns empty on failure/without logcat.
local function scanAnrPackages()
    local anr = {}
    if not anrEnabled then return anr end

    local ok, out = Shell.exec("logcat -d -b main -t 1000")
    if not ok or not out or out == "(dry-run)" then
        return anr
    end

    -- ActivityManager emits lines like: "ANR in com.apengjers.v3 (com.apengjers.v3/.X)"
    for line in out:gmatch("[^\r\n]+") do
        local pkg = line:match("ANR in (%S+)")
        if pkg then
            -- drop trailing '(' / component suffix if present
            pkg = pkg:gsub("%s*%(.+$", "")
            anr[pkg] = true
        end
    end
    return anr
end

-- Update the status of a single instance based on its process state and ANR logs.
-- Returns the current status string for convenience.
function Status.check(instance)
    local id = instance.id
    local pkg = instance.package
    local now = os.time()
    local s = states[id] or {}
    states[id] = s

    -- If currently being recovered, reset, or held in a forced "starting" state, keep
    -- that status until it finishes (don't let the normal classifier override it).
    if s.status == "recovery" or s.status == "resetting" or s.startingOverride then
        return s.status
    end

    local procExists = false
    local active = false
    if pkg then
        -- Health is decided from the RSS threshold (isActive): a force-close leaves a
        -- low-RSS stub process alive (~188 MB vs ~1 GB for a running clone), so a process
        -- that exists but stays below the threshold means its UI is gone.
        local okP, resP = pcall(function() return APK.isRunning(pkg) end)
        procExists = okP and resP
        local okA, resA = pcall(function() return APK.isActive(pkg) end)
        active = okA and resA
    end
    local rssKb = pkg and APK.getRSSinKB(pkg) or -1
    s.rssKb = rssKb

    if not procExists then
        -- offline: nothing running
        s.status = "offline"
        s.healthySince = nil
        s.stuckSince = nil
        s.anrSeen = nil
        s.forceRunning = nil
        return s.status
    end

    if not active then
        -- Process alive but RSS below the threshold (force-close stub, or a clone that
        -- is merely sitting on the login screen with little memory).
        --
        -- If the clone has NO logged-in account (Auth.isLoggedIn == false) it is treated
        -- as idle: low RSS is expected, so we mark it "nologin" and never start the
        -- freeze/relaunch clock. On a failed detection (nil) we fall back to the normal
        -- freeze handling so existing behavior is preserved.
        local loggedIn = Auth.isLoggedIn(instance)
        if loggedIn == false then
            s.status = "nologin"
            s.stuckSince = nil
            s.healthySince = nil
            return s.status
        end
        -- Otherwise: the clone is genuinely frozen (force-close stub). Show Freeze;
        -- after freezeTimeout the monitor force-stops and relaunches it.
        s.status = "freeze"
        if not s.stuckSince then s.stuckSince = now end
        s.healthySince = nil
        return s.status
    end

    -- Process is genuinely active (real memory).
    if s.forceRunning then
        -- Recovery/relaunch just succeeded: go straight to Running.
        s.forceRunning = nil
        s.healthySince = nil
        s.status = "ingame"
        s.stuckSince = nil
        return s.status
    end

    if not s.healthySince then
        s.healthySince = now
        s.status = "starting"
        s.stuckSince = nil
        return s.status
    end

    local healthyAge = now - s.healthySince

    -- Freeze detection: ANR present for this package in recent logcat.
    local anr = scanAnrPackages()
    local frozen = anr[pkg] == true
    if frozen then
        s.status = "freeze"
        if not s.stuckSince then s.stuckSince = now end
        return s.status
    end

    -- Not frozen and running; classify by how long it's been healthy.
    if healthyAge < gracePeriod then
        s.status = "starting"
        s.stuckSince = nil
        return s.status
    end

    -- Healthy past the grace period -> ingame.
    s.status = "ingame"
    s.stuckSince = nil
    return s.status
end

-- Whether this instance has been stuck/frozen for at least freezeTimeout seconds.
-- Returns true when it is time to relaunch.
function Status.isFreezeTimeout(id)
    local s = states[id]
    if not s then return false end
    if s.status ~= "freeze" then return false end
    if not s.stuckSince then return false end
    return (os.time() - s.stuckSince) >= freezeTimeout
end

-- ANSI colors
local C = {
    green  = "\27[32m",
    red    = "\27[31m",
    yellow = "\27[33m",
    cyan   = "\27[36m",
    blue   = "\27[34m",
    dim    = "\27[2m",
    reset  = "\27[0m",
}

-- Human label + color for a status (used by the monitor table).
local STATUS_UI = {
    ingame   = { "Running",  C.green },
    stuck    = { "Stuck",    C.red },
    freeze   = { "Freeze",   C.yellow },
    recovery = { "Recovery", C.yellow },
    resetting= { "Resetting", C.yellow },
    starting = { "Starting", C.blue },
    offline  = { "Offline",  C.dim },
    nologin  = { "NoLogin",  C.dim },
}

-- Best-effort memory + storage readout, cached to avoid shell cost every cycle.
local sysCache = { memAt = 0, memLine = nil, diskAt = 0, diskLine = nil }
local SYS_CACHE_TTL = 30

-- Read MemTotal/MemAvailable from /proc/meminfo (kB) via shell.
-- Returns a content line like "58% (860MB Free)" or nil on failure.
local function memoryLine()
    local now = os.time()
    if sysCache.memAt == 0 or (now - sysCache.memAt) >= SYS_CACHE_TTL then
        sysCache.memAt = now
        sysCache.memLine = nil
        local ok, out = Shell.exec("cat /proc/meminfo")
        if ok and out and out ~= "(dry-run)" then
            local total, avail
            for line in out:gmatch("[^\r\n]+") do
                if not total then
                    total = tonumber(line:match("MemTotal:%s*(%d+)"))
                end
                if not avail then
                    avail = tonumber(line:match("MemAvailable:%s*(%d+)"))
                end
            end
            if total and total > 0 then
                local used = avail and (total - avail) or 0
                local pct = math.floor(used / total * 100 + 0.5)
                local freeMb = avail and math.floor(avail / 1024) or 0
                sysCache.memLine = string.format("%d%% (%dMB Free)", pct, freeMb)
            end
        end
    end
    return sysCache.memLine
end

-- Read free space from `df` (best-effort). Picks the storage mount if present
-- (/sdcard, /emulated, or the root mount), else the first real block. Returns a
-- line like "300GB Free" or nil on failure.
local function storageLine()
    local now = os.time()
    if sysCache.diskAt == 0 or (now - sysCache.diskAt) >= SYS_CACHE_TTL then
        sysCache.diskAt = now
        sysCache.diskLine = nil
        local ok, out = Shell.exec("df -h 2>/dev/null")
        if ok and out and out ~= "(dry-run)" then
            local fallbackAvail
            for line in out:gmatch("[^\r\n]+") do
                -- df -h columns: Filesystem Size Used Avail Use% Mounted on
                local avail, mnt = line:match("%S+%s+%S+%s+%S+%s+(%S+)%s+%S+%%%s+(.+)")
                if avail then
                    local isWanted = mnt and (
                        mnt:find("/sdcard", 1, true) or
                        mnt:find("/emulated", 1, true) or
                        mnt == "/"
                    )
                    if isWanted then
                        sysCache.diskLine = avail .. " Free"
                        break
                    end
                    if not fallbackAvail then fallbackAvail = avail end
                end
            end
            if not sysCache.diskLine and fallbackAvail then
                sysCache.diskLine = fallbackAvail .. " Free"
            end
        end
    end
    return sysCache.diskLine
end

-- Height (in terminal rows) of the dashboard frame drawn by the last printSummary
-- call, plus the footer hint row. Used to reposition with cursor-up on the next
-- refresh instead of clearing the whole screen (avoids flicker).
local frameHeight = 0

-- Reset dashboard positioning state (called when a new monitor session starts).
function Status.resetDashboard()
    frameHeight = 0
end

-- Print a colorized status table. The first call draws the frame from the cursor
-- position and records its height; later calls move the cursor up and redraw over the
-- same rows (no full-screen clear), then clear any leftover below. Rows use CRLF so
-- the cursor returns to column 0 each line on Termux (LF alone drifts rows rightward).
-- Pad a plain string into a column cell of `width` wrapping spaces. `text` has no
-- ANSI codes so padding is based on visible characters; color is applied separately.
local function padCell(text, width)
    if #text > width - 2 then text = text:sub(1, width - 2) end
    local pad = width - 2 - #text
    local left = math.floor(pad / 2)
    return " " .. string.rep(" ", left) .. text .. string.rep(" ", pad - left) .. " "
end

local function blankCell(width)
    return string.rep(" ", width)
end

function Status.printSummary(instances)
    local LCOL = 33   -- width of the left (Instance) column
    local RCOL = 23   -- width of the right (Status/Value) column

    local top  = "╭" .. string.rep("─", LCOL) .. "┬" .. string.rep("─", RCOL) .. "╮"
    local mid  = "├" .. string.rep("─", LCOL) .. "┼" .. string.rep("─", RCOL) .. "┤"
    local bot  = "╰" .. string.rep("─", LCOL) .. "┴" .. string.rep("─", RCOL) .. "╯"

    -- One body row. `rightColor`, if given, colors the visible right text only so
    -- every row still aligns on the same column.
    local function bodyRow(left, rightText, rightColor)
        local lc = padCell(left, LCOL)
        local rc = padCell(rightText, RCOL)
        if rightColor then
            local l = math.floor((RCOL - 2 - #rightText) / 2)
            rc = " " .. string.rep(" ", l) .. rightColor .. rightText .. C.reset
                 .. string.rep(" ", (RCOL - 2 - #rightText) - l) .. " "
        end
        return "│" .. lc .. "│" .. rc .. "│"
    end

    local function blankRow()
        return "│" .. blankCell(LCOL) .. "│" .. blankCell(RCOL) .. "│"
    end

    local sb = {}
    table.insert(sb, top)
    table.insert(sb, blankRow())
    table.insert(sb, bodyRow("Instance", "Status"))
    table.insert(sb, blankRow())
    table.insert(sb, mid)

    if not instances or #instances == 0 then
        table.insert(sb, bodyRow("(no instances)", "Offline", C.dim))
        table.insert(sb, mid)
    else
        for _, inst in ipairs(instances) do
            local id = inst.id or inst.name or "?"
            local pkg = inst.package or inst.name or tostring(id)
            local s = states[id]
            local status = s and s.status or "offline"
            local ui = STATUS_UI[status] or { status, C.dim }
            local label = ui[1] or "Unknown"
            local uname = nil
            pcall(function() uname = Username.get(inst) end)
            local rowText = uname and (pkg .. " (" .. tostring(uname) .. ")") or pkg
            table.insert(sb, bodyRow(rowText, label, ui[2]))
        end
        table.insert(sb, mid)
    end

    table.insert(sb, bodyRow("Memory Usage", memoryLine() or "--"))
    table.insert(sb, bodyRow("Storage Available", storageLine() or "--"))
    table.insert(sb, bot)

    -- Footer hint below the table.
    table.insert(sb, " ")
    table.insert(sb, C.dim .. "(tekan Ctrl+C untuk berhenti)" .. C.reset)

    -- Reposition on top of the previous frame if we already drew one, then redraw.
    if frameHeight > 0 then
        io.write("\27[" .. frameHeight .. "A")
    end
    io.write("\27[?25l")                                  -- hide cursor (smoother refresh)
    io.write(table.concat(sb, "\r\n") .. "\r\n")          -- CRLF so every row resets column
    io.write("\27[J")                                     -- clear any leftover below
    frameHeight = #sb                                     -- full frame incl. footer
    io.write("\27[?25h")                                  -- show cursor again
    io.flush()
end

return Status
