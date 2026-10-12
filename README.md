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
3. Stand in the **middle** of the cabin, type a name, press **Save cabin here**.
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

## How a night plays out

1. **Find each other.** Everyone wakes up scattered in the dark, far from the cabin
   (`hh_regroup`, `hh_regroup_spread`, `hh_regroup_distance`). Survivors on their own call out
   every 20-35 seconds; others hear it and see which way it came from. Bind a key to `hh_call`
   to shout yourself.
2. **Get to the cabin.** Once you're together (or after `hh_regroup_timeout`), the chosen
   cabin is marked on screen with its distance. Once everyone is inside, the defense starts.
   The marker stays up whenever you're away from it.
3. **Hold out until sunrise.** Power the fuse boxes, board up doors and windows, survive the attacks.

## The killer: when it shows up

VJ NPCs on their own find the nearest player and run straight at them. Here the killer
**doesn't exist on the map** until the director decides it should. It shows itself by
`hh_first_contact` seconds, then again and again, with the gap shrinking from
`hh_contact_gap_max` to `hh_contact_gap_min` as dread rises. Each time it is one of:

- **Stalking:** it stands out in the dark watching one survivor who is away from the cabin.
  Stare too long or walk up to it and it turns and walks off, or (more often as the night wears on)
  comes for you. Shoot it and it definitely comes for you.
- **Chase:** it hunts a survivor from the far side of the cabin. The chase ends when they get
  near the cabin (`hh_safe_margin`), it loses everyone, or `hh_pursuit_max` runs out.
- **Prowling:** everyone is in the cabin, so it circles outside and tries a door or window once
  or twice before leaving. Step outside near it at your own risk.
- **Siege:** the real attack. Rolled each night: after a random amount of setup progress
  (`hh_siege_progress` up to fully set up) plus a random delay, never before `hh_siege_earliest`,
  always by `hh_siege_latest`. It bashes through barricades (`hh_bash_damage`) and comes in.
  Waves last `hh_wave_min`-`hh_wave_max` seconds or until you deal `hh_retreat_damage`, then a
  quiet stretch (`hh_respite_*`). By default it can't die (`hh_killer_can_die 0`).

## Dread: it gets worse

Dread climbs from 0 to 1 over the night (`hh_dread_speed`), with how set up the cabin is,
once the sieges start, and a little every time the killer appears. As it rises the fog
closes in, colour drains, the screen edges darken, late at night you hear your own pulse,
and the psychological scares come more often (`hh_psych_rate`, more when you're alone) and get nastier:

| From dread | Scare |
|---|---|
| any | footsteps behind you; a glimpse of it standing far off (gone when you look properly) |
| 0.30 | breathing right behind your head; the cabin lamps stutter |
| 0.35 | your flashlight stutters; knocking on the boards from outside |
| 0.55 | a teammate's voice calling from where no teammate is |
| 0.70 | the power dies for a while |
| 0.75 | a glimpse of it standing inside the cabin with you |

Turn on `hh_debug 1` to see the director's decisions in the server console.

## Settings are saved per map

Whatever you set (in the menu, with `hh_set`, or in the server console) is saved for the
map you're on, a second after you change it, in `data/horror_helper/settings/<map>.json`.
Next time that map loads, its settings come back: killer, night length, director tuning,
everything. Cabin layouts were already saved per map.

- **Use these settings as the default for other maps** (`hh_settings_save_defaults`):
  maps with no saved settings of their own start from these.
- **Forget this map's settings** (`hh_settings_forget_map`): back to the defaults.
- `hh_settings_status` says where the current settings came from.

Saved settings override `server.cfg` on maps that have them.

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
