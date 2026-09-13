local Logger = require("core.logger")
local APK = require("managers.apk")
local Auth = require("managers.auth")
local Username = require("managers.username")
local Heartbeat = require("managers.heartbeat")
local Shell = require("utils.shell")

local Status = {}

-- Per-instance runtime state, keyed by PACKAGE name (unique per clone, so a wrong id
-- never bleeds into another clone's state — status dibaca per package 1-1).
-- package -> {
--   status        = "offline"|"starting"|"ingame"|"running"|"stuck"|"freeze"|"nologin"|"recovery"
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

-- Normalize the identity used as the state key: instances are keyed by package (unique
-- per clone) so a wrong id never bleeds into another clone's state. Accepts an instance
-- table or a raw key for safety.
local function keyOf(x)
    return type(x) == "table" and (x.package or x.id) or x
end

-- Mark an instance as currently being recovered (so the monitor shows "recovery").
function Status.beginRecovery(inst)
    local k = keyOf(inst)
    local s = states[k] or {}
    s.status = "recovery"
    s.stuckSince = nil
    states[k] = s
end

function Status.endRecovery(inst)
    local s = states[keyOf(inst)]
    if s and s.status == "recovery" then
        s.status = nil
        -- A successful recovery means the app is genuinely running again; skip the
        -- "starting" grace period so it shows Running immediately on the next check.
        s.forceRunning = true
    end
end

-- Force-hold an instance in "starting" while it is being launched/loaded (used by the
-- Menu 1 sequential launch flow). Cleared with Status.endStarting when it is up.
function Status.beginStarting(inst)
    local k = keyOf(inst)
    local s = states[k] or {}
    s.startingOverride = true
    s.status = "starting"
    s.stuckSince = nil
    states[k] = s
end

function Status.endStarting(inst)
    local s = states[keyOf(inst)]
    if s then
        s.startingOverride = nil
    end
end

-- Mark an instance as currently being reset (force-stopped / relaunched / joined), so the
-- monitor shows "Resetting" until the operation finishes. Mirrors recovery handling.
function Status.beginResetting(inst)
    local k = keyOf(inst)
    local s = states[k] or {}
    s.status = "resetting"
    s.stuckSince = nil
    states[k] = s
end

function Status.endResetting(inst)
    local s = states[keyOf(inst)]
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
    local pkg = instance.package
    local now = os.time()
    local s = states[pkg] or {}
    states[pkg] = s

    -- If currently being recovered, reset, or held in a forced "starting" state, keep
    -- that status until it finishes (don't let the normal classifier override it).
    if s.status == "recovery" or s.status == "resetting" or s.startingOverride then
        return s.status
    end

    -- Process evidence (shared by the heartbeat-strict branch and the RSS classifier):
    -- a force-close leaves a low-RSS stub process alive (~188 MB vs ~1 GB for a
    -- running clone), so "exists but below threshold" means the UI is gone.
    local procExists = false
    local active = false
    if pkg then
        local okP, resP = pcall(function() return APK.isRunning(pkg) end)
        procExists = okP and resP
        local okA, resA = pcall(function() return APK.isActive(pkg) end)
        active = okA and resA
    end
    local rssKb = pkg and APK.getRSSinKB(pkg) or -1
    s.rssKb = rssKb

    -- Heartbeat override (authoritative when enabled): the in-game script signals it
    -- is alive, so a fresh signal proves the clone is actually executing and a missing
    -- one means the game is frozen — regardless of RSS/proc readings.
    if Heartbeat.isEnabled() then
        local alive, stale, seen = Heartbeat.evaluate(instance)
        if seen then
            local loggedIn = Auth.isLoggedIn(instance)
            if alive then
                -- Script is sending signals -> execution confirmed -> "Running".
                s.status = "running"
                s.stuckSince = nil
                s.healthySince = nil
                s.forceRunning = nil
                s.silentSince = nil
                return s.status
            elseif loggedIn == false then
                -- Signal gone but no account is logged in: treat as idle, never freeze.
                s.status = "nologin"
                s.stuckSince = nil
                s.healthySince = nil
                s.forceRunning = nil
                s.silentSince = nil
                return s.status
            else
                -- Signal expired -> frozen; start the relaunch clock (freezeTimeout).
                s.status = "freeze"
                if not s.stuckSince then s.stuckSince = now end
                s.healthySince = nil
                s.forceRunning = nil
                s.silentSince = nil
                return s.status
            end
        elseif Heartbeat.strictFor(instance) then
            -- Server-first (strict), belum pernah ada sinyal: kalau server ON dan clone
            -- ini DIHARAPKAN ngirim sinyal (key ter-resolve + login aktif + proses hidup)
            -- tapi sudah diam > noSignalGrace -> Freeze (recovery/relaunch). Kalau
            -- prasyaratnya belum lengkap (key nil / logout / proses mati / server OFF)
            -- timer tidak dijalankan -> RSS safety yang decide (Ingame/Offline/NoLogin).
            if not active then
                s.silentSince = nil
            else
                local serverUp = false
                pcall(function() serverUp = Heartbeat.serverInfo().running == true end)
                local keyKnown = Heartbeat.keyFor(instance) ~= nil
                local loggedIn = Auth.isLoggedIn(instance)
                if serverUp and keyKnown and loggedIn == true then
                    if not s.silentSince then s.silentSince = now end
                    if (now - s.silentSince) >= Heartbeat.noSignalGrace() then
                        s.status = "freeze"
                        if not s.stuckSince then s.stuckSince = now end
                        s.healthySince = nil
                        s.forceRunning = nil
                        return s.status
                    end
                    -- Masih dalam grace window: proses hidup tapi server belum pernah
                    -- dengar -> jujur "ingame" (bukan "running"), nolak utk di-relaunch.
                    s.status = "ingame"
                    s.stuckSince = nil
                    s.healthySince = nil
                    s.forceRunning = nil
                    return s.status
                else
                    s.silentSince = nil
                end
            end
        end
    end

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
        -- freeze/relaunch clock.
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
        -- Recovery/relaunch just succeeded: skip the starting grace period.
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
function Status.isFreezeTimeout(inst)
    local s = states[keyOf(inst)]
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
    ingame   = { "Ingame",  C.green },
    running  = { "Running", C.green },
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
    local HBCOL = 10  -- width of the heartbeat column (sinyal "masih hidup" per clone)
    local RCOL = 23   -- width of the right (Status/Value) column

    local top  = "╭" .. string.rep("─", LCOL) .. "┬" .. string.rep("─", HBCOL) .. "┬" .. string.rep("─", RCOL) .. "╮"
    local mid  = "├" .. string.rep("─", LCOL) .. "┼" .. string.rep("─", HBCOL) .. "┼" .. string.rep("─", RCOL) .. "┤"
    local bot  = "╰" .. string.rep("─", LCOL) .. "┴" .. string.rep("─", HBCOL) .. "┴" .. string.rep("─", RCOL) .. "╯"

    -- One body row. `rightColor`, if given, colors the visible right text only so
    -- every row still aligns on the same column. `hbText`/`hbColor` fill the HB cell.
    local function bodyRow(left, rightText, rightColor, hbText, hbColor)
        local lc = padCell(left, LCOL)
        local rc = padCell(rightText, RCOL)
        if rightColor then
            local l = math.floor((RCOL - 2 - #rightText) / 2)
            rc = " " .. string.rep(" ", l) .. rightColor .. rightText .. C.reset
                 .. string.rep(" ", (RCOL - 2 - #rightText) - l) .. " "
        end
        local hb
        if hbText then
            hb = padCell(hbText, HBCOL)
            if hbColor then
                local l = math.floor((HBCOL - 2 - #hbText) / 2)
                hb = " " .. string.rep(" ", l) .. hbColor .. hbText .. C.reset
                     .. string.rep(" ", (HBCOL - 2 - #hbText) - l) .. " "
            end
        else
            hb = blankCell(HBCOL)
        end
        return "│" .. lc .. "│" .. hb .. "│" .. rc .. "│"
    end

    local function blankRow()
        return "│" .. blankCell(LCOL) .. "│" .. blankCell(HBCOL) .. "│" .. blankCell(RCOL) .. "│"
    end

    local sb = {}
    table.insert(sb, top)
    table.insert(sb, blankRow())
    table.insert(sb, bodyRow("Instance", "Status", nil, "HB", nil))
    table.insert(sb, blankRow())
    table.insert(sb, mid)

    if not instances or #instances == 0 then
        table.insert(sb, bodyRow("(no instances)", "Offline", C.dim, "-", C.dim))
        table.insert(sb, mid)
    else
        for _, inst in ipairs(instances) do
            local pkg = inst.package or inst.name or tostring(inst.id or "?")
            local s = states[pkg]
            local status = s and s.status or "offline"
            local ui = STATUS_UI[status] or { status, C.dim }
            local label = ui[1] or "Unknown"
            local uname = nil
            pcall(function() uname = Username.get(inst) end)
            local rowText = uname and (pkg .. " (" .. tostring(uname) .. ")") or pkg

            -- Heartbeat cell: umur sinyal terakhir bila sudah pernah terima, "-" bila
            -- belum pernah, "OFF" bila fitur heartbeat mati. Ini bukti visual apakah
            -- server Termux benar-benar menerima sinyal dari clone tsb.
            local hbText, hbColor = "-", C.dim
            pcall(function()
                local info = Heartbeat.info(inst)
                if info and info.enabled then
                    if info.seen and info.age then
                        local age = info.age
                        local thr = Heartbeat.timeout() or 30
                        if age < 60 then
                            hbText = age .. "s"
                        else
                            hbText = string.format("%dm%ds", math.floor(age / 60), age % 60)
                        end
                        hbColor = age <= thr and C.green or C.yellow
                    elseif info.key == nil then
                        -- Key (heartbeatKey/username) belum ter-resolve: kita tak tahu
                        -- nama key yang harus dicocokkan -> "?" merah, bukan "-" yang
                        -- bisa disalahartikan "server nggak nerima sinyal".
                        hbText, hbColor = "?", C.red
                    else
                        hbText, hbColor = "-", C.dim
                    end
                else
                    hbText, hbColor = "OFF", C.dim
                end
            end)
            table.insert(sb, bodyRow(rowText, label, ui[2], hbText, hbColor))
        end
        table.insert(sb, mid)
    end

    table.insert(sb, bodyRow("Memory Usage", memoryLine() or "--"))
    table.insert(sb, bodyRow("Storage Available", storageLine() or "--"))
    table.insert(sb, bot)

    -- Status server heartbeat + footer hint below the table.
    local hbServer = "HB server: OFF (aktifkan heartbeat di config)"
    pcall(function()
        local info = Heartbeat.serverInfo()
        if info and info.running then
            hbServer = string.format("HB server: ON :%d (pid %s) | %d key terhubung",
                info.port, tostring(info.pid), info.keyCount)
        end
    end)
    table.insert(sb, " ")
    table.insert(sb, C.dim .. hbServer .. C.reset)
    -- Peringatan merah apabila ada clone yang heartbeat ON tapi key belum ter-resolve.
    local unresolved = 0
    for _, inst2 in ipairs(instances or {}) do
        pcall(function()
            local info2 = Heartbeat.info(inst2)
            if info2 and info2.enabled and not info2.key then
                unresolved = unresolved + 1
            end
        end)
    end
    if unresolved > 0 then
        table.insert(sb, C.red .. string.format(
            "%d clone username belum ter-resolve (cek data/username_scan.log / lua tools/username_diag.lua)",
            unresolved) .. C.reset)
    end
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
