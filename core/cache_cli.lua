local Cleaner = require("managers.cache_cleaner")
local Config = require("core.config")
local Instances = require("managers.instance")

local CLI = {}

local function prompt(label)
    io.write(label)
    io.flush()
    return io.read()
end

local function formatMiB(kib)
    return kib and string.format("%.1f MB", kib / 1024) or "?"
end

local function list()
    local instances = Instances.getAll()
    if #instances == 0 then
        print("Belum ada clone di config.")
        return instances
    end
    print("\nClone                         Status     RAM       Cache")
    for i, inst in ipairs(instances) do
        local info, err = Cleaner.inspectForInstance(inst)
        local status = info and (info.running and "jalan" or "berhenti") or (err or "?")
        local ram = info and info.rssMiB and (info.rssMiB .. " MB") or "?"
        local cache = info and formatMiB(info.cacheKiB) or "?"
        print(string.format("%d) %-27s %-10s %-9s %s", i,
            tostring(inst.name or inst.package or "?"), status, ram, cache))
    end
    print("Cache = penyimpanan; membersihkannya tidak langsung mengurangi RAM clone yang masih jalan.")
    return instances
end

local function report(ok, reason, freedKiB)
    if ok then
        print("Cache dibersihkan: " .. formatMiB(freedKiB) .. " bebas.")
    elseif reason == "running" then
        print("Dilewati: clone masih jalan. Tutup clone dulu agar sesi floating tidak terputus.")
    else
        print("Gagal membersihkan cache: " .. tostring(reason))
    end
end

local function saveSettings(key)
    local conf = Config.get() or {}
    conf.cacheCleaner = conf.cacheCleaner or {}
    local current = Cleaner.getConfig()[key]
    conf.cacheCleaner[key] = not current
    local ok, err = Config.save(conf)
    if ok then
        print(key .. " = " .. tostring(conf.cacheCleaner[key]))
    else
        conf.cacheCleaner[key] = current
        print("Gagal simpan: " .. tostring(err))
    end
end

function CLI.run()
    while true do
        local cfg = Cleaner.getConfig()
        print(string.format("\nCache Manager (auto=%s, WebView=%s)",
            tostring(cfg.enabled), tostring(cfg.clearWebView)))
        print("  1) Lihat cache dan RAM clone")
        print("  2) Bersihkan cache satu clone yang berhenti")
        print("  3) Bersihkan cache semua clone yang berhenti")
        print("  4) Toggle auto clear saat relaunch")
        print("  5) Toggle cache WebView")
        print("  6) Kembali")
        local choice = prompt("Choose: ")
        if not choice then return end
        choice = choice:match("^%s*(.-)%s*$")
        if choice == "1" then
            list()
        elseif choice == "2" then
            local instances = list()
            if #instances > 0 then
                local index = tonumber(prompt("Nomor clone (Enter batal): ") or "")
                if index and index == math.floor(index) and instances[index] then
                    report(Cleaner.applyForInstance(instances[index], { manual = true }))
                else
                    print("Batal / nomor tidak valid.")
                end
            end
        elseif choice == "3" then
            local cleared, skipped, failed = Cleaner.applyAll({ manual = true })
            print(string.format("Selesai: %d dibersihkan, %d masih jalan, %d gagal.",
                cleared, skipped, failed))
        elseif choice == "4" then
            saveSettings("enabled")
        elseif choice == "5" then
            saveSettings("clearWebView")
        elseif choice == "6" then
            return
        else
            print("Pilihan tidak dikenal.")
        end
    end
end

return CLI
