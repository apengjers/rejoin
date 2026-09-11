local AutoExecute = require("managers.autoexecute")
local Config = require("core.config")

local CLI = {}

local function prompt(msg)
    io.write(msg)
    io.flush()
    return io.read()
end

-- Read multi-line script input from the terminal until a line that is exactly `END`
-- (the very last line). The `END` line is NOT stored / not executed.
local function readScript()
    local lines = {}
    while true do
        io.write("> ")
        io.flush()
        local line = io.read()
        if line == nil then return nil end                 -- EOF / Ctrl+D
        if line:match("^%s*END%s*$") then break end        -- terminal marker
        table.insert(lines, line)
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Print the numbered contents of the Delta autoexecute folder.
local function formatList(list)
    print(string.format("Isi folder (%d script):", #list))
    for i, s in ipairs(list) do
        print(string.format("  %2d) %-30s %6d bytes", i, (s.name or "?"):gsub("%.lua$", ""), s.size))
    end
end

-- Print the current contents of the Delta autoexecute folder.
local function printList()
    local list, err = AutoExecute.list()
    if not list then
        print("Could not list scripts: " .. tostring(err))
        return
    end
    if #list == 0 then
        print("(belum ada script — pilih 1 untuk Add)")
        return
    end
    formatList(list)
end

-- Show the numbered list and let the user pick one by number. Returns the chosen
-- entry ({name,size,path}) or nil when canceled (empty, invalid number, EOF).
local function pickFromList(promptLabel)
    local list, err = AutoExecute.list()
    if not list then
        print("Could not list scripts: " .. tostring(err))
        return nil
    end
    if #list == 0 then
        print("(belum ada script — pilih 1 untuk Add)")
        return nil
    end
    formatList(list)
    print("")
    local ans = prompt(promptLabel)
    if ans == nil then
        print("\n(Input berakhir — dibatalkan)")
        return nil
    end
    local idx = tonumber(ans:match("^%s*(%d+)%s*$")) or 0
    if idx < 1 or idx > #list then
        print("Nomor tidak valid (1-" .. #list .. ").")
        return nil
    end
    return list[idx]
end

-- Ask to continue adding more scripts ("Mau tambah lagi? (y/n)"). Returns true to add more.
local function wantMore()
    local a = prompt("Mau tambah lagi? (y/n): ") or ""
    return a:lower() == "y"
end

local function addFlow()
    while true do
        local name = prompt("Script name (no .lua): ") or ""
        name = name:match("^%s*(.-)%s*$")
        if name == "" then print("Name is required."); return end
        print("Tulis kode script. Akhiri dengan baris `END` di paling bawah, lalu Enter:")
        local content = readScript()
        if content == nil then print("Input dibatalkan (EOF)."); return end
        local ok, res = AutoExecute.save(name, content)
        if ok then
            print("Saved: " .. tostring(res))
        else
            print("Failed to save: " .. tostring(res))
            return
        end
        printList()
        if not wantMore() then return end
    end
end

local function editFlow()
    local entry = pickFromList("Nomor script yang mau diedit: ")
    if not entry then return end
    print("Edit " .. (entry.name:gsub("%.lua$", "")) .. ".lua")
    print("Tulis kode baru. Akhiri dengan baris `END` di paling bawah, lalu Enter:")
    local content = readScript()
    if content == nil then print("Input dibatalkan (EOF)."); return end
    local ok, res = AutoExecute.save(entry.name, content)
    if ok then print("Overwritten: " .. tostring(res)) else print("Failed: " .. tostring(res)) end
end

local function deleteFlow()
    local entry = pickFromList("Nomor script yang mau dihapus: ")
    if not entry then return end
    local confirm = prompt("Hapus " .. (entry.name:gsub("%.lua$", "")) .. ".lua? type 'yes' untuk konfirmasi: ") or ""
    if confirm:lower() ~= "yes" then print("Aborted"); return end
    local ok, err = AutoExecute.remove(entry.name)
    if ok then print("Deleted " .. entry.name) else print("Failed to delete: " .. tostring(err)) end
end

function CLI.run()
    while true do
        local conf = Config.get() or {}
        print("\nAutoExecute Manager — folder: " .. tostring(conf.appAutoExecutePath or "(belum di-set)"))
        printList()
        print("")
        print("  1) Add script")
        print("  2) Edit script")
        print("  3) Delete script")
        print("  4) Exit")
        local choice = prompt("Choose an option: ")
        if choice == nil then
            print("\n(Input berakhir — kembali ke menu utama)")
            break
        end
        choice = choice:match("^%s*(.-)%s*$")
        if choice == "1" then
            addFlow()
        elseif choice == "2" then
            editFlow()
        elseif choice == "3" then
            deleteFlow()
        elseif choice == "4" then
            print("Exiting AutoExecute Manager")
            break
        else
            print("Unknown choice")
        end
    end
end

return CLI