Are you tired of not knowing if you build over tree or rocks or iron or other resources? I was, so I made this simple mod to show markers, either press F9 or try to build something, it will show markers for every type of resource. This way you can avoid building over resources and blocking their respawn, and my goldfish memory is too bad to remember where is what.


REQUIREMENTS
------------

UE4SS for Palworld ("Experimental" build) is necessary and will not work otherwise.


INSTALL
-------

Copy the whole "ExhaustedResourceMarkers" folder into your UE4SS "Mods" folder. Depending on you installed UE4SS:

  a) UE4SS installed through Palworld's steam workshop:
      <Palworld>\Mods\NativeMods\UE4SS\Mods\

  b) UE4SS installed manually:
      <Palworld>\Pal\Binaries\Win64\ue4ss\Mods\

You should end up with something like this:
  ...\Mods\ExhaustedResourceMarkers\enabled.txt
  ...\Mods\ExhaustedResourceMarkers\Scripts\main.lua
  ...\Mods\ExhaustedResourceMarkers\Scripts\config.lua

The empty enabled.txt file switches the mod on, it should stay empty.

Do NOT install it alongside the steam workshop version or you will end up with mod running twice, which is bad.


HOW TO USE
----------

  F9 will toggle it on and off.
 Markers will appear automatically while the build menu is open.

Markers cover 50 m around you and refresh every 2 seconds.

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

Scripts\config.lua holds configs, edit it with notepad or preferable notepad++, game will need restart thought.

  toggle_key          hotkey (default "F9")
  show_in_build_mode  true/false - show markers automatically in the build menu
  radius_meters        how far around you markers are shown (default 50)
  max_markers          maximum number of marked spots (default 300)
  show_trees          true/false
  show_rocks          true/false
  resource_types      colour per resource; color = { red, green, blue } from 0 to 1
  foliage_types        same for trees; stack / stack_step_cm set the tree column height
  chat_messages        true/false - chat confirmation when pressing the hotkey
  diagnostics          true/false - extra details in UE4SS.log for bug reports

If there is mistake in config.lua, it will fall back to its defaults and will write log files to UE4SS.log instead of not working, kind of a neat feature.

NOTES
-----

- It is Purely visual. it never changes respawning points or your save and is safe to remove mid game.
- Made for single-player and hosting your own world as client. Not tested if it works in multiplayer yet, I will check eventualy and try to fix if not. Do NOT install it on server, it is client side as all UI mods are.

UNINSTALL
---------

Delete the ExhaustedResourceMarkers folder from your UE4SS Mods folder,
or delete just enabled.txt to switch it off while keeping your settings.


BUG REPORTS
-----------

Set diagnostics to true in config.lua, reproduce the problem, then send the lines
starting with [ExhaustedResourceMarkers] from UE4SS.log to me, this will help immensely with debugging it and fixing stuff.

Full source on for version control or if I go missing or get kidnapped by aliens and mod stops working: https://github.com/DanScallion/ExhaustedResourceMarkers
If your mod requires my mod you can safely make patches or updates for it without asking me.
