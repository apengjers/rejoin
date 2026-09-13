-- Sample config for Rejoin Engine (adjust package names and paths for your device)
return {
    monitorInterval = 5,
    recoveryDelay = 3,
    recoveryRetries = 3,
    checkTimeout = 15,
    debug = true,
    logPath = "data/rejoin.log",
    -- Optional fast filter for auto-detect clone scan (e.g. "com.apengjers."). Empty = disabled.
    clonePackagePrefix = "",
    -- Deteksi freeze/stuck. Recovery baru dipicu setelah freeze 300 detik (5 menit).
    freezeTimeout = 300,
    gracePeriod = 30,
    anrCheckEnabled = true,
    -- Minimum resident memory (MB) for a clone's process to be considered ACTIVE.
    -- A running clone reads ~1 GB while a force-close stub is ~188 MB, so anything
    -- below this is treated as "not really running" and gets relaunched. Tune if needed.
    minRss = 200,
    -- Timeout (seconds) for each shell command (via the `timeout` tool) so a hung
    -- su/dumpsys call can't freeze the whole tool / stop the terminal accepting input.
    shellTimeout = 10,
    -- How long (s) to wait for one clone to become active (RSS >= minRss) during the
    -- Menu 1 sequential launch before moving on to the next instance.
    launchWaitTimeout = 60,
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
    -- sebagai <name>.lua. Path ini shared untuk semua instance (Delta mod: internal storage).
    appAutoExecutePath = "/sdcard/Delta/Autoexecute",
    instances = {
        [1] = {
        id = 1,
        name = "Clone1",
        package = "com.apengjers.v3",
        privateServer = "https://www.roblox.com/games/107778070777162/Steal-An-Egg",
        },
        [2] = {
        id = 2,
        name = "Clone2",
        package = "com.apengjers.v4",
        privateServer = "https://www.roblox.com/games/107778070777162/Steal-An-Egg",
        },
        [3] = {
        id = 3,
        name = "Clone3",
        package = "com.apengjers.v5",
        privateServer = "https://www.roblox.com/games/107778070777162/Steal-An-Egg",
        },
        [4] = {
        id = 4,
        name = "Clone4",
        package = "com.apengjers.v6",
        privateServer = "https://www.roblox.com/games/107778070777162/Steal-An-Egg",
        },
    }
}