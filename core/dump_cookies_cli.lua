local InstanceManager = require("managers.instance")
local CookieInjector = require("managers.cookie_injector")

local CLI = {}

function CLI.run()
    print("\nDump Cookies (debug) - menampilkan baris cookie clone, value hanya panjangnya\n")
    local list = InstanceManager.getAll()
    if #list == 0 then
        print("(no instances configured)")
        return
    end
    print("Instances:")
    for _, inst in ipairs(list) do
        print(string.format("  id=%s name=%s package=%s", tostring(inst.id), tostring(inst.name or ""), tostring(inst.package or "")))
    end
    io.write("Instance id (atau kosong untuk batal): ")
    io.flush()
    local raw = io.read()
    local id = raw and tonumber((raw:gsub("^%s+", ""):gsub("%s+$", ""))) or nil
    if not id then
        print("Dibatalkan.")
        return
    end
    local inst = InstanceManager.findById(id)
    if not inst then
        print("Instance not found")
        return
    end
    print(string.format("Target: %s (%s)", tostring(inst.name or ""), tostring(inst.package or "")))

    local ok, msg = CookieInjector.dump(inst)
    if ok then
        print("\n----- cookies dump -----")
        print(msg)
        print("----- end dump -----")
    else
        print("[GAGAL] " .. tostring(msg))
    end
end

return CLI