local InstanceManager = require("managers.instance")
local CookieInjector = require("managers.cookie_injector")

local CLI = {}

local function prompt(msg)
    io.write(msg)
    io.flush()
    return io.read()
end

-- Read a (potentially huge) token, then immediately wipe the echoed paste line from
-- the screen. A 1170-char paste renders as one giant line that can stall the Termux UI
-- and eat subsequent keystrokes (Enter included), so it must be erased right after the
-- read while input is still responsive.
local function readToken(msg)
    io.write(msg)
    io.flush()
    local t = io.read() or ""
    io.write("\r\27[2K") -- carriage return + clear entire current line (echoed paste)
    io.flush()
    return t:gsub("^%s+", ""):gsub("%s+$", "")
end

local function listInstances()
    local list = InstanceManager.getAll()
    if #list == 0 then
        print("(no instances configured)")
        return nil
    end
    print("Instances:")
    for _, inst in ipairs(list) do
        print(string.format("  id=%s name=%s package=%s", tostring(inst.id), tostring(inst.name or ""), tostring(inst.package or "")))
    end
    return list
end

local function pickInstance()
    local list = listInstances()
    if not list then return nil end
    local id = prompt("Instance id: ") or ""
    id = tonumber(id)
    local inst = id and InstanceManager.findById(id)
    if not inst then
        print("Instance not found")
        return nil
    end
    print(string.format("Target: %s (%s)", tostring(inst.name or ""), tostring(inst.package or "")))
    return inst
end

-- One-shot flow: after an action prints its result we consume any leftover stdin
-- (a big token paste can desync the Termux keyboard/buffer) then return to the main
-- menu, so the user never sits stuck in this submenu. The screen is cleared first:
-- forcing a full repaint re-syncs the Termux surface after a heavy paste.
local function backToMain()
    io.write("\27[2J\27[H") -- clear screen + cursor home
    io.flush()
    print("[Selesai] Tekan Enter untuk kembali ke menu utama")
    io.read()
end

-- Token actions (inject / cek validitas) do a huge paste, after which the terminal's
-- input pipeline can silently die. So they never wait for input again: print the
-- result and exit the process right away, dropping back to the shell. No further
-- io.read(), no stuck submenu/menu.
local function exitAfter(msg)
    print(tostring(msg))
    print("\nSelesai. Script keluar otomatis. Jalankan lagi dengan: lua main.lua")
    os.exit(0)
end

function CLI.run()
    while true do
        print("\nInject Cookie:\n  1) Inject .ROBLOSECURITY ke instance\n  2) Dump cookies (debug)\n  3) Cek validitas token\n  4) Exit\n")
        local choice = prompt("Choose an option: ") or ""
        choice = choice:match("^%s*(.-)%s*$")
        if choice == "1" then
            local inst = pickInstance()
            if inst then
                print("")
                print("=============================================================")
                print(" 1 token = 1 clone = 1 akun.")
                print(" Token yang dipakai di >1 clone/device beruntun -> Roblox")
                print(" force-logout SEMUA sesi (termasuk browser sumber) + rotasi.")
                print(" Untuk tiap clone gunakan eksport token yang BEDA.")
                print("=============================================================")
                local token = readToken("Cookie .ROBLOSECURITY: ")
                if token == "" then
                    exitAfter("[GAGAL] Token kosong, dibatalkan.")
                else
                    local confirm = prompt(string.format("Inject cookie (%d char) ke %s? Force-stop app dulu. type 'y': ", #token, tostring(inst.package or ""))) or ""
                    if confirm:lower() == "y" then
local ok, msg = CookieInjector.inject(inst, token)
                            if ok then
                                print("[OK] " .. tostring(msg))
                                -- The app was force-stopped by inject; launch it right away so
                                -- it authenticates against Roblox immediately.
                                local APK = require("managers.apk")
                                local Timer = require("utils.timer")
                                print("Membuka " .. tostring(inst.package or "") .. "...")
                                local lOk, lOut = APK.launch(inst.package)
                                if not lOk then
                                    print("[WARN] Gagal membuka app otomatis: " .. tostring(lOut or "(tanpa output)"))
                                end
                                -- IMPORTANT: DO NOT curl-verify the token while the app is
                                -- running. curl + WebView authenticating the SAME session in
                                -- succession is exactly the "session hijack" pattern Roblox
                                -- detects -> instant revoke (proven at 01:43: 200 at :28,
                                -- app launched at :30, 401 hit during the post-launch curl).
                                -- Here we only READ the DB (rotation check), no network.
                                Timer.sleep(8)
                                print("")
                                print("Periksa rotasi session (baca DB saja, TANPA panggil server —")
                                print("menghindari 2 client pakai token sama serentak yg memicu revoke):")
                                print(CookieInjector.probeToken(inst, token))
                                print("")
                                print("- prefix SAMA dgn token -> rotasi belum terjadi, cek app saat ini.")
                                print("- prefix BERBEDA -> WebView sudah authenticate (login PASTI sukses).")
                                print("JANGAN verifikasi token (7>3) SELAMA app masih terbuka.")
                                exitAfter("Inject + launch selesai.")
                            else
                                exitAfter("[GAGAL] " .. tostring(msg))
                            end
                    else
                        exitAfter("Dibatalkan")
                    end
                end
            else
                exitAfter("[GAGAL] Instances dibutuhkan untuk inject.")
            end
        elseif choice == "2" then
            local inst = pickInstance()
            if inst then
                local ok, msg = CookieInjector.dump(inst)
                if ok then
                    print("\n----- cookies dump -----")
                    print(msg)
                    print("----- end dump -----")
                else
                    print("[GAGAL] " .. tostring(msg))
                end
            end
            backToMain()
            break
        elseif choice == "3" then
            print("TUTUP dulu clone / app-nya sebelum cek (2 client pakai token sama serentak = trigger revoke).")
            local token = readToken("Cookie .ROBLOSECURITY: ")
            if token == "" then
                exitAfter("[GAGAL] Token kosong, dibatalkan.")
            else
                local ok, msg = CookieInjector.verifyRemote(token)
                exitAfter(ok and ("[VALID] " .. tostring(msg)) or ("[GAGAL] " .. tostring(msg)))
            end
        elseif choice == "4" then
            print("Exiting Inject Cookie")
            break
        else
            print("Unknown choice")
        end
    end
end

return CLI