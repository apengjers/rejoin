local InstanceManager = require("managers.instance")
local CookieInjector = require("managers.cookie_injector")
local Logger = require("core.logger")

local CLI = {}

local function prompt(msg)
    io.write(msg)
    io.flush()
    return io.read()
end

-- Disable terminal echo while reading a long token. Echoing a long paste can stall
-- Termux rendering and consume the next prompt's input.
local function readToken(msg)
    io.write(msg)
    io.flush()
    local saved
    local state = io.popen("stty -g </dev/tty 2>/dev/null")
    if state then
        saved = state:read("*l")
        state:close()
    end
    if saved and saved:match("^[%x:]+$") then
        os.execute("stty -echo </dev/tty 2>/dev/null")
    else
        saved = nil
    end
    local readOk, t = pcall(io.read, "*l")
    if saved then os.execute("stty " .. saved .. " </dev/tty 2>/dev/null") end
    -- Some Termux sessions lose echo or ONLCR after a long paste. Restore the
    -- interactive modes explicitly before any menu or diagnostic output.
    os.execute("stty echo icanon opost onlcr </dev/tty 2>/dev/null")
    io.write("\r\n")
    io.flush()
    if not readOk then return "" end
    t = t or ""
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

-- A new Lua process gets a clean terminal input state after the long paste.
-- run.sh treats exit 75 as a request to redraw and restart the main menu.
local function finish(msg)
    print(tostring(msg))
    io.flush()
    os.exit(75)
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
                    finish("[GAGAL] Token kosong, dibatalkan.")
                    return
                else
                    local confirm = prompt(string.format("Inject cookie (%d char) ke %s? Force-stop app dulu. type 'y': ", #token, tostring(inst.package or ""))) or ""
                    if confirm:lower() == "y" then
                            local called, ok, msg = pcall(CookieInjector.inject, inst, token)
                            if not called then finish("[GAGAL] Inject error. Cek log dan coba lagi.") end
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
                                local probeOk, probeText, probeVerdict = pcall(CookieInjector.probeToken, inst, token)
                                if not probeOk then
                                    probeText = "Probe gagal; periksa Cookies DB setelah app ditutup."
                                    probeVerdict = "NEED_MANUAL_CHECK"
                                end
                                print(probeText)
                                print("")
                                print("[VERDICT] " .. tostring(probeVerdict))
                                Logger.info("Probe:\n" .. tostring(probeText))
                                Logger.info("VERDICT: " .. tostring(probeVerdict))
                                print("")
                                print("JANGAN verifikasi token (7>3) SELAMA app masih terbuka.")
                                finish("Inject + launch selesai.")
                                return
                            else
                                finish("[GAGAL] " .. tostring(msg))
                                return
                            end
                    else
                        finish("Dibatalkan")
                        return
                    end
                end
            else
                finish("[GAGAL] Instances dibutuhkan untuk inject.")
                return
            end
        elseif choice == "2" then
            local inst = pickInstance()
            if inst then
                local ok, msg = CookieInjector.dump(inst)
                if ok then
                    print("\n----- cookies dump -----")
                    print(msg)
                    print("----- end dump -----")
                    Logger.info("DUMP for " .. tostring(inst.package or "?") .. ":\n" .. tostring(msg))
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
                finish("[GAGAL] Token kosong, dibatalkan.")
                return
            else
                local called, ok, msg = pcall(CookieInjector.verifyRemote, token)
                if not called then finish("[GAGAL] Verifikasi error. Cek koneksi lalu coba lagi.") end
                finish(ok and ("[VALID] " .. tostring(msg)) or ("[GAGAL] " .. tostring(msg)))
                return
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
