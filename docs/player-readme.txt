SentryHeat 1.1.0 - Payday 3 sentry heat display (UE4SS Lua mod)
=================================================================

Shows how hot each sentry is, plus your sentries' Machine War damage bonus
and kill count.

  - Heat number per sentry: green < 60%, yellow 60-80%, red 80%+ (the game's
    smoke starts at 80%), pulsing from 90%, OVH when overheated.
  - Your sentries: heat, Machine War damage bonus (blue at the +50% cap),
    kills since placement.
  - Teammates' sentries: heat only by default, faded.
  - Choose what is shown for your sentries and for teammates' (heat, dmg,
    kills, or off) in settings.ini.
  - Off-screen warning: a red arrow at the screen edge points to any of your
    sentries that is out of view and running hot.
  - Hidden in the pause menu and other cursor menus.

Two display styles (Style in settings.ini or Will's Mod Menu; default world):
  world - data floats over each of your sentries; a one-line readout from
          far away, a HEAT / DMG / KILLS panel up close.
  panel - each of your sentries gets a number tag (1, 2, 3); the data for
          every sentry is in a small table on the right of your HUD.

Keys: none by default. ToggleKey (markers on/off) and StyleKey (switch style)
can be set in settings.ini.

REQUIREMENTS
  UE4SS for Payday 3: https://www.nexusmods.com/payday3/mods/266

INSTALL
  1. Install UE4SS for Payday 3 (see its page).
  2. Copy the SentryHeat folder into
     PAYDAY3\PAYDAY3\Binaries\Win64\ue4ss\Mods\
     so you end up with ...\ue4ss\Mods\SentryHeat\Scripts\main.lua
     (the included enabled.txt turns the mod on; no need to edit mods.txt).
  3. Start the game.

SETTINGS
  Edit SentryHeat\settings.ini (style, panel position, teammates, colour
  thresholds, colours, keys, marker height...). Restart the game after editing.
  With Will's Mod Menu (optional), change them in game; they apply at once.

NOTES
  - Client-side only. Works whether you host or join. Other players don't
    need the mod.
  - UE4SS itself makes the game flag your session as modded.
  - On a client the game doesn't send a sentry's max heat capacity, so heat
    is measured against the sentry's health when the mod first saw it. This is
    exact unless you joined after the sentry was placed.
  - Kill counts are tracked by the mod from the moment it sees the sentry
    and reset when the sentry is picked up.
  - Lightweight: about 0.05 ms per frame, 0.15-0.2 ms with sentries out. The
    mod only looks for sentries when one is placed (a single short lookup),
    and does nothing on maps where nobody brought one.
  - After changing mods, restart the game rather than using UE4SS's
    hot-reload (Ctrl+R), which can crash Lua mods.

UNINSTALL
  Delete the ue4ss\Mods\SentryHeat folder.

CHANGES
  1.1.0  Works with Will's Mod Menu (settings in game, applied live).
         Keys are off by default.
