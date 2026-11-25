local scripts = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$")
local M = {}

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

function M.betterEnabled()
    if not scripts then return false end
    local mods = scripts .. "/../.."
    local better = mods .. "/BetterModManager"
    if not exists(better .. "/Scripts/modconfig.lua") then return false end
    if exists(better .. "/enabled.txt") then return true end

    local loadOrder = readFile(mods .. "/mods.txt") or ""
    local enabled = ("\n" .. loadOrder:gsub("^\239\187\191", "")):lower():match("\n%s*bettermodmanager%s*:%s*([01])")
    if enabled then return enabled == "1" end
    local ok, schema = pcall(function() return ModRef:GetSharedVariable("BetterModManager.schema.BetterModManager") end)
    return ok and type(schema) == "string" and schema ~= ""
end

local function dekConfigPath(id)
    local ok, paks = pcall(function() return IterateGameDirectories().Game.Content.Paks end)
    if ok and paks and paks.LogicMods then
        local logic = paks.LogicMods.__absolute_path
        local pakRoot = paks.__absolute_path
        if logic and (exists(logic .. "/DekModConfigMenu_P.pak")
            or (pakRoot and exists(pakRoot .. "/~mods/DekModConfigMenu_P.pak"))) then
            return logic .. "/" .. id .. ".modconfig.json"
        end
    end
    return nil
end

local function normalize(option, value)
    if type(value) ~= type(option.init) then return nil end
    if type(value) ~= "number" then return value end
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    if option.type == "integer" then value = math.tointeger(value) end
    if value == nil then return nil end
    local limits = option.opts
    if limits and (value < limits.min or value > limits.max) then return nil end
    return value
end

local function start(id, betterActive, getValue, applyValue, log)
    if not scripts then return false end
    local path = dekConfigPath(id)
    if not path then return false end

    local json = require("dek_json")
    local function decode(raw)
        if not raw then return nil end
        local ok, result = pcall(json.decode, (raw:gsub("^\239\187\191", "")))
        if ok and type(result) == "table" then return result end
        return nil
    end

    local schema = decode(readFile(scripts .. "/dek_menu.json"))
    if not schema then
        log("Dek settings template could not be read")
        return false
    end
    local fields = {}
    for key, option in pairs(schema) do
        if type(option) == "table" and option.init ~= nil then fields[key] = option end
    end

    if not exists(path) then
        for key, option in pairs(fields) do
            local value = normalize(option, getValue(key))
            if value ~= nil then option.live = value end
        end
        local temp = path .. ".tmp"
        local file, err = io.open(temp, "wb")
        if not file then
            log("could not create Dek settings: " .. tostring(err))
            return false
        end
        local written = file:write(json.encode(schema))
        local closed = file:close()
        if not written or not closed then
            os.remove(temp)
            log("could not write Dek settings: " .. path)
            return false
        end
        local renamed, renameError = os.rename(temp, path)
        if not renamed then
            os.remove(temp)
            if not exists(path) then
                log("could not install Dek settings: " .. tostring(renameError))
                return false
            end
        end
    end

    if betterActive then
        log("settings controlled by Better Mod Manager; Dek changes are inactive this session")
        return false
    end

    local lastText
    local function reload()
        local raw = readFile(path)
        if not raw or raw == lastText then return end
        lastText = raw
        local saved = decode(raw)
        if not saved then
            log("Dek settings are invalid; keeping the current values")
            return
        end
        for key, option in pairs(fields) do
            local row = saved[key]
            if type(row) == "table" then
                local value = normalize(option, row.live)
                if value ~= nil then applyValue(key, value) end
            end
        end
    end
    reload()
    local function poll()
        local ok, err = pcall(reload)
        if not ok then log("could not apply Dek settings: " .. tostring(err)) end
        ExecuteInGameThreadWithDelay(1000, poll)
    end
    ExecuteInGameThreadWithDelay(1000, poll)
    log("settings controlled by Dek Mod Config Menu")
    return true
end

function M.start(id, betterActive, getValue, applyValue, log)
    local ok, result = pcall(start, id, betterActive, getValue, applyValue, log)
    if ok then return result end
    log("could not initialize Dek settings: " .. tostring(result))
    return false
end

return M
