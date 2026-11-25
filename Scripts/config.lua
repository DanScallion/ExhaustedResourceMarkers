return {
    toggle_key = "F9", -- key name from the UE4SS Key list, F8 is allready used by BreedingHelper
    toggle_modifiers = {}, -- e.g. { "CONTROL" } or { "SHIFT", "ALT" }, empty = key on its own
    show_in_build_mode = true, -- markers also show while the build menu is open, even with F9 off

    radius_meters = 50, -- how far around the player, 5 to 300
    max_markers = 300, -- most spots markd at once, closest win, a stack of tree lights counts as one
    show_trees = true,
    show_rocks = true, -- rocks, ores and the other spawner resources below

    -- treasure light, the old blue beam (DroppedCharacter) has no colour parameter so it can't be tinted
    beam_effect_path = "/Game/Pal/Effect/Treasure/NS_MapObject_TreasureLight.NS_MapObject_TreasureLight",
    beam_scale = { x = 1.0, y = 1.0, z = 1.0 }, -- fallback Niagara scale
    tree_beam_height_cm = 450, -- custom mesh height for trees and wood
    resource_beam_height_cm = 200, -- custom mesh height for other resources
    color_parameter_names = { "User.Color" }, -- user parameter that gets the colour, found wiht the diag effect lines
    -- only read when diagnostics = true, logs which user parameters each effect has
    diagnostic_effect_paths = {
        "/Game/Pal/Effect/MapObject/NS_MapObject_DroppedCharacter.NS_MapObject_DroppedCharacter",
        "/Game/Pal/Effect/Treasure/NS_MapObject_TreasureLight.NS_MapObject_TreasureLight",
        "/Game/Pal/Effect/Common/Glow/NS_ItemPickupTower_Glow.NS_ItemPickupTower_Glow",
    },

    -- trees and other foliage, first match on the FoliageTypeId wins, "" matches everyting
    -- Color applies to either renderer. Height, stack, and stack_step_cm apply to the Niagara fallback.
    foliage_types = {
        { label = "mushroom", match = { "Mushroom" }, color = { 1.0, 0.35, 0.7 } },
        { label = "tree", match = { "" }, color = { 0.1, 1.0, 0.1 }, height = 5.0, stack = 5, stack_step_cm = 80 },
    },

    -- rocks, ores and other respawning spawners, first match on the spawner class name wins (not case sensitive) so the more specific names go frist
    -- ONLY LISTED SPAWNERS GET MARKERS, CHESTS ARE "Treasure_" NOT "TreasureBox" SO THE OLD EXCLUDE LIST MARKED THEM
    resource_types = {
        { label = "sulfur", match = { "Sulfur" }, color = { 1.0, 0.9, 0.0 } },
        { label = "coal", match = { "RockCoal" }, color = { 0.3, 0.3, 0.35 } },
        { label = "ore", match = { "RockCopper" }, color = { 1.0, 0.45, 0.1 } },
        { label = "iron", match = { "RockIron" }, color = { 0.85, 0.2, 0.1 } },
        { label = "quartz", match = { "RockQuartz" }, color = { 0.75, 1.0, 1.0 } },
        { label = "paldium", match = { "PalCrystal" }, color = { 0.1, 0.45, 1.0 } }, -- has to stay above crystal, PalCrystal contains Crystal
        { label = "crystal", match = { "Crystal" }, color = { 0.7, 0.2, 1.0 } },
        { label = "nightstone", match = { "NightStone" }, color = { 0.45, 0.1, 0.8 } },
        { label = "rare ore", match = { "SkyIslandOre", "WorldTreeOre" }, color = { 1.0, 0.2, 0.85 } },
        { label = "stone", match = { "RockStone", "SmallStone", "DamagableRock", "DestroyableWall_Rock" }, color = { 0.6, 0.6, 0.6 } },
        { label = "wood", match = { "TreeYakushima", "DamagableWood" }, color = { 0.1, 1.0, 0.1 }, height = 5.0, stack = 5, stack_step_cm = 80 },
        { label = "log", match = { "_log" }, color = { 0.55, 0.3, 0.1 } }, -- underscore so only the log spawner matches
        { label = "bone", match = { "_bone" }, color = { 1.0, 0.95, 0.8 } },
        { label = "plant", match = { "RedBerry", "AffectionFruit", "SkillFruits", "Lotus", "Poppy", "Mushroom" }, color = { 1.0, 0.35, 0.7 } },
    },

    foliage_alive_state = 0, -- 0 = alive, any other state (1 decaying, 2 dead) gets a marker
    spawner_match_distance_cm = 300, -- spawner with no map object this close coutns as mined

    poll_interval_ms = 250, -- how often the mod wakes up
    refresh_interval_ms = 2000, -- how often markers are worked out agian while shown
    rock_refresh_interval_ms = 5000, -- reuse the occupancy grid while it covers the current area
    scan_budget_ms = 6, -- game thread time per tick, more = quicker refresh but can hitch
    cache_margin_meters = 30, -- extra reach kept in the cache, walking this far rebuilds it
    cache_rebuild_interval_ms = 60000, -- rebuild anyway after this long, so newly loaded trees and rocks get picked up

    chat_messages = true, -- chat line when pressing the hotkey
    diagnostics = false, -- extra diag lines in UE4SS.log, for bug reprots
}
