-- Config template for Rejoin Engine
return {
    -- AutoExecute is now a GLOBAL multi-script manager: scripts live in
    -- `autoExecuteDeployPath` and are deployed manually via the "Script Manager" menu
    -- into each app (see appAutoExecutePath below). The user writes the scripts.
    monitorInterval = 5,
    recoveryDelay = 3,
    recoveryRetries = 3,
    checkTimeout = 15,
    debug = true,
    -- Console log verbosity. Hidden below this level: "DEBUG" shows everything,
    -- "INFO" is the default (hides the monitor's per-probe/su debug spam).
    logLevel = "INFO",
    autoExecuteDeployPath = "data/autoexecute",
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

    -- Folder tujuan Deploy (Script Manager / AutoExecute). Scripts di-deploy ke sini
    -- sebagai <name>.lua. Path ini shared untuk semua instance.
    -- Delta mod: /sdcard/Delta/Autoexecute (internal storage, tidak perlu root).
    appAutoExecutePath = "/sdcard/Delta/Autoexecute",

    -- Where global scripts are stored on the Termux side (Termux folder, no root needed).
    autoExecuteDeployPath = "data/autoexecute",

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
            privateServer = "https://www.roblox.com/games/107778070777162/Steal-An-Egg"
        }
    }
}
