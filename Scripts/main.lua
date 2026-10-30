local UEHelpers = require("UEHelpers")
local config = require("config")

local MOD_VERSION = "0.3.0"
local TAG = "[ExhaustedResourceMarkers] "
-- exact float only this mod uses as z scale, so markers left from an earlier load can be recognised and removed
local MARKER_SCALE_Z = 1.0009765625
local KEY_CELL_CM = 50 -- markers closer than this share a kye
local RADIUS_CM = config.radius_meters * 100
local RADIUS_SQ = RADIUS_CM * RADIUS_CM
local CACHE_MARGIN_CM = config.cache_margin_meters * 100
local CACHE_MARGIN_SQ = CACHE_MARGIN_CM * CACHE_MARGIN_CM
-- cache keeps a bit more than the radius, so walking arround doesn't rebuild it every refresh
local REACH_SQ = (RADIUS_CM + CACHE_MARGIN_CM) * (RADIUS_CM + CACHE_MARGIN_CM)
local MATCH_CM = config.spawner_match_distance_cm
local MATCH_SQ = MATCH_CM * MATCH_CM
local BEAM_ASSET_NAME = config.beam_effect_path:match("%.([^%.]+)$") or config.beam_effect_path
local ZERO_ROTATION = { Pitch = 0, Yaw = 0, Roll = 0 }
local CLOCK_CHECK_EVERY = 32 -- items bewteen clock checks while scanning

local hotkeyOn = false
local buildModeOn = false
local wasActive = false
-- set once a player exists, cleared when the player is gone so the markers get dropped
local sessionReady = false
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
local niagaraLibrary = nil
local diagnosticsLogged = false
local propertiesLogged = false

local function log(message)
    print(TAG .. message .. "\n")
end

-- milliseconds, os.clock is wall time on windows so it works as a timer
local function now()
    return os.clock() * 1000
end

-- false for nil or anything that throws
local function isValid(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function() return object:IsValid() end)
    return ok and valid == true
end

-- runs getter in pcall, nil unless it gives back three numbers
local function readVector(getter)
    local ok, x, y, z = pcall(getter)
    if not ok or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
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
    local dz = a.z - b.z
    return distanceSq2D(a, b) + dz * dz
end

local function toVector(location)
    return { X = location.x, Y = location.y, Z = location.z }
end

-- class name, or ? if it can't be read
local function className(object)
    local ok, name = pcall(function() return object:GetClass():GetFName():ToString() end)
    if not ok or type(name) ~= "string" then
        return "?"
    end
    return name
end

-- not case sensitive, so lowercase class names like bp_palmapobjectspawner_palegg still match
local function containsAny(text, needles)
    local lowered = text:lower()
    for _, needle in ipairs(needles) do
        if lowered:find(needle:lower(), 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function actorLocation(actor)
    return readVector(function()
        local location = actor:K2_GetActorLocation()
        return location.X, location.Y, location.Z
    end)
end

-- cached transform first, raw one as fallback, 0,0,0 counts as not loaded
local function foliageLocation(instance)
    local cached = readVector(function()
        local translation = instance.WorldTransformCache.Translation
        return translation.X, translation.Y, translation.Z
    end)
    if cached ~= nil and not isOrigin(cached) then
        return cached
    end
    local raw = readVector(function()
        local location = instance.WorldTransform.Location
        return location.X, location.Y, location.Z
    end)
    if raw == nil or isOrigin(raw) then
        return nil
    end
    return raw
end

-- 0 = alive, 1 = decaying (falling over), 2 = dead stump, nil if unreadable
local function readFoliageState(instance)
    if not isValid(instance) then
        return nil
    end
    local ok, state = pcall(function() return instance.InstanceState end)
    if not ok or type(state) ~= "number" then
        return nil
    end
    return state
end

-- UEHelpers does a FindAllOf on every call, so the controller is cached and only searched again once a second
local function getPlayerController()
    if isValid(cachedController) then
        return cachedController
    end
    cachedController = nil
    if now() < controllerSearchAt then
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
    local ok, pawn = pcall(function() return controller.Pawn end)
    if not ok or not isValid(pawn) then
        return nil
    end
    return pawn
end

-- log line plus a chat line, the 3 is copied from EffigyBeacons which uses the same call
local function say(text)
    log(text)
    if not config.chat_messages then
        return
    end
    local controller = getPlayerController()
    if controller == nil then
        return
    end
    pcall(function() controller:EnterChat_Receive(text, 3) end)
end

-- cached, loaded agian once the asset went invalid
local function getBeamAsset()
    if isValid(beamAsset) then
        return beamAsset
    end
    local ok, asset = pcall(LoadAsset, config.beam_effect_path)
    if not ok or not isValid(asset) then
        log("could not load beam effect " .. config.beam_effect_path)
        return nil
    end
    beamAsset = asset
    return asset
end

local function getNiagaraLibrary()
    if isValid(niagaraLibrary) then
        return niagaraLibrary
    end
    local ok, library = pcall(StaticFindObject, "/Script/Niagara.Default__NiagaraFunctionLibrary")
    if not ok or not isValid(library) then
        log("could not find NiagaraFunctionLibrary")
        return nil
    end
    niagaraLibrary = library
    return library
end

-- tree or rock scale from config, goes into User.Scale
local function beamScaleFor(kind)
    local scale = config.rock_beam_scale
    if kind == "tree" then
        scale = config.tree_beam_scale
    end
    return { X = scale.x, Y = scale.y, Z = scale.z }
end

-- location rounded to 50 cm cells, so the same spot keeps the same marker between refreshes
local function markerKey(location)
    return string.format("%d:%d:%d",
        math.floor(location.x / KEY_CELL_CM),
        math.floor(location.y / KEY_CELL_CM),
        math.floor(location.z / KEY_CELL_CM))
end

local function destroyMarker(component)
    if not isValid(component) then
        return
    end
    pcall(function() component:SetVisibility(false, false) end)
    pcall(function() component:K2_DestroyComponent(component) end)
end

-- User.Scale for trees or rocks, then visible
local function configureMarker(component, marker)
    pcall(function() component:SetNiagaraVariableVec3("User.Scale", beamScaleFor(marker.kind)) end)
    pcall(function() component:SetVisibility(true, false) end)
end

-- true if the move worked, pooled markers are moved instead of spawned agian
local function moveMarker(component, location)
    local ok = pcall(function() component:K2_SetWorldLocation(toVector(location), false, {}, true) end)
    return ok
end

-- spawned with the z scale fingerprint, false, true, 0, false = keep it (pooled), activate now, no niagara pooling, always spawn
local function spawnMarker(world, marker)
    local library = getNiagaraLibrary()
    local asset = getBeamAsset()
    if library == nil or asset == nil then
        return nil
    end
    local ok, component = pcall(function()
        return library:SpawnSystemAtLocation(world, asset, toVector(marker.location), ZERO_ROTATION,
            { X = 1, Y = 1, Z = MARKER_SCALE_Z }, false, true, 0, false)
    end)
    if not ok then
        log("marker spawn failed: " .. tostring(component))
        return nil
    end
    if not isValid(component) then
        return nil
    end
    return component
end

-- reuses a hidden marker from the pool if there is one, otherwise spawns a new one
local function acquireMarker(world, marker)
    while #freeMarkers > 0 do
        local component = table.remove(freeMarkers)
        if isValid(component) and moveMarker(component, marker.location) then
            pcall(function() component:Activate(true) end)
            configureMarker(component, marker)
            return component
        end
        destroyMarker(component)
    end
    local component = spawnMarker(world, marker)
    if component == nil then
        return nil
    end
    configureMarker(component, marker)
    return component
end

-- hidden and kept for reuse, DeactivateImmediate so no particles linger, plain Deactivate if that one fails
local function releaseMarker(component)
    if not isValid(component) then
        return
    end
    pcall(function() component:SetVisibility(false, false) end)
    local immediateOk = pcall(function() component:DeactivateImmediate() end)
    if not immediateOk then
        pcall(function() component:Deactivate() end)
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

-- marker from before a hot reload, found by the z scale fingerprint and the effect name
local function isLeftoverMarker(component)
    local scaleOk, scaleZ = pcall(function() return component.RelativeScale3D.Z end)
    if not scaleOk or scaleZ ~= MARKER_SCALE_Z then
        return false
    end
    local assetOk, assetName = pcall(function() return component:GetAsset():GetFullName() end)
    if not assetOk or type(assetName) ~= "string" then
        return false
    end
    return assetName:find(BEAM_ASSET_NAME, 1, true) ~= nil
end

local function sweepLeftoverMarkers()
    local ok, components = pcall(FindAllOf, "NiagaraComponent")
    if not ok or components == nil then
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

-- numbers for the diag lines
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
        spawnerClasses = {},
        neighbourClasses = {},
        trees = 0,
        rocks = 0,
        spawned = 0,
        wallMs = 0,
    }
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

-- grid cell as a string key, cells are MATCH_CM wide
local function cellKey(x, y)
    return math.floor(x / MATCH_CM) .. ":" .. math.floor(y / MATCH_CM)
end

-- closest map object in the 3x3 cells around location, cells are MATCH_CM wide so nothign in range is missed
local function nearestOccupant(grid, location)
    local cellX = math.floor(location.x / MATCH_CM)
    local cellY = math.floor(location.y / MATCH_CM)
    local best = nil
    local bestSq = math.huge
    for dx = -1, 1 do
        for dy = -1, 1 do
            local bucket = grid[(cellX + dx) .. ":" .. (cellY + dy)]
            if bucket ~= nil then
                for _, entry in ipairs(bucket) do
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

local function countInto(map, key)
    map[key] = (map[key] or 0) + 1
end

-- FindAllOf result stored on the job, empty list if it failed
local function loadList(target, classNameToFind)
    local ok, all = pcall(FindAllOf, classNameToFind)
    if not ok then
        log("FindAllOf(" .. classNameToFind .. ") failed: " .. tostring(all))
    end
    target.list = (ok and all) or {}
    target.index = 1
    return #target.list
end

-- visits from the saved index until deadline, false = not done yet, carries on next tick
local function sweepList(target, deadline, every, visit)
    local list = target.list
    if list == nil then
        return true
    end
    local sinceCheck = 0
    while target.index <= #list do
        visit(list[target.index])
        target.index = target.index + 1
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

-- only foliage within reach is kept, so later refreshes don't walk all of it agian
local function collectFoliageEntry(current, instance)
    local location = nil
    if isValid(instance) then
        location = foliageLocation(instance)
    end
    if location == nil then
        current.report.foliageWithoutLocation = current.report.foliageWithoutLocation + 1
        return
    end
    if distanceSq2D(location, current.origin) > REACH_SQ then
        return
    end
    current.foliage[#current.foliage + 1] = { object = instance, location = location }
end

-- spawners matching spawner_class_excludes are skipped (chests, eggs, junk), not case sensitive
local function collectSpawnerEntry(current, spawner)
    if not isValid(spawner) then
        return
    end
    local name = className(spawner)
    if containsAny(name, config.spawner_class_excludes) then
        return
    end
    local location = actorLocation(spawner)
    if location == nil or distanceSq2D(location, current.origin) > REACH_SQ then
        return
    end
    current.spawners[#current.spawners + 1] = { object = spawner, location = location, className = name }
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
    local key = cellKey(location.x, location.y)
    local bucket = current.grid[key] or {}
    bucket[#bucket + 1] = { location = location, className = name }
    current.grid[key] = bucket
    current.report.mapObjectsNearby = current.report.mapObjectsNearby + 1
end

-- anything not alive within the radius gets a tree marker
local function evaluateTree(current, entry)
    local state = readFoliageState(entry.object)
    if state == nil then
        return
    end
    countInto(current.report.states, state)
    if state == config.foliage_alive_state then
        return
    end
    local distanceSq = distanceSq2D(entry.location, current.origin)
    if distanceSq > RADIUS_SQ then
        return
    end
    current.markers[#current.markers + 1] = { kind = "tree", location = entry.location, distanceSq = distanceSq }
end

-- no map object within spawner_match_distance_cm of the spawner, so the rock was mined
local function evaluateRock(current, entry)
    local distanceSq = distanceSq2D(entry.location, current.origin)
    if distanceSq > RADIUS_SQ or not isValid(entry.object) then
        return
    end
    local report = current.report
    local classStats = report.spawnerClasses[entry.className] or { total = 0, exhausted = 0 }
    classStats.total = classStats.total + 1
    report.spawnerClasses[entry.className] = classStats
    local occupant, occupantSq = nearestOccupant(current.grid, entry.location)
    if occupant ~= nil and occupantSq <= MATCH_SQ then
        countInto(report.neighbourClasses, occupant.className)
        return
    end
    classStats.exhausted = classStats.exhausted + 1
    current.markers[#current.markers + 1] = { kind = "rock", location = entry.location, distanceSq = distanceSq }
end

-- closest max_markers spots, counted as trees or rocks for the chat line
local function selectMarkers(current)
    local markers = current.markers
    table.sort(markers, function(a, b) return a.distanceSq < b.distanceSq end)
    local wanted = {}
    for index = 1, math.min(#markers, config.max_markers) do
        local marker = markers[index]
        wanted[markerKey(marker.location)] = marker
        if marker.kind == "tree" then
            current.report.trees = current.report.trees + 1
        else
            current.report.rocks = current.report.rocks + 1
        end
    end
    return wanted
end

-- key=count list for the diag lines, (none) if empty
local function formatCounts(map)
    local parts = {}
    for key, value in pairs(map) do
        if type(value) == "table" then
            parts[#parts + 1] = tostring(key) .. "=" .. value.exhausted .. "/" .. value.total
        else
            parts[#parts + 1] = tostring(key) .. "=" .. value
        end
    end
    table.sort(parts)
    if #parts == 0 then
        return "(none)"
    end
    return table.concat(parts, ", ")
end

-- diag only, property names of the class up to Actor or Object
local function propertyNames(object)
    local names = {}
    pcall(function()
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
    end)
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

-- diag lines, the detailed ones only once per session unless the cache was rebuilt
local function logReport(report)
    if not config.diagnostics then
        return
    end
    if report.cacheRebuilt then
        log(string.format("diag cache rebuilt in %.1f ms: foliage in memory %d (no location %d, within reach %d),"
            .. " spawners %d (within reach after excludes %d)",
            report.cacheMs, report.foliageTotal, report.foliageWithoutLocation, report.foliageNearby,
            report.spawnerTotal, report.spawnersNearby))
    end
    if diagnosticsLogged and not report.cacheRebuilt then
        return
    end
    diagnosticsLogged = true
    log("diag foliage states within reach: " .. formatCounts(report.states))
    log("diag spawner classes within radius (exhausted/total): " .. formatCounts(report.spawnerClasses))
    log("diag map objects occupying spawners: " .. formatCounts(report.neighbourClasses)
        .. " (map objects in memory " .. report.mapObjectsTotal .. ", within reach " .. report.mapObjectsNearby .. ")")
    log(string.format("diag refresh took %.1f ms wall over %d slice(s); markers: %d trees, %d rocks, %d newly shown",
        report.wallMs, report.slices, report.trees, report.rocks, report.spawned))
    logProperties()
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
        return sweepList(current, deadline, CLOCK_CHECK_EVERY, function(instance)
            collectFoliageEntry(current, instance)
        end)
    end,
    -- find spawners
    function(current)
        if not current.rebuild or not config.show_rocks then
            return true
        end
        current.report.spawnerTotal = loadList(current, "PalMapObjectSpawnerBase")
        return true
    end,
    -- spawners in reach
    function(current, deadline)
        return sweepList(current, deadline, CLOCK_CHECK_EVERY, function(spawner)
            collectSpawnerEntry(current, spawner)
        end)
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
        current.list = cache.foliage
        current.index = 1
        return true
    end,
    -- tree states
    function(current, deadline)
        return sweepList(current, deadline, CLOCK_CHECK_EVERY, function(entry)
            evaluateTree(current, entry)
        end)
    end,
    -- find map objects
    function(current)
        if #cache.spawners == 0 then
            return true
        end
        current.report.mapObjectsTotal = loadList(current, "PalMapObject")
        return true
    end,
    -- map objects into grid
    function(current, deadline)
        return sweepList(current, deadline, CLOCK_CHECK_EVERY, function(object)
            collectOccupant(current, object)
        end)
    end,
    -- queue spawners
    function(current)
        current.list = cache.spawners
        current.index = 1
        return true
    end,
    -- mined rocks
    function(current, deadline)
        return sweepList(current, deadline, CLOCK_CHECK_EVERY, function(entry)
            evaluateRock(current, entry)
        end)
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
        return sweepList(current, deadline, 4, function(item)
            local component = acquireMarker(current.world, item.marker)
            if component == nil then
                return
            end
            activeMarkers[item.key] = component
            current.report.spawned = current.report.spawned + 1
        end)
    end,
    -- report
    function(current)
        current.report.wallMs = now() - current.started
        logReport(current.report)
        if not announceNextResult then
            return true
        end
        announceNextResult = false
        say(string.format("Exhausted within %d m: %d trees, %d rocks",
            config.radius_meters, current.report.trees, current.report.rocks))
        return true
    end,
}

local function finishJob()
    job = nil
    lastRefreshAt = now()
end

-- runs stages until one isn't finished or the budget is used up, a failing stage drops the whole refresh
local function advanceJob()
    local deadline = now() + config.scan_budget_ms
    job.report.slices = job.report.slices + 1
    while job.stage <= #STAGES do
        local ok, done = pcall(STAGES[job.stage], job, deadline)
        if not ok then
            log("refresh failed at stage " .. job.stage .. ": " .. tostring(done))
            finishJob()
            return
        end
        if not done then
            return
        end
        job.stage = job.stage + 1
        if now() >= deadline and job.stage <= #STAGES then
            return
        end
    end
    finishJob()
end

local function startJob(pawn)
    local origin = actorLocation(pawn)
    if origin == nil then
        return
    end
    local ok, world = pcall(function() return pawn:GetWorld() end)
    if not ok or not isValid(world) then
        return
    end
    job = {
        world = world,
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

-- builder component on the player, searched again at most every 2 s
local function findBuilder()
    if isValid(builder) then
        return builder
    end
    if now() < builderSearchAt then
        return nil
    end
    builderSearchAt = now() + 2000
    local ok, found = pcall(FindFirstOf, "PalBuilderComponent")
    if not ok or not isValid(found) then
        return nil
    end
    builder = found
    if config.diagnostics then
        log("diag builder component: " .. tostring(found:GetFullName()))
    end
    return builder
end

-- InstallChecker only exists and is visible while the build menu is open
local function readBuildMode()
    local component = findBuilder()
    if component == nil then
        return false
    end
    local ok, checker = pcall(function() return component.InstallChecker end)
    if not ok or not isValid(checker) then
        return false
    end
    local hiddenOk, hidden = pcall(function() return checker.bHidden end)
    if hiddenOk and hidden == true then
        return false
    end
    return true
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

-- player gone (menu, loading), the markers went with the world so the references are just droped
local function endSession()
    if not sessionReady then
        return
    end
    sessionReady = false
    wasActive = false
    job = nil
    cache = nil
    builder = nil
    beamAsset = nil
    activeMarkers = {}
    freeMarkers = {}
    log("session ended, markers dropped")
end

-- first tick with a player, removes markers left from a hot relaod
local function beginSession()
    if sessionReady then
        return
    end
    sessionReady = true
    diagnosticsLogged = false
    sweepLeftoverMarkers()
    log("session started")
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
    local pawn = getPawn()
    if pawn == nil then
        endSession()
        return
    end
    beginSession()
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

local function toggle()
    hotkeyOn = not hotkeyOn
    if not hotkeyOn then
        say("Exhausted resource markers OFF")
        return
    end
    forceRefresh = true
    announceNextResult = true
    say("Exhausted resource markers ON")
end

local function registerHotkey()
    local key = Key[config.toggle_key]
    if key == nil then
        log("unknown toggle_key '" .. tostring(config.toggle_key) .. "', hotkey disabled")
        return
    end
    local modifiers = {}
    for _, name in ipairs(config.toggle_modifiers) do
        local modifier = ModifierKey[name]
        if modifier == nil then
            log("unknown toggle modifier '" .. tostring(name) .. "', hotkey disabled")
            return
        end
        modifiers[#modifiers + 1] = modifier
    end
    -- keybind runs off the game thread, so the toggle is handed over to it
    local callback = function()
        ExecuteInGameThread(function()
            local ok, err = pcall(toggle)
            if not ok then
                log("toggle failed: " .. tostring(err))
            end
        end)
    end
    if #modifiers == 0 then
        RegisterKeyBind(key, callback)
    else
        RegisterKeyBind(key, modifiers, callback)
    end
    local label = table.concat(config.toggle_modifiers, "+")
    if label ~= "" then
        label = label .. "+"
    end
    log("toggle key: " .. label .. config.toggle_key)
end

registerHotkey()

-- every poll_interval_ms on the LoopAsync thread, the actual work runs on the game thread
LoopAsync(config.poll_interval_ms, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(tick)
        if not ok then
            log("tick failed: " .. tostring(err))
        end
    end)
    return false
end)

log("v" .. MOD_VERSION .. " loaded")
