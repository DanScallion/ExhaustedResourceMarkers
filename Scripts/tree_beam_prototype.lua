local ASSET_FOLDER = "/Game/ExhaustedResourceMarkers"
local ASSET = ASSET_FOLDER .. "/SM_ExhaustedTreeBeam.SM_ExhaustedTreeBeam"
local SPAWN_CLASS = "/Script/Engine.StaticMeshActor"
local MOVABLE = 2
local MESH_HEIGHT_CM = 450
local EMISSIVE_STRENGTH = 2.5
local POOL_LIMIT = 24

return function(valid, log, config)
    local actorClass, mesh
    local tried, showed = false, false
    local owned = setmetatable({}, { __mode = "k" })
    local free = {}
    local colorParameter
    local prototype = {}

    local function loadMesh()
        local current = LoadAsset(ASSET)
        if valid(current) then return current end

        local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        if not valid(helpers) then return nil end
        local registry = helpers:GetAssetRegistry()
        if not valid(registry) then return nil end
        registry:ScanPathsSynchronous({ ASSET_FOLDER }, true, false)
        return LoadAsset(ASSET)
    end

    function prototype.ready()
        if tried then return valid(actorClass) and valid(mesh) end
        tried = true
        local ok, loadedClass, loadedMesh = pcall(function()
            return StaticFindObject(SPAWN_CLASS), loadMesh()
        end)
        if not ok or not valid(loadedClass) or not valid(loadedMesh) then
            log("tree beam prototype asset unavailable; using the original marker effect")
            return false
        end
        actorClass, mesh = loadedClass, loadedMesh
        log("tree beam prototype loaded the custom mesh")
        return true
    end

    function prototype.owns(actor)
        return actor ~= nil and owned[actor] ~= nil
    end

    function prototype.destroy(actor)
        if not prototype.owns(actor) then return end
        owned[actor] = nil
        if not valid(actor) then return end
        pcall(function() actor:SetActorHiddenInGame(true) end)
        local ok, err = pcall(function() actor:K2_DestroyActor() end)
        if not ok then log("could not remove the prototype tree beam: " .. tostring(err)) end
    end

    function prototype.release(actor)
        if #free < POOL_LIMIT and valid(actor) then
            local hidden = pcall(function() actor:SetActorHiddenInGame(true) end)
            if hidden then
                free[#free + 1] = actor
                return
            end
        end
        prototype.destroy(actor)
    end

    local function configure(actor, resource)
        local state = owned[actor]
        local label = resource.label
        local height = (label == "tree" or label == "wood")
            and config.tree_beam_height_cm or config.resource_beam_height_cm
        if state.height ~= height then
            actor:SetActorScale3D({ X = 1, Y = 1, Z = height / MESH_HEIGHT_CM })
            state.height = height
        end
        local color = resource.color
        if state.color ~= color then
            if colorParameter == nil then colorParameter = FName("BeamColor") end
            state.material:SetVectorParameterValue(colorParameter, {
                R = color.R * EMISSIVE_STRENGTH,
                G = color.G * EMISSIVE_STRENGTH,
                B = color.B * EMISSIVE_STRENGTH,
                A = 1,
            })
            state.color = color
        end
    end

    function prototype.spawn(world, vector, rotation, resource)
        if not prototype.ready() or not valid(world) then return nil end
        while #free > 0 do
            local actor = table.remove(free)
            local state = owned[actor]
            if valid(actor) and state and valid(state.component) and valid(state.material) then
                local reused = pcall(function()
                    state.component:K2_SetWorldLocation(vector, false, {}, true)
                    configure(actor, resource)
                    actor:SetActorHiddenInGame(false)
                end)
                if reused then return actor end
            end
            prototype.destroy(actor)
        end

        local actor
        local ok, err = pcall(function()
            actor = world:SpawnActor(actorClass, vector, rotation)
            assert(valid(actor), "could not spawn the beam actor")
            owned[actor] = {}
            actor:SetActorEnableCollision(false)
            actor:SetMobility(MOVABLE)
            local component = actor.StaticMeshComponent
            assert(valid(component), "beam mesh component is unavailable")
            component:SetCastShadow(false)
            assert(component:SetStaticMesh(mesh), "could not assign the beam mesh")
            local material = component:CreateDynamicMaterialInstance(0, component:GetMaterial(0), FName("None"))
            assert(valid(material), "could not create the colored beam material")
            owned[actor] = { component = component, material = material }
            configure(actor, resource)
        end)
        if not ok then
            prototype.destroy(actor)
            mesh = nil
            log("custom beam failed; using the fallback effect: " .. tostring(err))
            return nil
        end
        if not showed then
            showed = true
            log("custom beam placed its first marker: " .. resource.label)
        end
        return actor
    end

    function prototype.reset()
        actorClass, mesh = nil, nil
        tried, showed = false, false
        owned = setmetatable({}, { __mode = "k" })
        free = {}
    end

    return prototype
end
