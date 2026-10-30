return {
    toggle_key = "F9", -- key name from the UE4SS Key list, F8 is allready used by BreedingHelper
    toggle_modifiers = {}, -- e.g. { "CONTROL" } or { "SHIFT", "ALT" }, empty = key on its own
    show_in_build_mode = true, -- markers also show while the build menu is open, even with F9 off

    radius_meters = 50, -- how far around the player in metres
    max_markers = 300, -- most markers at once, the closest ones win
    show_trees = true,
    show_rocks = true, -- rocks and ores, from map object spawners

    -- light pillar the game uses for dropped items
    beam_effect_path = "/Game/Pal/Effect/MapObject/NS_MapObject_DroppedCharacter.NS_MapObject_DroppedCharacter",
    tree_beam_scale = { x = 1.0, y = 1.0, z = 1.0 }, -- User.Scale for tree markers, x is the beam height
    rock_beam_scale = { x = 1.0, y = 1.0, z = 1.0 }, -- same as trees, at 0.6 the beam fell apart into small particles

    foliage_alive_state = 0, -- 0 = alive, any other state (1 decaying, 2 dead) gets a marker
    spawner_match_distance_cm = 300, -- spawner with no map object this close coutns as mined
    -- spawner classes with any of these in the name are ignored (chests, eggs, item piles, dungeon rewards, junk), not case sensitve
    spawner_class_excludes = { "TreasureBox", "PalEgg", "MultiItem", "RandomIncident", "Dungeon", "Supply", "Junk" },

    poll_interval_ms = 250, -- how often the mod wakes up
    refresh_interval_ms = 2000, -- how often markers are worked out agian while shown
    scan_budget_ms = 6, -- game thread time per tick, more = quicker refresh but can hitch
    cache_margin_meters = 30, -- extra reach kept in the cache, walking this far rebuilds it
    cache_rebuild_interval_ms = 60000, -- rebuild anyway after this long, so newly loaded trees and rocks get picked up

    chat_messages = true, -- chat line when pressing the hotkey
    diagnostics = true, -- extra diag lines in UE4SS.log, on while the mod is still being tested
}
