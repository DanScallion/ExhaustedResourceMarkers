local UEHelpers = require("UEHelpers")
local config = require("config")

local MOD_VERSION = "0.1.0"
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

-- true if any needle is in the text, case sensitive
local function containsAny(text, needles)
    for _, needle in ipairs(needles) do
        if text:find(needle, 1, true) ~= nil then
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
    if not ok or not isValid(component) then
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

-- hidden and kept for reuse, destroyed once the pool is full
local function releaseMarker(component)
    if not isValid(component) then
        return
    end
    pcall(function() component:SetVisibility(false, false) end)
    pcall(function() component:Deactivate() end)
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

-- called between items, yields the coroutine once the deadline has passed so the scan carries on next tick, weight = how much work an item is
local function makeStepper(deadline, report)
    local work = 0
    return function(weight)
        work = work + (weight or 1)
        if work < 64 then
            return
        end
        work = 0
        if now() < deadline then
            return
        end
        report.slices = report.slices + 1
        deadline = coroutine.yield()
    end
end

-- numbers for the diag lines
local function newReport()
    return {
        slices = 1,
        cacheRebuilt = false,
        cacheMs = 0,
        foliageTotal = 0,
        foliageWithoutLocation = 0,
        foliageNearby = 0,
        spawnerTotal = 0,
        spawnersNearby = 0,
        mapObjectsNearby = 0,
        states = {},
        spawnerClasses = {},
        neighbourClasses = {},
        trees = 0,
        rocks = 0,
        wallMs = 0,
    }
end

-- all foliage in memory, only the ones within reach are kept
local function collectFoliage(origin, step, report)
    local nearby = {}
    if not config.show_trees then
        return nearby
    end
    local ok, all = pcall(FindAllOf, "PalFoliageInstance")
    if not ok or all == nil then
        return nearby
    end
    report.foliageTotal = #all
    for _, instance in ipairs(all) do
        step(1)
        local location = nil
        if isValid(instance) then
            location = foliageLocation(instance)
        end
        if location == nil then
            report.foliageWithoutLocation = report.foliageWithoutLocation + 1
        elseif distanceSq2D(location, origin) <= REACH_SQ then
            nearby[#nearby + 1] = { object = instance, location = location }
        end
    end
    report.foliageNearby = #nearby
    return nearby
end

-- spawners within reach that don't match spawner_class_excludes
local function collectSpawners(origin, step, report)
    local nearby = {}
    if not config.show_rocks then
        return nearby
    end
    local ok, all = pcall(FindAllOf, "PalMapObjectSpawnerBase")
    if not ok or all == nil then
        return nearby
    end
    report.spawnerTotal = #all
    for _, spawner in ipairs(all) do
        step(1)
        if isValid(spawner) then
            local name = className(spawner)
            local location = actorLocation(spawner)
            if not containsAny(name, config.spawner_class_excludes)
                and location ~= nil
                and distanceSq2D(location, origin) <= REACH_SQ then
                nearby[#nearby + 1] = { object = spawner, location = location, className = name }
            end
        end
    end
    report.spawnersNearby = #nearby
    return nearby
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

-- foliage and spawners near the player, reused until the player walks out of the cache margin
local function rebuildCache(origin, step, report)
    local started = now()
    local foliage = collectFoliage(origin, step, report)
    local spawners = collectSpawners(origin, step, report)
    cache = { origin = origin, builtAt = now(), foliage = foliage, spawners = spawners }
    report.cacheRebuilt = true
    report.cacheMs = now() - started
end

-- grid cell as a string key, cells are MATCH_CM wide
local function cellKey(x, y)
    return math.floor(x / MATCH_CM) .. ":" .. math.floor(y / MATCH_CM)
end

-- map objects within reach in a grid of MATCH_CM cells, so each spawner only checks its neighbours
local function buildOccupancy(origin, step, report)
    local grid = {}
    local ok, all = pcall(FindAllOf, "PalMapObject")
    if not ok or all == nil then
        return grid
    end
    for _, object in ipairs(all) do
        step(1)
        if isValid(object) then
            local location = actorLocation(object)
            if location ~= nil and distanceSq2D(location, origin) <= REACH_SQ then
                local key = cellKey(location.x, location.y)
                local bucket = grid[key] or {}
                bucket[#bucket + 1] = { object = object, location = location }
                grid[key] = bucket
                report.mapObjectsNearby = report.mapObjectsNearby + 1
            end
        end
    end
    return grid
end

-- closest map object in the 3x3 cells around location, spawners are skiped so a spawner never counts as its own rock
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
                    if distanceSq < bestSq and not className(entry.object):find("Spawner", 1, true) then
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

-- anything not alive within the radius gets a tree marker
local function evaluateTrees(origin, step, report, markers)
    for _, entry in ipairs(cache.foliage) do
        step(1)
        local state = readFoliageState(entry.object)
        if state ~= nil then
            countInto(report.states, state)
            local distanceSq = distanceSq2D(entry.location, origin)
            if state ~= config.foliage_alive_state and distanceSq <= RADIUS_SQ then
                markers[#markers + 1] = { kind = "tree", location = entry.location, distanceSq = distanceSq }
            end
        end
    end
end

-- spawner with no map object within spawner_match_distance_cm counts as mined
local function evaluateRocks(origin, step, report, markers)
    if #cache.spawners == 0 then
        return
    end
    local grid = buildOccupancy(origin, step, report)
    for _, entry in ipairs(cache.spawners) do
        step(2)
        local distanceSq = distanceSq2D(entry.location, origin)
        if isValid(entry.object) and distanceSq <= RADIUS_SQ then
            local occupant, occupantSq = nearestOccupant(grid, entry.location)
            local exhausted = occupant == nil or occupantSq > MATCH_SQ
            local classStats = report.spawnerClasses[entry.className] or { total = 0, exhausted = 0 }
            classStats.total = classStats.total + 1
            report.spawnerClasses[entry.className] = classStats
            if exhausted then
                classStats.exhausted = classStats.exhausted + 1
                markers[#markers + 1] = { kind = "rock", location = entry.location, distanceSq = distanceSq }
            else
                countInto(report.neighbourClasses, className(occupant.object))
            end
        end
    end
end

-- closest max_markers markers, counted as trees or rocks for the chat line
local function selectMarkers(markers, report)
    table.sort(markers, function(a, b) return a.distanceSq < b.distanceSq end)
    local selected = {}
    for index = 1, math.min(#markers, config.max_markers) do
        local marker = markers[index]
        selected[#selected + 1] = marker
        if marker.kind == "tree" then
            report.trees = report.trees + 1
        else
            report.rocks = report.rocks + 1
        end
    end
    return selected
end

-- markers that went away get hidden, new ones are spawned or taken from the pool
local function applyMarkers(world, markers, step)
    local wanted = {}
    for _, marker in ipairs(markers) do
        wanted[markerKey(marker.location)] = marker
    end
    for key, component in pairs(activeMarkers) do
        if wanted[key] == nil or not isValid(component) then
            releaseMarker(component)
            activeMarkers[key] = nil
        end
    end
    for key, marker in pairs(wanted) do
        if activeMarkers[key] == nil then
            step(16)
            local component = acquireMarker(world, marker)
            if component ~= nil then
                activeMarkers[key] = component
            end
        end
    end
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
        .. " (map objects within reach " .. report.mapObjectsNearby .. ")")
    log(string.format("diag refresh took %.1f ms wall over %d slice(s); markers: %d trees, %d rocks",
        report.wallMs, report.slices, report.trees, report.rocks))
    logProperties()
end

-- one full refresh, runs inside a coroutine so it can pause betwen ticks
local function runRefresh(deadline, world, origin)
    local report = newReport()
    local step = makeStepper(deadline, report)
    local started = now()
    if cacheIsStale(origin) then
        rebuildCache(origin, step, report)
    end
    local markers = {}
    evaluateTrees(origin, step, report, markers)
    evaluateRocks(origin, step, report, markers)
    applyMarkers(world, selectMarkers(markers, report), step)
    report.wallMs = now() - started
    logReport(report)
    if not announceNextResult then
        return
    end
    announceNextResult = false
    say(string.format("Exhausted within %d m: %d trees, %d rocks", config.radius_meters, report.trees, report.rocks))
end

-- gives the coroutine a new deadline, job is cleared once it finishes or throws
local function resumeJob()
    local ok, err = coroutine.resume(job, now() + config.scan_budget_ms)
    if not ok then
        log("refresh failed: " .. tostring(err))
        job = nil
        lastRefreshAt = now()
        return
    end
    if coroutine.status(job) ~= "dead" then
        return
    end
    job = nil
    lastRefreshAt = now()
end

-- refresh as a coroutine, the first slice runs right away
local function startJob(pawn)
    local origin = actorLocation(pawn)
    if origin == nil then
        return
    end
    local ok, world = pcall(function() return pawn:GetWorld() end)
    if not ok or not isValid(world) then
        return
    end
    job = coroutine.create(function(deadline) runRefresh(deadline, world, origin) end)
    resumeJob()
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
        resumeJob()
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
