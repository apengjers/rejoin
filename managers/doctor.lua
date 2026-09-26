-- Environment doctor: emit a compare-friendly KEY=value report of everything that can
-- differ BETWEEN devices and cause "inject [OK] tapi app ga login" on one device but
-- not the other (root, Android/WebView version, clone APK version+hash, Cookies DB
-- layout/schema, curl/sqlite3 availability). Run `lua main.lua --doctor` on EACH device
-- and diff the two outputs -- the mismatch line is the dependency/fingerprint culprit.

local Logger = require("core.logger")
local Shell = require("utils.shell")
local Config = require("core.config")
local InstanceManager = require("managers.instance")

local TERMUX_PREFIX = "/data/data/com.termux/files/usr"

local Doctor = {}

local function join(k, v)
    if v == nil then v = "(tidak ada)" end
    v = tostring(v):gsub("[\r\n]+", "\\n")
    return tostring(k) .. "=" .. v
end

local function outOf(cmd)
    local ok, out = Shell.exec(cmd)
    if not ok or not out then return nil end
    out = out:gsub("\n+$", "")
    if out:gsub("%s+", "") == "" then return nil end
    return out
end

local function oneOf(stmts)
    for _, c in ipairs(stmts) do
        local v = outOf(c)
        if v and v ~= "" then return v end
    end
    return nil
end

local function hashApk(pkg)
    local p = outOf("pm path " .. pkg .. " 2>/dev/null | head -n1")
    if not p then return nil end
    local apk = p:match("^package:(.+)$")
    if not apk or apk == "" then return nil end
    return outOf("sha1sum '" .. apk:gsub("'", "'\\''") .. "' 2>/dev/null | cut -d' ' -f1")
end

function Doctor.gather()
    local rows = {}
    local function add(k, v) rows[#rows + 1] = join(k, v) end

    add("LUA_VERSION", _VERSION)
    add("LUA_BIN", outOf("command -v lua"))
    add("CURL_BIN", oneOf({ "command -v curl" }))
    add("SQLITE_BIN", oneOf({ "command -v sqlite3", "ls " .. TERMUX_PREFIX .. "/bin/sqlite3" }))

    add("ROOT_UID", outOf("id -u"))
    add("SELINUX", outOf("getenforce"))
    add("ANDROID_SDK", outOf("getprop ro.build.version.sdk"))
    add("ANDROID_RELEASE", outOf("getprop ro.build.version.release"))
    add("MODEL", oneOf({ "getprop ro.product.model", "getprop ro.product.device" }))

    add("WEBVIEW_GOOGLE", oneOf({
        "dumpsys package com.google.android.webview | grep -m1 versionName",
        "cmd package dump com.google.android.webview | grep -m1 versionName",
        "pm path com.google.android.webview",
    }))
    add("WEBVIEW_AOSP", oneOf({
        "dumpsys package com.android.webview | grep -m1 versionName",
        "cmd package dump com.android.webview | grep -m1 versionName",
    }))
    add("PLAY_SERVICES", oneOf({
        "dumpsys package com.google.android.gms | grep -m1 versionName",
        "cmd package dump com.google.android.gms | grep -m1 versionName",
    }))

    local instances = InstanceManager.getAll() or {}
    add("INSTANCE_COUNT", #instances)
    local CookieInjector = require("managers.cookie_injector")
    for i, inst in ipairs(instances) do
        local pkg = inst and inst.package or ""
        local tag = string.format("INST%d", i)
        add(tag .. "_PKG", pkg)
        add(tag .. "_VER", oneOf({
            "dumpsys package " .. pkg .. " | grep -m1 versionName",
            "cmd package dump " .. pkg .. " | grep -m1 versionName",
        }))
        add(tag .. "_CODE", oneOf({
            "dumpsys package " .. pkg .. " | grep -m1 versionCode",
            "cmd package dump " .. pkg .. " | grep -m1 versionCode",
        }))
        add(tag .. "_SHA1", hashApk(pkg))
        add(tag .. "_INSTALLED", oneOf({
            "dumpsys package " .. pkg .. " | grep -m1 firstInstallTime",
            "cmd package dump " .. pkg .. " | grep -m1 firstInstallTime",
        }))

        local dbs = CookieInjector.listDbs(inst)
        if dbs then
            add(tag .. "_COOKIE_DBS", #dbs)
            for j, db in ipairs(dbs) do
                add(tag .. "_DB" .. j, db)
                add(tag .. "_DB" .. j .. "_SIZE", outOf("wc -c < '" .. (db:gsub("'", "'\\''")) .. "' 2>/dev/null"))
                add(tag .. "_DB" .. j .. "_INFO", CookieInjector.dbInfo(db))
            end
        else
            add(tag .. "_COOKIE_DBS", "none/reject")
        end
    end
    return table.concat(rows, "\n")
end

function Doctor.run()
    local report = Doctor.gather()
    Logger.info("DOCTOR REPORT begin")
    for line in (report .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then Logger.info("DOCTOR| " .. line) end
    end
    Logger.info("DOCTOR REPORT end")
    return report
end

return Doctor