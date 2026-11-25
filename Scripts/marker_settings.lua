return function(config, limits, log, applySetting, onHotkey)
    local source = debug.getinfo(1, "S").source
    local scripts = source:match("^@(.*)[/\\][^/\\]+$")
    if not scripts then return false, false end

    local ok, registered, managesHotkey = pcall(function()
        local library, loadError = loadfile(scripts .. "/../../BetterModManager/Scripts/modconfig.lua")
        if not library then
            if loadError and loadError:find("cannot open", 1, true) then return false, false end
            error(loadError, 0)
        end

        local options, byKey = {}, {}
        local function add(option)
            options[#options + 1] = option
            if option.key then byKey[option.key] = option end
        end
        local function toggle(key, label)
            add({ key = key, type = "toggle", label = label, default = config[key] })
        end
        local function slider(key, label, step, range, default)
            range = range or limits[key]
            add({ key = key, type = "slider", label = label, min = range[1], max = range[2],
                step = step or 1, default = default or config[key] })
        end

        local nativeHotkey = #config.toggle_modifiers == 0
        if nativeHotkey then
            add({ key = "toggle_key", type = "hotkey", label = "Toggle Markers", onPress = onHotkey,
                default = (Key or {})[config.toggle_key] and config.toggle_key or "" })
        else
            add({ type = "note", label = "The marker hotkey uses the modifiers set in config.lua." })
        end
        toggle("show_in_build_mode", "Show in Build Mode")
        toggle("show_trees", "Show Trees and Foliage")
        toggle("show_rocks", "Show Rocks, Ores, and Other Resources")
        toggle("chat_messages", "Show Chat Messages")
        slider("radius_meters", "Marker Radius (m)")
        slider("max_markers", "Maximum Markers")

        add({ type = "header", label = "Performance" })
        slider("poll_interval_ms", "Update Interval (ms)", 50)
        slider("refresh_interval_ms", "Refresh Interval (ms)", 250)
        slider("rock_refresh_interval_ms", "Rock and Ore Scan Interval (ms)", 250)
        slider("scan_budget_ms", "Scan Budget per Tick (ms)")
        slider("cache_margin_meters", "Cache Margin (m)")
        slider("cache_rebuild_interval_ms", "Cache Rebuild Interval (ms)", 1000)
        slider("spawner_match_distance_cm", "Spawner Match Distance (cm)")
        slider("foliage_alive_state", "Living Foliage State", 1, { 0, 255 })

        add({ type = "header", label = "Marker Effect" })
        slider("tree_beam_height_cm", "Tree and Wood Beam Height (cm)", 10)
        slider("resource_beam_height_cm", "Other Beam Height (cm)", 10)
        add({ type = "header", label = "Fallback Niagara Effect" })
        add({ key = "beam_effect_path", type = "text", label = "Effect Asset Path",
            maxLength = 256, default = config.beam_effect_path })
        for _, axis in ipairs({ "X", "Y", "Z" }) do
            slider("beam_scale." .. axis:lower(), "Beam Scale " .. axis, 0.05, { 0.05, 50 }, config.beam_scale[axis])
        end
        add({ key = "color_parameter_names", type = "text", label = "Color Parameters",
            description = "Separate effect parameter names with commas.", maxLength = 256,
            default = table.concat(config.color_parameter_names, ", ") })
        toggle("diagnostics", "Diagnostics")

        local settings = library().register({
            id = "ExhaustedResourceMarkers",
            name = "Exhausted Resource Markers",
            description = "Changes apply during the current session.",
            options = options,
            onChange = function(key, value)
                if byKey[key] then applySetting(key, value) end
            end,
        })
        for _, option in ipairs(options) do
            if option.key then applySetting(option.key, settings.values[option.key]) end
        end
        return true, nativeHotkey
    end)
    if ok then return registered, managesHotkey end
    log("Better Mod Manager registration failed: " .. tostring(registered))
    return false, false
end
