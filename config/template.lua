-- Config template for Rejoin Engine
return {
    -- AutoExecute is now managed DIRECTLY in the app's autoexecute folder: scripts are
    -- added/edited/deleted from the "Script Manager" menu into `appAutoExecutePath`
    -- (e.g. /sdcard/Delta/Autoexecute). No separate staging folder, no deploy step.
    monitorInterval = 5,
    recoveryDelay = 3,
    recoveryRetries = 3,
    checkTimeout = 15,
    debug = true,
    -- Console log verbosity. Hidden below this level: "DEBUG" shows everything,
    -- "INFO" is the default (hides the monitor's per-probe/su debug spam).
    logLevel = "INFO",
    logPath = "data/rejoin.log",
    -- Optional fast filter for auto-detect clone scan (e.g. "com.apengjers."). Empty = disabled.
    clonePackagePrefix = "",
    -- Seconds an app may stay frozen/stuck before the monitor force-relaunches it.
    -- (5 minutes = 300s). Clones that are NOT logged in are never relaunched regardless
    -- (see cookiePath / Auth detection).
    freezeTimeout = 300,
    -- Seconds after launch that a running app is still considered "starting" before it
    -- is judged ingame vs stuck.
    gracePeriod = 30,
    -- Enable ANR (Application Not Responding) detection via logcat (best-effort, needs
    -- readable logcat, more reliable with root).
    anrCheckEnabled = true,
    -- Minimum resident memory (MB) for a clone's process to be considered ACTIVE.
    -- A running clone reads ~1 GB while a force-close stub is ~188 MB, so anything
    -- below this is treated as "not really running" and gets relaunched. Tune if needed.
    minRss = 200,
    -- Timeout (seconds) for each shell command (via the `timeout` tool) so a hung
    -- su/dumpsys call can't freeze the whole tool / stop the terminal accepting input.
    shellTimeout = 10,
    -- Automatic per-cycle diagnostics: written to this file whenever the app is
    -- launched via Menu 1 (Launch + Monitor). Shows running/isActive/RSS per clone.
    launchLogPath = "launch.log",
    launchLogEnabled = true,

    -- Deprioritize the Roblox clones with renice/ionice to cut RAM/CPU contention when
    -- several floating windows run at once. Applied to every clone after launch/recovery
    -- (the process gets a new pid on each relaunch, so tuning is re-applied each time).
    optimizer = {
        enabled = true,
        renice = 19,   -- CPU scheduling priority (higher = lower). 19 = lowest.
        ionice = 3,    -- I/O class: 0=none,1=realtime,2=best-effort,3=idle.
    },

    -- Folder tujuan AutoExecute (Script Manager). Scripts dikelola LANGSUNG di sini
    -- sebagai <name>.lua (Add/Edit/Delete). Path ini shared untuk semua instance.
    -- Delta mod: /sdcard/Delta/Autoexecute (internal storage, tidak perlu root).
    appAutoExecutePath = "/sdcard/Delta/Autoexecute",

    -- Heartbeat (HTTP): clone di dalam game kirim POST /heartbeat tiap 10 detik ke
    -- server kecil di Termux (scripts/heartbeat_server.py). Server hanya menerima &
    -- mencatat timestamp ke statePath (di-baca monitor tiap siklus).
    --   - Tidak ada sinyal > `timeout` detik  => status Freeze, relaunch setelah
    --     `freezeTimeout` (5 menit) via recovery biasa.
    --   - Key sinyal = username akun clone (auto, dari cookie) ATAU per-instance
    --     `heartbeatKey` bila field itu diisi.
    --   - WAJIB executor Delta punya fungsi raw `request()/http_request`
    --     (HttpService:PostAsync TIDAK bisa — di-proxy server Roblox).
    --   - enabled=false (default) => NOL perubahan perilaku: monitor jalan seperti
    --     biasa (berbasis RSS), server tidak dinyalakan.
    --   - strict=true (server-first): kalau server ON dan clone DIPEROLEHKAN kirim
    --     sinyal (key ter-resolve + login aktif + proses hidup) tapi belum pernah ada
    --     sinyal > noSignalGrace detik => Freeze (dipulihkan). Kalau prasyarat belum
    --     lengkap (key nil / logout / server OFF) status jatuh balik ke RSS safety
    --     (Ingame/Offline/NoLogin) supaya tidak relaunch-spam.
    --     Per-instance bisa di-override via field `heartbeatRequired` di instances[].
    heartbeat = {
        enabled = false,
        host = "127.0.0.1",
        port = 8080,
        timeout = 30,
        statePath = "data/heartbeat_state.txt",
        strict = true,
        noSignalGrace = 180,
    },

    -- "Launch All" launches clones ONE AT A TIME, waiting for each to reopen before
    -- starting the next (so floating-window clones each get a chance to appear).
    -- launchWaitInterval: how often (s) to poll for the process while waiting.
    -- launchWaitTimeout:   how long (s) to wait before giving up on one clone and moving on.
    -- launchSettleDelay:   extra pause (s) after a clone is detected, before launching next.
    launchWaitInterval = 3,
    -- How long (s) to wait for a clone to become ACTIVE (RSS >= minRss) during the
    -- Menu 1 sequential launch (Starting -> Running) before moving on to the next one.
    launchWaitTimeout = 60,
    launchSettleDelay = 5,
    -- Run shell commands as root (su -c). Required on a rooted device Android 11+ so that
    -- ps/pidof/pgrep can actually see the app processes the Monitor depends on; Termux run
    -- as a normal user cannot see other apps' processes. Set false on a non-root device.
    useRoot = true,
    instances = {
        -- Example instance. Private Server accepts either a public game link
        --   https://www.roblox.com/games/<placeId>/...
        -- or a private server share link
        --   https://www.roblox.com/share?code=...&type=Server
        -- cookiePath (optional): path to this clone's WebView cookie DB used to detect
        -- whether an account is already logged in. If left empty, the default
        -- /data/data/<package>/app_webview/Default/Cookies is used. When no login is
        -- detected the clone is treated as idle and is never force-relaunched.
        {
            id = 1,
            name = "Main",
            package = "com.roblox.client",
            privateServer = "https://www.roblox.com/games/107778070777162/Steal-An-Egg",
            -- (optional) path to a file whose first line is this clone's Roblox username;
            -- when blank the monitor auto-resolves it via the Roblox API + ROBLOSECURITY cookie.
            usernamePath = "",
            -- (optional) heartbeat identity for this clone. Blank = the resolved username
            -- is used. Set it to a fixed string and use the SAME key in the in-game
            -- heartbeat script to make matching fully deterministic.
            heartbeatKey = "",
            -- (optional) override `heartbeat.strict` for THIS clone only.
            --   true  = clone DIHARUSKAN kirim sinyal (no-signal > grace => Freeze)
            --   false = clone tak pernah di-Freeze karena belum kirim sinyal (tetap RSS)
            --   blank = ikut setting global `heartbeat.strict`
            heartbeatRequired = nil
        }
    }
}
