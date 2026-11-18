local MOD_VERSION = "1.1.0"
local TAG = "[ExhaustedResourceMarkers] "
-- exact float only this mod uses as x scale, so markers left from an earlier load can be recognised and removed
local MARKER_SCALE_X = 1.0009765625

local function log(message)
    pcall(print, TAG .. tostring(message) .. "\n")
end

local helpersOk, UEHelpers = pcall(require, "UEHelpers")
if not helpersOk then
    UEHelpers = nil
    log("UEHelpers unavailable: " .. tostring(UEHelpers))
end

-- fallback for every config key, used wehn config.lua is missing or a value has the wrong type
local DEFAULTS = {
    toggle_key = "F9",
    toggle_modifiers = {},
    show_in_build_mode = true,
    radius_meters = 50,
    max_markers = 300,
    show_trees = true,
    show_rocks = true,
    beam_effect_path = "/Game/Pal/Effect/Treasure/NS_MapObject_TreasureLight.NS_MapObject_TreasureLight",
    beam_scale = { x = 1.0, y = 1.0, z = 1.0 },
    color_parameter_names = { "User.Color" },
    diagnostic_effect_paths = {},
    foliage_types = { { label = "tree", match = { "" }, color = { 0.1, 1.0, 0.1 } } },
    resource_types = {},
    foliage_alive_state = 0,
    spawner_match_distance_cm = 300,
    poll_interval_ms = 250,
    refresh_interval_ms = 2000,
    scan_budget_ms = 6,
    cache_margin_meters = 30,
    cache_rebuild_interval_ms = 60000,
    chat_messages = true,
    diagnostics = false,
}

-- {min, max} for numbers from config.lua, anything outside gets clampped
local LIMITS = {
    radius_meters = { 5, 300 },
    max_markers = { 1, 1000 },
    spawner_match_distance_cm = { 50, 2000 },
    poll_interval_ms = { 50, 5000 },
    refresh_interval_ms = { 250, 60000 },
    scan_budget_ms = { 1, 50 },
    cache_margin_meters = { 5, 200 },
    cache_rebuild_interval_ms = { 5000, 600000 },
}

local function clamp(value, low, high)
    if value < low then
        return low
    end
    if value > high then
        return high
    end
    return value
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- user scale as an X/Y/Z vector, or fallback if a value is missing, zero or negative
local function normalizeScale(scale, fallback)
    if type(scale) ~= "table" then
        return fallback
    end
    local x, y, z = scale.x, scale.y, scale.z
    if not isFiniteNumber(x) or not isFiniteNumber(y) or not isFiniteNumber(z) or x <= 0 or y <= 0 or z <= 0 then
        return fallback
    end
    return { X = clamp(x, 0.05, 50), Y = clamp(y, 0.05, 50), Z = clamp(z, 0.05, 50) }
end

-- {r, g, b} into a linear colour, nil if it isn't three numbers
local function normalizeColor(color)
    if type(color) ~= "table" then
        return nil
    end
    local r, g, b = color[1], color[2], color[3]
    if not isFiniteNumber(r) or not isFiniteNumber(g) or not isFiniteNumber(b) then
        return nil
    end
    return { R = clamp(r, 0, 20), G = clamp(g, 0, 20), B = clamp(b, 0, 20), A = 1.0 }
end

-- match strigns lowercased once here, so lookups later don't have to, nil if there are none
local function normalizeMatch(match)
    if type(match) ~= "table" then
        return nil
    end
    local lowered = {}
    for _, needle in ipairs(match) do
        if type(needle) == "string" then
            lowered[#lowered + 1] = needle:lower()
        end
    end
    if #lowered == 0 then
        return nil
    end
    return lowered
end

-- each type entry turned into what the marker code needs, broken entries are skiped with a log line
local function normalizeTypes(list, listName, defaultScale)
    local result = {}
    if type(list) ~= "table" then
        return result
    end
    for index, entry in ipairs(list) do
        local match = type(entry) == "table" and normalizeMatch(entry.match) or nil
        local color = type(entry) == "table" and normalizeColor(entry.color) or nil
        if match == nil or color == nil then
            log("config: " .. listName .. "[" .. index .. "] ignored (needs match strings and a 3-number color)")
        else
            local height = 1.0
            if isFiniteNumber(entry.height) and entry.height > 0 then
                height = clamp(entry.height, 0.1, 50)
            end
            local stack = 1
            if isFiniteNumber(entry.stack) then
                stack = math.floor(clamp(entry.stack, 1, 10))
            end
            local stackStep = 300
            if isFiniteNumber(entry.stack_step_cm) then
                stackStep = clamp(entry.stack_step_cm, 10, 5000)
            end
            result[#result + 1] = {
                label = type(entry.label) == "string" and entry.label or ("type" .. index),
                match = match,
                color = color,
                scale = normalizeScale(entry.scale, defaultScale),
                componentScale = { X = MARKER_SCALE_X, Y = 1.0, Z = height }, -- x is the leftover fingerprint, z the height
                stack = stack,
                stackStep = stackStep,
            }
        end
    end
    return result
end

local function normalizeStrings(list)
    local result = {}
    if type(list) ~= "table" then
        return result
    end
    for _, value in ipairs(list) do
        if type(value) == "string" and value ~= "" then
            result[#result + 1] = value
        end
    end
    return result
end

-- config.lua merged over DEFAULTS, a broken file nevr stops the mod, it just falls back
local function loadConfig()
    local ok, loaded = pcall(require, "config")
    if not ok or type(loaded) ~= "table" then
        log("config.lua could not be loaded, using defaults: " .. tostring(loaded))
        loaded = {}
    end
    local result = {}
    for key, default in pairs(DEFAULTS) do
        local value = loaded[key]
        if type(value) ~= type(default) then
            if value ~= nil then
                log("config: " .. key .. " has the wrong type, using default")
            end
            value = default
        end
        result[key] = value
    end
    for key, range in pairs(LIMITS) do
        local value = result[key]
        if not isFiniteNumber(value) then
            value = DEFAULTS[key]
        end
        result[key] = clamp(value, range[1], range[2])
    end
    result.max_markers = math.floor(result.max_markers)
    result.beam_scale = normalizeScale(result.beam_scale, { X = 1.0, Y = 1.0, Z = 1.0 })
    result.color_parameter_names = normalizeStrings(result.color_parameter_names)
    result.diagnostic_effect_paths = normalizeStrings(result.diagnostic_effect_paths)
    result.toggle_modifiers = normalizeStrings(result.toggle_modifiers)
    result.foliage_types = normalizeTypes(result.foliage_types, "foliage_types", result.beam_scale)
    result.resource_types = normalizeTypes(result.resource_types, "resource_types", result.beam_scale)
    -- without any foliage type no tree would match, so the default tree goes back in
    if #result.foliage_types == 0 then
        result.foliage_types = normalizeTypes(DEFAULTS.foliage_types, "foliage_types", result.beam_scale)
    end
    return result
end

local config = loadConfig()

local ZERO_ROTATION = { Pitch = 0, Yaw = 0, Roll = 0 }
local KEY_CELL_CM = 50 -- markers closer than this share a kye
local GRID_STRIDE = 1048576 -- packs grid cell x and y into one number, so no strings are built per lookup
local CLOCK_CHECK_EVERY = 32 -- items bewteen clock checks while scanning
local SPAWN_CLOCK_CHECK_EVERY = 4 -- spawning is slower, so the clock is checked more often
local MAX_CONSECUTIVE_FAILURES = 10 -- this many errors in a row switch the mod off until restart
local MAX_SPAWN_FAILURES = 3
local RETRY_BACKOFF_MS = 10000 -- wait before trying a failed spawn or asset load agian
local RADIUS_SQ, CACHE_MARGIN_SQ, REACH_SQ, MATCH_CM, MATCH_SQ
local function updateScanDistances()
    local radius = config.radius_meters * 100
    local margin = config.cache_margin_meters * 100
    RADIUS_SQ = radius * radius
    CACHE_MARGIN_SQ = margin * margin
    -- Keep a margin around the radius so that small movements can reuse the cache.
    REACH_SQ = (radius + margin) * (radius + margin)
    MATCH_CM = config.spawner_match_distance_cm
    MATCH_SQ = MATCH_CM * MATCH_CM
end
updateScanDistances()
local BEAM_ASSET_NAME = config.beam_effect_path:match("%.([^%.]+)$") or config.beam_effect_path

local hotkeyOn = false
local buildModeOn = false
local wasActive = false
local disabled = false
-- player and world the markers belong to, a diffrent world means the old markers are gone
local sessionReady = false
local sessionPawnAddress = nil
local sessionWorldAddress = nil
local sessionWorld = nil
local forceRefresh = false
local announceNextResult = false
local lastRefreshAt = -math.huge
local cachedController = nil
local controllerSearchAt = 0
local builder = nil
local builderSearchAt = 0
local cache = nil
local job = nil
local activeMarkers = {} -- marker key -> component on screen
local freeMarkers = {} -- hidden components wating for reuse
local beamAsset = nil
local assetRetryAt = 0
local niagaraLibrary = nil
local libraryRetryAt = 0
local spawnFailures = 0
local spawnBlockedUntil = 0
local consecutiveFailures = 0
local errorCounts = {}
local tickPending = false
local nextTickAt = -math.huge
local diagnosticsLogged = false
local propertiesLogged = false
local effectsLogged = false
local spawnerTypeMemo = {} -- class name -> type entry, false = not a listed resource
local foliageTypeMemo = {}

-- milliseconds, os.clock is wall time on windows so it works as a timer
local function now()
    return os.clock() * 1000
end

-- first 5 times, then every 100th, so a repeating error can't flood UE4SS.log
local function logLimited(key, message)
    local count = (errorCounts[key] or 0) + 1
    errorCounts[key] = count
    if count <= 5 or count % 100 == 0 then
        log(message .. " (occurrence " .. count .. ")")
    end
end

-- small named helpers for pcall, so no new closure is made for evrey object read
local function callIsValid(object)
    return object:IsValid()
end

local function isValid(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(callIsValid, object)
    return ok and valid == true
end

local function getField(object, name)
    return object[name]
end

local function readField(object, name)
    local ok, value = pcall(getField, object, name)
    if not ok then
        return nil
    end
    return value
end

local function callGetAddress(object)
    return object:GetAddress()
end

local function addressOf(object)
    local ok, address = pcall(callGetAddress, object)
    if not ok then
        return nil
    end
    return address
end

-- takes pcall results directly, nil if the call failed or a value isn't a number
local function toLocation(ok, x, y, z)
    if not ok or not isFiniteNumber(x) or not isFiniteNumber(y) or not isFiniteNumber(z) then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function isOrigin(location)
    return location.x == 0 and location.y == 0 and location.z == 0
end

local function distanceSq2D(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    return dx * dx + dy * dy
end

local function distanceSq3D(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

local function toVector(location)
    return { X = location.x, Y = location.y, Z = location.z }
end

local function classNameOf(object)
    return object:GetClass():GetFName():ToString()
end

local function className(object)
    local ok, name = pcall(classNameOf, object)
    if not ok or type(name) ~= "string" then
        return "?"
    end
    return name
end

-- first type whose match string is in the name, or nil, result rememberd per name
local function resolveType(name, types, memo)
    local known = memo[name]
    if known ~= nil then
        return known or nil
    end
    local lowered = name:lower()
    for _, entry in ipairs(types) do
        for _, needle in ipairs(entry.match) do
            if lowered:find(needle, 1, true) ~= nil then
                memo[name] = entry
                return entry
            end
        end
    end
    memo[name] = false
    return nil
end

local function actorXYZ(actor)
    local location = actor:K2_GetActorLocation()
    return location.X, location.Y, location.Z
end

local function actorLocation(actor)
    return toLocation(pcall(actorXYZ, actor))
end

local function foliageCacheXYZ(instance)
    local translation = instance.WorldTransformCache.Translation
    return translation.X, translation.Y, translation.Z
end

local function foliageRawXYZ(instance)
    local location = instance.WorldTransform.Location
    return location.X, location.Y, location.Z
end

-- cached transform first, raw one as fallback, 0,0,0 counts as not loaded
local function foliageLocation(instance)
    local cached = toLocation(pcall(foliageCacheXYZ, instance))
    if cached ~= nil and not isOrigin(cached) then
        return cached
    end
    local raw = toLocation(pcall(foliageRawXYZ, instance))
    if raw == nil or isOrigin(raw) then
        return nil
    end
    return raw
end

local function foliageTypeName(instance)
    return instance.FoliageTypeId:ToString()
end

local function readFoliageTypeId(instance)
    local ok, typeId = pcall(foliageTypeName, instance)
    if not ok or type(typeId) ~= "string" then
        return "?"
    end
    return typeId
end

-- 0 = alive, 1 = decaying (falling over), 2 = dead stump, nil if unreadable
local function readFoliageState(instance)
    if not isValid(instance) then
        return nil
    end
    local state = readField(instance, "InstanceState")
    if type(state) ~= "number" then
        return nil
    end
    return state
end

local function callGetWorld(object)
    return object:GetWorld()
end

local function readWorld(pawn)
    local ok, world = pcall(callGetWorld, pawn)
    if not ok or not isValid(world) then
        return nil
    end
    return world
end

-- UEHelpers does a FindAllOf on every call, so the controller is cached and only serached again once a second
local function getPlayerController()
    if isValid(cachedController) then
        return cachedController
    end
    cachedController = nil
    if UEHelpers == nil or now() < controllerSearchAt then
        return nil
    end
    controllerSearchAt = now() + 1000
    local ok, controller = pcall(UEHelpers.GetPlayerController)
    if not ok or not isValid(controller) then
        return nil
    end
    cachedController = controller
    return controller
end

local function getPawn()
    local controller = getPlayerController()
    if controller == nil then
        return nil
    end
    local pawn = readField(controller, "Pawn")
    if not isValid(pawn) then
        return nil
    end
    return pawn
end

-- chat line on screen, the 3 is copied from EffigyBeacons which uses the same call
local function callChat(controller, text)
    controller:EnterChat_Receive(text, 3)
end

local function say(text)
    log(text)
    if not config.chat_messages then
        return
    end
    local controller = getPlayerController()
    if controller == nil then
        return
    end
    pcall(callChat, controller, text)
end

-- cached, after a failed load it waits RETRY_BACKOFF_MS before the next try
local function getBeamAsset()
    if isValid(beamAsset) then
        return beamAsset
    end
    beamAsset = nil
    if now() < assetRetryAt then
        return nil
    end
    local ok, asset = pcall(LoadAsset, config.beam_effect_path)
    if not ok or not isValid(asset) then
        assetRetryAt = now() + RETRY_BACKOFF_MS
        logLimited("asset", "could not load beam effect " .. config.beam_effect_path)
        return nil
    end
    beamAsset = asset
    return asset
end

local function getNiagaraLibrary()
    if isValid(niagaraLibrary) then
        return niagaraLibrary
    end
    niagaraLibrary = nil
    if now() < libraryRetryAt then
        return nil
    end
    local ok, library = pcall(StaticFindObject, "/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not ok or not isValid(library) then
        libraryRetryAt = now() + RETRY_BACKOFF_MS
        logLimited("library", "could not find NiagaraFunctionLibrary")
        return nil
    end
    niagaraLibrary = library
    return library
end

local function callSetVisibility(component, visible)
    component:SetVisibility(visible, false)
end

local function callDeactivateImmediate(component)
    component:DeactivateImmediate()
end

local function callDeactivate(component)
    component:Deactivate()
end

local function callActivate(component)
    component:Activate(true)
end

local function callDestroy(component)
    component:K2_DestroyComponent(component)
end

local function callSetVec3(component, name, value)
    component:SetNiagaraVariableVec3(name, value)
end

local function callSetColor(component, name, value)
    component:SetNiagaraVariableLinearColor(name, value)
end

local function callMove(component, vector)
    component:K2_SetWorldLocation(vector, false, {}, true)
end

local function callSetScale(component, scale)
    component:SetRelativeScale3D(scale)
end

-- false = no auto destroy (pooled), true = activate now, 0 = no niagara pooling, false = no pre-cull so it always spawns
local function callSpawn(library, world, asset, vector, scale)
    return library:SpawnSystemAtLocation(world, asset, vector, ZERO_ROTATION, scale, false, true, 0, false)
end

-- location rounded to 50 cm cells plus the label, so the same spot keeps the same marker between refershes
local function markerKey(location, label)
    return math.floor(location.x / KEY_CELL_CM) .. ":"
        .. math.floor(location.y / KEY_CELL_CM) .. ":"
        .. math.floor(location.z / KEY_CELL_CM) .. ":" .. label
end

local function destroyMarker(component)
    if not isValid(component) then
        return
    end
    pcall(callSetVisibility, component, false)
    pcall(callDestroy, component)
end

-- component z scale stretches the light upwards, User.Scale alone barely did anyting on this effect
local function configureMarker(component, resource)
    pcall(callSetScale, component, resource.componentScale)
    pcall(callSetVec3, component, "User.Scale", resource.scale)
    for _, name in ipairs(config.color_parameter_names) do
        pcall(callSetColor, component, name, resource.color)
    end
    pcall(callSetVisibility, component, true)
end

-- after 3 failures in a row spawning pauses for 10 s instead of trying every tick
local function spawnMarker(world, marker)
    if now() < spawnBlockedUntil or not isValid(world) then
        return nil
    end
    local library = getNiagaraLibrary()
    local asset = getBeamAsset()
    if library == nil or asset == nil then
        return nil
    end
    local ok, component = pcall(callSpawn, library, world, asset, marker.vector, marker.resource.componentScale)
    if ok and isValid(component) then
        spawnFailures = 0
        return component
    end
    spawnFailures = spawnFailures + 1
    logLimited("spawn", "marker spawn failed: " .. tostring(component))
    if spawnFailures >= MAX_SPAWN_FAILURES then
        spawnFailures = 0
        spawnBlockedUntil = now() + RETRY_BACKOFF_MS
        log("marker spawning paused for " .. (RETRY_BACKOFF_MS / 1000) .. " s after repeated failures")
    end
    return nil
end

-- reuses a hidden marker from the pool if there is one, otherwise spawns a new one
local function acquireMarker(world, marker)
    while #freeMarkers > 0 do
        local component = table.remove(freeMarkers)
        if isValid(component) and pcall(callMove, component, marker.vector) then
            pcall(callActivate, component)
            configureMarker(component, marker.resource)
            return component
        end
        destroyMarker(component)
    end
    local component = spawnMarker(world, marker)
    if component == nil then
        return nil
    end
    configureMarker(component, marker.resource)
    return component
end

-- hidden and kept for reuse, DeactivateImmediate so no particles linger, plain Deactivate if that one fails
local function releaseMarker(component)
    if not isValid(component) then
        return
    end
    pcall(callSetVisibility, component, false)
    if not pcall(callDeactivateImmediate, component) then
        pcall(callDeactivate, component)
    end
    if #freeMarkers >= config.max_markers then
        destroyMarker(component)
        return
    end
    freeMarkers[#freeMarkers + 1] = component
end

local function hideAllMarkers()
    for key, component in pairs(activeMarkers) do
        releaseMarker(component)
        activeMarkers[key] = nil
    end
end

local function readScaleX(component)
    return component.RelativeScale3D.X
end

local function readAssetName(component)
    return component:GetAsset():GetFullName()
end

-- marker from before a hot reload, found by the x scale fingerprint and the effect name
local function isLeftoverMarker(component)
    local scaleOk, scaleX = pcall(readScaleX, component)
    if not scaleOk or scaleX ~= MARKER_SCALE_X then
        return false
    end
    local assetOk, assetName = pcall(readAssetName, component)
    if not assetOk or type(assetName) ~= "string" then
        return false
    end
    return assetName:find(BEAM_ASSET_NAME, 1, true) ~= nil
end

local function sweepLeftoverMarkers()
    local ok, components = pcall(FindAllOf, "NiagaraComponent")
    if not ok or type(components) ~= "table" then
        return
    end
    local removed = 0
    for _, component in ipairs(components) do
        if isValid(component) and isLeftoverMarker(component) then
            destroyMarker(component)
            removed = removed + 1
        end
    end
    if removed > 0 then
        log("removed " .. removed .. " marker(s) left over from a previous load")
    end
end

-- numbers for the diag lines, most of them only filled when diagnostics is on
local function newReport()
    return {
        slices = 0,
        cacheRebuilt = false,
        cacheMs = 0,
        foliageTotal = 0,
        foliageWithoutLocation = 0,
        foliageNearby = 0,
        spawnerTotal = 0,
        spawnersNearby = 0,
        mapObjectsTotal = 0,
        mapObjectsNearby = 0,
        states = {},
        deadFoliageTypes = {},
        spawnerClasses = {},
        unmatchedClasses = {},
        neighbourClasses = {},
        labels = {},
        spawned = 0,
        wallMs = 0,
    }
end

local function countInto(map, key)
    map[key] = (map[key] or 0) + 1
end

-- rebuild once the player left the cache margin or the cache is older then cache_rebuild_interval_ms
local function cacheIsStale(origin)
    if cache == nil then
        return true
    end
    if distanceSq2D(cache.origin, origin) > CACHE_MARGIN_SQ then
        return true
    end
    return now() - cache.builtAt > config.cache_rebuild_interval_ms
end

local function gridCell(value)
    return math.floor(value / MATCH_CM)
end

-- closest map object in the 3x3 cells around location, cells are MATCH_CM wide so nothing in range is mised
local function nearestOccupant(grid, location)
    local cellX = gridCell(location.x)
    local cellY = gridCell(location.y)
    local best = nil
    local bestSq = math.huge
    for dx = -1, 1 do
        local rowKey = (cellX + dx) * GRID_STRIDE + cellY
        for dy = -1, 1 do
            local bucket = grid[rowKey + dy]
            if bucket ~= nil then
                for index = 1, #bucket do
                    local entry = bucket[index]
                    local distanceSq = distanceSq3D(entry.location, location)
                    if distanceSq < bestSq then
                        best = entry
                        bestSq = distanceSq
                    end
                end
            end
        end
    end
    return best, bestSq
end

-- FindAllOf result stored on the job, empty list if it failed
local function loadList(target, classNameToFind)
    local ok, all = pcall(FindAllOf, classNameToFind)
    if not ok then
        logLimited("find:" .. classNameToFind, "FindAllOf(" .. classNameToFind .. ") failed: " .. tostring(all))
    end
    if not ok or type(all) ~= "table" then
        all = {}
    end
    target.list = all
    target.index = 1
    return #all
end

-- visits from the saved index until deadline, false = not done yet, carries on next tick
local function sweepList(target, deadline, every, visit)
    local list = target.list
    if list == nil then
        return true
    end
    local count = #list
    local index = target.index
    local sinceCheck = 0
    while index <= count do
        local item = list[index]
        index = index + 1
        target.index = index
        visit(target, item)
        sinceCheck = sinceCheck + 1
        if sinceCheck >= every then
            sinceCheck = 0
            if now() >= deadline then
                return false
            end
        end
    end
    target.list = nil
    target.index = 1
    return true
end

-- only foliage within reach is kept, so later refreshes don't walk all of it again
local function collectFoliageEntry(current, instance)
    if not isValid(instance) then
        return
    end
    local location = foliageLocation(instance)
    if location == nil then
        current.report.foliageWithoutLocation = current.report.foliageWithoutLocation + 1
        return
    end
    if distanceSq2D(location, current.origin) > REACH_SQ then
        return
    end
    local typeId = readFoliageTypeId(instance)
    local resource = resolveType(typeId, config.foliage_types, foliageTypeMemo)
    if resource == nil then
        return
    end
    current.foliage[#current.foliage + 1] = {
        object = instance, location = location, vector = toVector(location), typeId = typeId, resource = resource,
    }
end

-- spawners not in resource_types are skipped (chests, eggs, junk)
local function collectSpawnerEntry(current, spawner)
    if not isValid(spawner) then
        return
    end
    local location = actorLocation(spawner)
    if location == nil or distanceSq2D(location, current.origin) > REACH_SQ then
        return
    end
    local name = className(spawner)
    local resource = resolveType(name, config.resource_types, spawnerTypeMemo)
    if resource == nil then
        if config.diagnostics then
            countInto(current.report.unmatchedClasses, name)
        end
        return
    end
    current.spawners[#current.spawners + 1] = {
        object = spawner, location = location, vector = toVector(location), className = name, resource = resource,
    }
end

-- spawners are left out so a spawner never counts as its own rock
local function collectOccupant(current, object)
    if not isValid(object) then
        return
    end
    local location = actorLocation(object)
    if location == nil or distanceSq2D(location, current.origin) > REACH_SQ then
        return
    end
    local name = className(object)
    if name:find("Spawner", 1, true) ~= nil then
        return
    end
    local key = gridCell(location.x) * GRID_STRIDE + gridCell(location.y)
    local bucket = current.grid[key]
    if bucket == nil then
        bucket = {}
        current.grid[key] = bucket
    end
    bucket[#bucket + 1] = { location = location, className = name }
    current.report.mapObjectsNearby = current.report.mapObjectsNearby + 1
end

local function evaluateTree(current, entry)
    local state = readFoliageState(entry.object)
    if state == nil then
        return
    end
    if config.diagnostics then
        countInto(current.report.states, state)
    end
    if state == config.foliage_alive_state then
        return
    end
    local distanceSq = distanceSq2D(entry.location, current.origin)
    if distanceSq > RADIUS_SQ then
        return
    end
    if config.diagnostics then
        countInto(current.report.deadFoliageTypes, entry.typeId)
    end
    current.markers[#current.markers + 1] = entry
    entry.distanceSq = distanceSq
end

-- no map object within spawner_match_distance_cm of the spawner, so the rock was minned
local function evaluateRock(current, entry)
    local distanceSq = distanceSq2D(entry.location, current.origin)
    if distanceSq > RADIUS_SQ or not isValid(entry.object) then
        return
    end
    local report = current.report
    local classStats = nil
    if config.diagnostics then
        classStats = report.spawnerClasses[entry.className] or { total = 0, exhausted = 0 }
        classStats.total = classStats.total + 1
        report.spawnerClasses[entry.className] = classStats
    end
    local occupant, occupantSq = nearestOccupant(current.grid, entry.location)
    if occupant ~= nil and occupantSq <= MATCH_SQ then
        if config.diagnostics then
            countInto(report.neighbourClasses, occupant.className)
        end
        return
    end
    if classStats ~= nil then
        classStats.exhausted = classStats.exhausted + 1
    end
    current.markers[#current.markers + 1] = entry
    entry.distanceSq = distanceSq
end

local function byDistance(a, b)
    return a.distanceSq < b.distanceSq
end

-- stacked lights for one spot, built once and kept on the entry, one light is about 80 cm high
local function piecesOf(entry)
    local pieces = entry.pieces
    if pieces ~= nil then
        return pieces
    end
    pieces = {}
    local resource = entry.resource
    local location = entry.location
    local baseKey = markerKey(location, resource.label)
    for level = 0, resource.stack - 1 do
        pieces[#pieces + 1] = {
            key = baseKey .. ":" .. level,
            resource = resource,
            vector = { X = location.x, Y = location.y, Z = location.z + level * resource.stackStep },
        }
    end
    entry.pieces = pieces
    return pieces
end

-- only sorted when there are more spots than max_markers, so the closest ones win
local function selectMarkers(current)
    local markers = current.markers
    if #markers > config.max_markers then
        table.sort(markers, byDistance)
    end
    local wanted = {}
    for index = 1, math.min(#markers, config.max_markers) do
        local marker = markers[index]
        local pieces = piecesOf(marker)
        for pieceIndex = 1, #pieces do
            local piece = pieces[pieceIndex]
            wanted[piece.key] = piece
        end
        countInto(current.report.labels, marker.resource.label)
    end
    return wanted
end

local function formatCounts(map)
    local parts = {}
    for key, value in pairs(map) do
        if type(value) == "table" then
            parts[#parts + 1] = tostring(key) .. "=" .. tostring(value.exhausted) .. "/" .. tostring(value.total)
        else
            parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
        end
    end
    table.sort(parts)
    if #parts == 0 then
        return "(none)"
    end
    return table.concat(parts, ", ")
end

-- diag only, property names of the class up to Actor or Object
local function collectPropertyNames(object, names)
    local struct = object:GetClass()
    while isValid(struct) do
        local structName = struct:GetFName():ToString()
        if structName == "Actor" or structName == "Object" then
            return
        end
        struct:ForEachProperty(function(property)
            names[#names + 1] = structName .. "." .. property:GetFName():ToString()
        end)
        struct = struct:GetSuperStruct()
    end
end

local function propertyNames(object)
    local names = {}
    pcall(collectPropertyNames, object, names)
    return table.concat(names, ", ")
end

local function logProperties()
    if propertiesLogged or cache == nil then
        return
    end
    propertiesLogged = true
    if cache.foliage[1] ~= nil then
        log("diag foliage instance properties: " .. propertyNames(cache.foliage[1].object))
    end
    if cache.spawners[1] ~= nil then
        log("diag spawner properties (" .. cache.spawners[1].className .. "): "
            .. propertyNames(cache.spawners[1].object))
    end
end

local function logReport(report)
    if not config.diagnostics then
        return
    end
    if report.cacheRebuilt then
        log(string.format("diag cache rebuilt in %.1f ms: foliage in memory %d (no location %d, within reach %d),"
            .. " spawners %d (listed within reach %d)",
            report.cacheMs, report.foliageTotal, report.foliageWithoutLocation, report.foliageNearby,
            report.spawnerTotal, report.spawnersNearby))
    end
    if diagnosticsLogged and not report.cacheRebuilt then
        return
    end
    diagnosticsLogged = true
    log("diag foliage states within reach: " .. formatCounts(report.states))
    log("diag dead foliage type ids: " .. formatCounts(report.deadFoliageTypes))
    log("diag spawner classes within radius (exhausted/total): " .. formatCounts(report.spawnerClasses))
    log("diag unlisted spawner classes within reach (ignored): " .. formatCounts(report.unmatchedClasses))
    log("diag map objects occupying spawners: " .. formatCounts(report.neighbourClasses)
        .. " (map objects in memory " .. report.mapObjectsTotal .. ", within reach " .. report.mapObjectsNearby .. ")")
    log(string.format("diag refresh took %.1f ms wall over %d slice(s); markers: %s; %d newly shown",
        report.wallMs, report.slices, formatCounts(report.labels), report.spawned))
    logProperties()
end

local function spawnPending(current, item)
    local component = acquireMarker(current.world, item.marker)
    if component == nil then
        return
    end
    activeMarkers[item.key] = component
    current.report.spawned = current.report.spawned + 1
end

-- refresh split in steps, each one can stop when the time budget is used and carry on next tick
-- NO COROUTINES HERE, UE4SS FUNCTIONS FAIL INSIDE A COROUTINE ("lua state has no instance")
local STAGES = {
    -- find foliage
    function(current)
        if not current.rebuild or not config.show_trees then
            return true
        end
        current.report.foliageTotal = loadList(current, "PalFoliageInstance")
        return true
    end,
    -- foliage in reach
    function(current, deadline)
        return sweepList(current, deadline, CLOCK_CHECK_EVERY, collectFoliageEntry)
    end,
    -- find spawners
    function(current)
        if not current.rebuild or not config.show_rocks or #config.resource_types == 0 then
            return true
        end
        current.report.spawnerTotal = loadList(current, "PalMapObjectSpawnerBase")
        return true
    end,
    -- listed spawners in reach
    function(current, deadline)
        return sweepList(current, deadline, CLOCK_CHECK_EVERY, collectSpawnerEntry)
    end,
    -- save cache
    function(current)
        if current.rebuild then
            cache = { origin = current.origin, builtAt = now(), foliage = current.foliage, spawners = current.spawners }
            current.report.cacheRebuilt = true
            current.report.cacheMs = now() - current.started
            current.report.foliageNearby = #current.foliage
            current.report.spawnersNearby = #current.spawners
        end
        if cache == nil then
            return true
        end
        current.list = cache.foliage
        current.index = 1
        return true
    end,
    -- tree states
    function(current, deadline)
        return sweepList(current, deadline, CLOCK_CHECK_EVERY, evaluateTree)
    end,
    -- find map objects
    function(current)
        if cache == nil or #cache.spawners == 0 then
            return true
        end
        current.report.mapObjectsTotal = loadList(current, "PalMapObject")
        return true
    end,
    -- map objects into grid
    function(current, deadline)
        return sweepList(current, deadline, CLOCK_CHECK_EVERY, collectOccupant)
    end,
    -- queue spawners
    function(current)
        if cache == nil then
            return true
        end
        current.list = cache.spawners
        current.index = 1
        return true
    end,
    -- mined rocks
    function(current, deadline)
        return sweepList(current, deadline, CLOCK_CHECK_EVERY, evaluateRock)
    end,
    -- markers that went away get hidden, new ones get queued
    function(current)
        local wanted = selectMarkers(current)
        for key, component in pairs(activeMarkers) do
            if wanted[key] == nil or not isValid(component) then
                releaseMarker(component)
                activeMarkers[key] = nil
            end
        end
        local pending = {}
        for key, marker in pairs(wanted) do
            if activeMarkers[key] == nil then
                pending[#pending + 1] = { key = key, marker = marker }
            end
        end
        current.list = pending
        current.index = 1
        return true
    end,
    -- spawn new markers
    function(current, deadline)
        if not isValid(current.world) then
            current.list = nil
            return true
        end
        return sweepList(current, deadline, SPAWN_CLOCK_CHECK_EVERY, spawnPending)
    end,
    -- report
    function(current)
        current.report.wallMs = now() - current.started
        logReport(current.report)
        if not announceNextResult then
            return true
        end
        announceNextResult = false
        say(string.format("Exhausted within %d m: %s", config.radius_meters, formatCounts(current.report.labels)))
        return true
    end,
}

local function finishJob()
    job = nil
    lastRefreshAt = now()
end

local function disableMod(reason)
    disabled = true
    job = nil
    pcall(hideAllMarkers)
    log("mod disabled until the game restarts: " .. tostring(reason))
end

-- 10 failures in a row switch the mod off, so a broken state can't keep erroring every tick
local function recordFailure(where, err)
    consecutiveFailures = consecutiveFailures + 1
    logLimited(where, where .. " failed: " .. tostring(err))
    if consecutiveFailures < MAX_CONSECUTIVE_FAILURES then
        return
    end
    disableMod(consecutiveFailures .. " consecutive errors, last in " .. where)
end

-- runs stages until one isn't finished or the budget is used up
local function advanceJob()
    local deadline = now() + config.scan_budget_ms
    job.report.slices = job.report.slices + 1
    while job ~= nil and job.stage <= #STAGES do
        local stage = job.stage
        local ok, done = pcall(STAGES[stage], job, deadline)
        if not ok then
            recordFailure("refresh stage " .. stage, done)
            finishJob()
            return
        end
        if not done then
            return
        end
        job.stage = stage + 1
        if now() >= deadline and job.stage <= #STAGES then
            return
        end
    end
    finishJob()
end

local function startJob(pawn)
    local origin = actorLocation(pawn)
    if origin == nil or not isValid(sessionWorld) then
        return
    end
    job = {
        world = sessionWorld,
        origin = origin,
        rebuild = cacheIsStale(origin),
        started = now(),
        stage = 1,
        list = nil,
        index = 1,
        foliage = {},
        spawners = {},
        grid = {},
        markers = {},
        report = newReport(),
    }
    advanceJob()
end

-- builder component on teh player, searched again at most every 2 s
local function findBuilder()
    if isValid(builder) then
        return builder
    end
    builder = nil
    if now() < builderSearchAt then
        return nil
    end
    builderSearchAt = now() + 2000
    local ok, found = pcall(FindFirstOf, "PalBuilderComponent")
    if not ok or not isValid(found) then
        return nil
    end
    builder = found
    return builder
end

-- InstallChecker only exists and is visible while the build menu is open
local function readBuildMode()
    local component = findBuilder()
    if component == nil then
        return false
    end
    local checker = readField(component, "InstallChecker")
    if not isValid(checker) then
        return false
    end
    return readField(checker, "bHidden") ~= true
end

local function updateBuildMode()
    if not config.show_in_build_mode then
        buildModeOn = false
        return
    end
    local current = readBuildMode()
    if current == buildModeOn then
        return
    end
    buildModeOn = current
    if config.diagnostics then
        log("diag build mode " .. (current and "entered" or "left"))
    end
end

-- diag only, user parameters of an effect (that's how User.Color was found)
local function collectUserParameters(asset, names)
    asset.ExposedParameters.SortedParameterOffsets:ForEach(function(_, element)
        names[#names + 1] = element:get().Name:ToString()
    end)
end

local function logEffectParameters()
    if not config.diagnostics or effectsLogged then
        return
    end
    effectsLogged = true
    for _, path in ipairs(config.diagnostic_effect_paths) do
        local ok, asset = pcall(LoadAsset, path)
        if not ok or not isValid(asset) then
            log("diag effect " .. path .. " could not be loaded")
        else
            local names = {}
            local readOk, err = pcall(collectUserParameters, asset, names)
            local text = readOk and table.concat(names, ", ") or ("unreadable (" .. tostring(err) .. ")")
            log("diag effect " .. path .. " user parameters: " .. text)
        end
    end
end

-- old world is gone, so marker references are dropped without touchnig them
local function endSession(reason)
    if not sessionReady then
        return
    end
    sessionReady = false
    wasActive = false
    job = nil
    cache = nil
    builder = nil
    beamAsset = nil
    sessionWorld = nil
    sessionWorldAddress = nil
    sessionPawnAddress = nil
    activeMarkers = {}
    freeMarkers = {}
    log("session ended (" .. reason .. "), marker references dropped")
end

local function beginSession(pawn, pawnAddress, world, worldAddress)
    sessionReady = true
    sessionPawnAddress = pawnAddress
    sessionWorld = world
    sessionWorldAddress = worldAddress
    diagnosticsLogged = false
    sweepLeftoverMarkers()
    logEffectParameters()
    log("session started")
end

-- same pawn = nothing to do, new pawn in the same world (respawn) keeps the markres, new world starts over
local function trackSession(pawn)
    local pawnAddress = addressOf(pawn)
    if sessionReady and pawnAddress ~= nil and pawnAddress == sessionPawnAddress and isValid(sessionWorld) then
        return true
    end
    local world = readWorld(pawn)
    if world == nil then
        endSession("world unavailable")
        return false
    end
    local worldAddress = addressOf(world)
    if sessionReady and worldAddress == sessionWorldAddress then
        sessionPawnAddress = pawnAddress
        sessionWorld = world
        return true
    end
    endSession("world changed")
    beginSession(pawn, pawnAddress, world, worldAddress)
    return true
end

local function deactivate()
    if not wasActive then
        return
    end
    wasActive = false
    job = nil
    hideAllMarkers()
end

local function tick()
    if disabled then
        return
    end
    local pawn = getPawn()
    if pawn == nil then
        endSession("no player")
        return
    end
    if not trackSession(pawn) then
        return
    end
    updateBuildMode()
    -- markers show when F9 is on or the build menu is open
    if not hotkeyOn and not buildModeOn then
        deactivate()
        return
    end
    if not wasActive then
        wasActive = true
        forceRefresh = true
    end
    if job ~= nil then
        advanceJob()
        return
    end
    if not forceRefresh and now() - lastRefreshAt < config.refresh_interval_ms then
        return
    end
    forceRefresh = false
    startJob(pawn)
end

-- tickPending cleared first, so the next loop can queue agian
local function runTick()
    tickPending = false
    local ok, err = pcall(tick)
    if ok then
        consecutiveFailures = 0
        return
    end
    recordFailure("tick", err)
end

local function toggle()
    if disabled then
        say("Exhausted resource markers are disabled after repeated errors, see UE4SS.log")
        return
    end
    hotkeyOn = not hotkeyOn
    if not hotkeyOn then
        say("Exhausted resource markers OFF")
        return
    end
    forceRefresh = true
    announceNextResult = true
    say("Exhausted resource markers ON")
end

local function runToggle()
    local ok, err = pcall(toggle)
    if not ok then
        logLimited("toggle", "toggle failed: " .. tostring(err))
    end
end

-- keybind runs off the game thread, so the toggle is handed over to it
local function onHotkey()
    pcall(ExecuteInGameThread, runToggle)
end

local function registerHotkey()
    local key = Key ~= nil and Key[config.toggle_key] or nil
    if key == nil then
        log("unknown toggle_key '" .. tostring(config.toggle_key) .. "', hotkey disabled")
        return
    end
    local modifiers = {}
    for _, name in ipairs(config.toggle_modifiers) do
        local modifier = ModifierKey ~= nil and ModifierKey[name] or nil
        if modifier == nil then
            log("unknown toggle modifier '" .. tostring(name) .. "', hotkey disabled")
            return
        end
        modifiers[#modifiers + 1] = modifier
    end
    local ok, err
    if #modifiers == 0 then
        ok, err = pcall(RegisterKeyBind, key, onHotkey)
    else
        ok, err = pcall(RegisterKeyBind, key, modifiers, onHotkey)
    end
    if not ok then
        log("hotkey registration failed: " .. tostring(err))
        return
    end
    local label = table.concat(config.toggle_modifiers, "+")
    if label ~= "" then
        label = label .. "+"
    end
    log("toggle key: " .. label .. config.toggle_key)
end

local function clearMarkerEffects()
    for _, component in pairs(activeMarkers) do destroyMarker(component) end
    for _, component in ipairs(freeMarkers) do destroyMarker(component) end
    activeMarkers, freeMarkers = {}, {}
end

local function applySetting(key, value)
    local axis = key:match("^beam_scale%.([xyz])$")
    if axis then
        if not isFiniteNumber(value) then return end
        axis = axis:upper()
        value = clamp(value, 0.05, 50)
        if config.beam_scale[axis] == value then return end
        config.beam_scale[axis] = value
        hideAllMarkers()
    elseif key == "color_parameter_names" then
        if type(value) ~= "string" then return end
        local names = {}
        for part in value:gmatch("[^,]+") do
            local name = part:match("^%s*(.-)%s*$")
            if name ~= "" then names[#names + 1] = name end
        end
        if table.concat(names, "\0") == table.concat(config.color_parameter_names, "\0") then return end
        config.color_parameter_names = names
        clearMarkerEffects()
    else
        if type(value) ~= type(config[key]) or config[key] == value then return end
        if type(value) == "number" then
            if not isFiniteNumber(value) then return end
            local range = LIMITS[key]
            if range then value = clamp(value, range[1], range[2]) end
            if key == "max_markers" or key == "radius_meters" or key == "foliage_alive_state" then
                value = math.floor(value)
            end
        end
        if key == "beam_effect_path" and value == "" then return end
        config[key] = value
    end

    nextTickAt = -math.huge
    if key == "poll_interval_ms" or key == "refresh_interval_ms" or key == "scan_budget_ms"
        or key == "chat_messages" or key == "toggle_key" or key == "cache_rebuild_interval_ms" then return end

    if key == "radius_meters" or key == "cache_margin_meters" or key == "spawner_match_distance_cm" then
        updateScanDistances()
        cache = nil
    elseif key == "show_trees" or key == "show_rocks" then
        cache = nil
    elseif key == "beam_effect_path" then
        clearMarkerEffects()
        BEAM_ASSET_NAME = value:match("%.([^%.]+)$") or value
        beamAsset, assetRetryAt, spawnFailures, spawnBlockedUntil = nil, 0, 0, 0
    elseif key == "max_markers" then
        while #freeMarkers > value do destroyMarker(table.remove(freeMarkers)) end
    elseif key == "diagnostics" and value then
        diagnosticsLogged, propertiesLogged, effectsLogged = false, false, false
        if sessionReady then logEffectParameters() end
    end
    job = nil
    forceRefresh = true
end

local nativeHotkey = false
local hasMenu, managesHotkey = require("marker_settings")(config, LIMITS, log, applySetting, function()
    if nativeHotkey then runToggle() end
end)
nativeHotkey = managesHotkey
if not nativeHotkey then registerHotkey() end

-- LoopAsync thread, only queues a game thread tick once the last one ran, so they can't pile up on a slow frmae
local function onLoop()
    if tickPending or disabled then
        return false
    end
    if hasMenu then
        local time = now()
        if time < nextTickAt then return false end
        nextTickAt = time + config.poll_interval_ms
    end
    tickPending = true
    if not pcall(ExecuteInGameThread, runTick) then
        tickPending = false
    end
    return false
end

-- With the menu active, the loop wakes at the shortest supported interval and queues scans at the configured rate.
local loopOk, loopErr = pcall(LoopAsync, hasMenu and LIMITS.poll_interval_ms[1] or config.poll_interval_ms, onLoop)
if not loopOk then
    log("could not start the update loop, mod inactive: " .. tostring(loopErr))
end

log("v" .. MOD_VERSION .. " loaded")
