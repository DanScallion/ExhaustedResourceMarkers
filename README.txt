Exhausted Resource Markers - 1.2.0

Are you tired of not knowing if you build over tree or rocks or iron or other resources? I was, so I made this simple mod to show markers, either press F9 or try to build something, it will show markers for every type of resource. This way you can avoid building over resources and blocking their respawn, and my goldfish memory is too bad to remember where is what.


CHANGELOG
---------

Since 1.0.0

- Added Better Mod Manager support. Change the hotkey, marker visibility,
  scan settings, and beam effects in-game without restarting.
- Added Dek Mod Config Menu support. Settings apply after you click Save.
  If both menus are installed, Better Mod Manager controls the settings and
  Dek tells you which menu to use. The mod still works with config.lua alone.
- Added separate install steps for Steam Workshop and Nexus, including Nexus
  installs that use Steam Workshop's UE4SS.
- Added a single colored beam per resource. Trees and logs use taller beams,
  and both heights can be changed in settings.
- Reduced repeated rock and ore scans and reused hidden beam actors as markers
  move in and out of range.
- Fixed missing quartz markers near other ore rocks or dropped items.
- Improved marker updates and cleanup of old beam effects. The mod now
  clears cached scans when you switch worlds or respawn.
- Fixed the error safeguard so ten failed scans in a row switch the mod off
  and log the reason. A successful scan resets the failure count.


REQUIREMENTS
------------

UE4SS for Palworld ("Experimental" build) is necessary and will not work otherwise.


INSTALL
-------

STEAM WORKSHOP

Subscribe to Exhausted Resource Markers and its required items in Steam Workshop.
Steam downloads them automatically. In Palworld, open Options > Mod Management
to enable the mod and its dependencies, then restart when prompted.

NEXUS ZIP ASSET INSTALLATION

Copy the ZIP's Pal folder into your Palworld game directory. The beam PAK
should be at:
  <Palworld>\Pal\Content\Paks\~mods\ExhaustedResourceMarkersTreeBeam_P.pak

Then install the ExhaustedResourceMarkers Lua folder using the section below
that matches your UE4SS install.

NEXUS ZIP WITH UE4SS FROM STEAM WORKSHOP

  1. Subscribe to UE4SS Experimental for Palworld in Steam Workshop. Enable
     it in Options > Mod Management and restart when prompted.
  2. Open the ZIP and locate the ExhaustedResourceMarkers folder.
  3. Copy the whole ExhaustedResourceMarkers folder into:
       <Palworld>\Mods\NativeMods\UE4SS\Mods\

NEXUS ZIP WITH MANUALLY INSTALLED UE4SS

Open the ZIP and locate the ExhaustedResourceMarkers folder.
Copy the whole ExhaustedResourceMarkers folder into your active UE4SS Mods folder,
usually:
  <Palworld>\Pal\Binaries\Win64\ue4ss\Mods\

You should end up with something like this:

  ...\Mods\ExhaustedResourceMarkers\enabled.txt
  ...\Mods\ExhaustedResourceMarkers\Scripts\main.lua
  ...\Mods\ExhaustedResourceMarkers\Scripts\config.lua

Leave enabled.txt empty. That file switches the mod on. If you switch this mod
from Workshop to Nexus, unsubscribe from its Workshop copy first. Keep your
Workshop UE4SS subscription if you use it to run Nexus mods.


HOW TO USE
----------

  F9 will toggle it on and off.
 Markers will appear automatically while the build menu is open.

By default, markers cover 50 m around you. The refresh interval is 2 seconds.
Rock and ore scans can be reused for up to 5 seconds while you stay nearby.

Colours:
  Green             trees
  Yellow             sulfur
  Orange           ore
  Red                 iron
  Dark grey        coal
  Pale cyan       quartz
  Blue                Paldium
  Purple             crystal
  Violet              night stone
  Magenta         sky island and World Tree ore
  Grey                stone
  Brown             logs
  Off-white          bones
  Pink                 berries, fruit, mushrooms, lotus, poppies

SETTINGS
--------

Better Mod Manager is optional. In Better Mod Manager, open Supported >
Exhausted Resource Markers to change the hotkey, marker visibility, scan
settings, and effects during the current session.

Dek Mod Config Menu is also optional. Its settings page is created in the
game's Pal\Content\Paks\LogicMods folder when Dek is installed. If Better
Mod Manager is active, use it to change settings. Otherwise, click Save in
Dek to apply changes within about a second. Without either menu, edit
Scripts\config.lua and restart Palworld. The hotkey is configured in that
file or in Better Mod Manager.
Hotkey modifiers and per-resource matching rules and colors are configured
in that file. A modifier-based hotkey keeps using the binding from the file.

  toggle_key          hotkey (default "F9")
  show_in_build_mode  true/false - show markers automatically in the build menu
  radius_meters        how far around you markers are shown (default 50)
  max_markers          maximum number of marked spots (default 300)
  show_trees          true/false
  show_rocks          true/false
  resource_types      colour per resource; color = { red, green, blue } from 0 to 1
  foliage_types         matching and colors for trees
  tree_beam_height_cm   beam height for trees and logs (default 450)
  resource_beam_height_cm beam height for other resources (default 200)
  rock_refresh_interval_ms rock and ore scan cache lifetime (default 5000)
  height, stack, stack_step_cm apply to the fallback Niagara effect
  chat_messages        true/false - chat confirmation when pressing the hotkey
  diagnostics          true/false - extra details in UE4SS.log for bug reports

If there is mistake in config.lua, it will fall back to its defaults and will write log files to UE4SS.log instead of not working, kind of a neat feature.

NOTES
-----

- It is Purely visual. it never changes respawning points or your save and is safe to remove mid game.
- Made for single-player and hosting your own world as client. Not tested if it works in multiplayer yet, I will check eventualy and try to fix if not. Do NOT install it on server, it is client side as all UI mods are.

UNINSTALL
---------

For Workshop, unsubscribe from Exhausted Resource Markers. For Nexus, delete
the ExhaustedResourceMarkers folder from your UE4SS Mods folder and remove
ExhaustedResourceMarkersTreeBeam_P.pak from Pal\Content\Paks\~mods.


BUG REPORTS
-----------

Enable Diagnostics in Better Mod Manager or set diagnostics to true in config.lua.
Reproduce the problem, then send the lines
starting with [ExhaustedResourceMarkers] from UE4SS.log to me, this will help immensely with debugging it and fixing stuff.

Full source on for version control or if I go missing or get kidnapped by aliens and mod stops working: https://github.com/DanScallion/ExhaustedResourceMarkers
If your mod requires my mod you can safely make patches or updates for it without asking me.
