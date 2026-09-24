local InstanceManager = require("managers.instance")
local CookieInjector = require("managers.cookie_injector")

local CLI = {}

local function prompt(msg)
    io.write(msg)
    io.flush()
    return io.read()
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

function CLI.run()
    while true do
        print("\nInject Cookie:\n  1) Inject .ROBLOSECURITY ke instance\n  2) Dump cookies (debug)\n  3) Exit\n")
        local choice = prompt("Choose an option: ") or ""
        choice = choice:match("^%s*(.-)%s*$")
        if choice == "1" then
            local inst = pickInstance()
            if inst then
                local token = prompt("Cookie .ROBLOSECURITY: ") or ""
                token = token:gsub("^%s+", ""):gsub("%s+$", "")
                if token == "" then
                    print("Token kosong, dibatalkan.")
                else
                    local confirm = prompt(string.format("Inject cookie (%d char) ke %s? Force-stop app dulu. type 'yes': ", #token, tostring(inst.package or ""))) or ""
                    if confirm:lower() == "yes" then
                        local ok, msg = CookieInjector.inject(inst, token)
                        print(ok and ("[OK] " .. tostring(msg)) or ("[GAGAL] " .. tostring(msg)))
                    else
                        print("Dibatalkan")
                    end
                end
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
        elseif choice == "3" then
            print("Exiting Inject Cookie")
            break
        else
            print("Unknown choice")
        end
    end
end

return CLI