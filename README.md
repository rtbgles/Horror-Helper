# Horror Helper: Until Sunrise

A home-defense slasher round that runs **on top of Sandbox**. You don't change gamemode or map:
an admin opens a waiting room, everyone readies up, a short film introduces the killer
(any NPC class, built for VJ Base), and then the night starts. Survivors hole up in a cabin,
go out into the dark to scavenge **fuses** (to power the lights) and **planks** (to board up
doors and windows), and have to survive until **sunrise**. When the round ends, everyone is
back in normal Sandbox.

Drop this folder into `garrysmod/addons/` on the server. It uses only stock HL2/GMod content.

## Setting up a cabin (once per map)

1. Spawn menu > **Utilities > Horror Helper > Cabin Setup** (admins).
2. Spawn the pieces and place them with the physgun:
   - **Fuse Box**: survivors fill it with fuses. All boxes full = power.
   - **Door Barricade** / **Window Barricade**: an orange box shows the area the boards cover.
     Stand door ones on the floor of a doorway; put window ones over windows.
   - **Cabin Lamp**: lights up when the power is on.
3. Stand in the **middle** of the cabin (survivors start here), type a name, press **Save cabin here**.
   Radius 0 = worked out from the pieces. Save several cabins on one map and players vote between them.

Run `nav_generate` on the map if it has no navmesh. Items and the killer are placed using it;
without one, placement falls back to rough traces that only suit open maps.

## Running a night

- **Round & Killer** page: paste the killer's NPC class (or double-click it in the list),
  press Enter, then **Test** to check it spawns. Then **Open the waiting room**.
- The waiting room appears for everyone: vote for a hideout, press **Ready**. When everyone is
  ready a countdown starts (an admin can **Start now**). `!lobby` in chat reopens it.
- Commands: `hh_lobby`, `hh_start`, `hh_stop`, `hh_set <cvar> <value>`, `hh_killer_test`,
  `hh_cabin_save <name> [radius]`, `hh_cabin_edit <name>`, `hh_cabin_delete <name>`,
  `hh_cabin_list`, `hh_cabin_clear`.

## How the director keeps it unpredictable

VJ NPCs on their own find the nearest player and run straight at them. Here the killer
**doesn't exist on the map** until the director decides it should:

- **Scavenging (early night):** no killer. Survivors far from the cabin may get a **chance
  encounter**: the killer appears out of sight on the far side from the cabin and gives chase.
  The chase ends when the hunted survivor gets near the cabin (`hh_safe_margin`), the killer loses
  everyone, or it runs too long (`hh_pursuit_max`). Then it vanishes as soon as nobody is looking.
- **Siege:** when it first attacks the cabin is rolled each night: after a random amount of
  setup progress (between `hh_siege_progress` and fully set up) plus a random delay, never before
  `hh_siege_earliest` and always by `hh_siege_latest` (fractions of the night). It walks in from
  the dark, bashes barricades (`hh_bash_damage`), and comes in through anything left open.
- **Waves:** each attack lasts `hh_wave_min`-`hh_wave_max` seconds, or until the survivors deal
  `hh_retreat_damage`. Then a quiet stretch (`hh_respite_*`) to repair and scavenge, and it
  comes again. By default it can't die (`hh_killer_can_die 0`).
- **Glimpses and phantoms:** one survivor at a time may see it standing far off in the trees
  (gone when they look properly), or hear footsteps right behind them.
- If it gets stuck somewhere it can't path from during a siege, it is simply at the boards
  the next time nobody is watching.

Turn on `hh_debug 1` to see the director's decisions in the server console.

## Atmosphere

Darkened map lighting (`hh_darkness`, `hh_darkness_style`), fog (`hh_fog`, `hh_fog_end`),
a dark sky and cold colour grade, a heartbeat that quickens as the killer gets close,
optional chase music (`hh_chase_music`, a path under `sound/` you provide), proximity voice
chat (`hh_proxvoice`, `hh_voice_range`; the dead hear everyone, the living can't hear the dead),
and Sandbox spawning, toolgun, physgun, noclip and spawn menu blocked during a round (`hh_restrict`).
Survivors start with `hh_loadout` (default: crowbar).

All settings are on the menu pages, with what each one does.

## Notes

- A cabin is saved with the **map's** layout, in `data/horror_helper/<map>.json`.
- Starting a round removes any loose setup pieces you placed by hand, so save first.
- Pressing E on a door barricade also opens or closes the map's door behind it.
