-- tools/username_diag.lua
-- Diagnose why a clone's username is NOT resolving. Prints, per package, the raw
-- evidence used by managers/username.lua WITHOUT swallowing errors:
--   * is /data/data/<pkg> present?
--   * is a .ROBLOSECURITY token found? (length + first 24 chars masked)
--   * raw output of the Roblox /v1/users/authenticated call (truncated)
--   * raw local-scan grep output + the value extracted from it
--   * the resolved Username.get() result vs Username.apiName() state
-- Usage (Termux, repo dir):
--   lua tools/username_diag.lua

pcall(require, "core.logger")

local Config = require("core.config")
local InstanceManager = require("managers.instance")
local Username = require("managers.username")
local Shell = require("utils.shell")

InstanceManager.load(Config.get())

local instances = InstanceManager.getAll()
if not instances or #instances == 0 then
    print("No instances configured.")
    os.exit(0)
end

local function run(cmd)
    local ok, out = Shell.exec(cmd)
    out = (out or ""):gsub("\n+$", "")
    return ok, out
end

local function dirExists(d)
    return os.rename(d, d) == true
end

-- Mirror of username.extractToken but prints the raw shell result too.
local function diagToken(base)
    print("  dir exists: " .. tostring(dirExists(base)))
    local ok, out = run("grep -a -r -o -E 'WARNING:-DO-NOT-SHARE![A-Za-z0-9_=:./+%-|]+' '"
        .. base .. "' 2>/dev/null | head -1")
    local token = out and out:match("(WARNING%-DO%-NOT%-SHARE%![A-Za-z0-9_=:./+%%%-|]+)")
    if ok and token and #token > 20 then
        print("  token: found len=" .. #token)
        print("  token (censored): " .. token:sub(1, 24) .. "...***")
    else
        print("  token: NOT FOUND (variant grep: " .. ((not ok) and "shell error" or "no match") .. ")")
        local ok2, out2 = run("grep -a -r -o -E '_[%|][A-Za-z0-9_=:./+%-]{25,}' '"
            .. base .. "' 2>/dev/null | head -1")
        print("  token bare-variant: " .. tostring((ok2 and out2 ~= "" and out2 ~= "(dry-run)") and out2:sub(1, 30) .. "..." or "(none)"))
        return nil
    end
    return token
end

local function diagApi(base, token)
    local cmd = "curl -s --max-time 3 -H 'Cookie: .ROBLOSECURITY=" .. token
        .. "' https://users.roblox.com/v1/users/authenticated"
    local ok, out = run(cmd)
    print("  api raw: " .. tostring((out or ""):sub(1, 120)))
    if not ok or not out or out == "" or out == "(dry-run)" then
        return nil, "shell-error/no-curl"
    end
    local name = out:match('"name"%s*:%s*"([^"]*)"') or out:match('"displayName"%s*:%s*"([^"]*)"')
    if name then return name, "ok" end
    if out:match("401") or out:match("Unauthorized") or out:match("Too many requests") then
        return nil, "unauth"
    end
    return nil, "unexpected-json"
end

local function diagLocal(base)
    local ok, out = run("grep -a -r -i -E '(userName|username|displayName|accountName|playerName)"
        .. "%[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9_]{3,32}[\"']?"
        .. "' --include='*.xml' --include='*.json' --include='*.txt' --include='*.log' '"
        .. base .. "/shared_prefs' '" .. base .. "/files' 2>/dev/null | head -1")
    print("  local raw: " .. tostring((ok and out) or "(none)"))
    local _, val = (out or ""):match('(username|userName|displayName|accountName|playerName)%s*[:=]%s*["\']?([A-Za-z0-9_]{3,32})')
    return val
end

print("==================================================================")
print("username resolution diagnostic (evidence is NOT swallowed)")
print("==================================================================")

for i, inst in ipairs(instances) do
    local pkg = inst.package or "?"
    local id = inst.id or i
    local name = tostring(inst.name or id)
    print("")
    print(string.format("----- #%d  %s  (%s) -----", i, name, pkg))

    if inst.usernamePath and inst.usernamePath ~= "" then
        print("  manual override (usernamePath): " .. inst.usernamePath)
    end

    local base = "/data/data/" .. pkg
    local token = diagToken(base)
    if token then
        local apiUser, apiState = diagApi(base, token)
        print("  api => state=" .. tostring(apiState) .. " username=" .. tostring(apiUser))
        if not apiUser then
            local v = diagLocal(base)
            print("  local => " .. tostring(v or "(none)"))
        end
    else
        local v = diagLocal(base)
        print("  local => " .. tostring(v or "(none)"))
    end

    local u = Username.get(inst)
    print("  Username.get => " .. tostring(u or "(nil)"))
    local au, st = Username.apiName(inst)
    print(string.format("  Username.apiName => state=%s username=%s", tostring(st), tostring(au)))
end