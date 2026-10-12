# Paramedic Response

A co-op ambulance shift on top of Sandbox. Dispatch sends you and your partner to crash scenes
staged with wrecked cars and ragdoll casualties. Assess them, stop the bleeding, collar and splint,
log-roll them onto a spine board, carry it between the two of you, load the ambulance and get them
to the hospital before they crash.

Drop this folder (`paramedic_response`) into `garrysmod/addons/`. It uses only stock HL2/GMod
content. It is a separate addon from Horror Helper; the two don't depend on each other.

## Quick start

1. **Place a hospital** (admin, once per map): spawn menu > Entities > Paramedic Response >
   **Hospital Drop-off**. Put it outside a building with room to park. It's saved for the map
   automatically, including when you move it with the physgun or delete it.
2. **Get an ambulance:** any vehicle works (HL2 jeep, a simfphys/LVS ambulance from the workshop...).
   The first vehicle someone on duty gets into becomes the ambulance, or look at a vehicle and press
   **R** with the paramedic kit.
3. Both of you type **`!duty`**. You get the paramedic kit, and the first call comes in after
   `pmr_first_call` seconds.
4. Grab a spine board (`!board`, or spawn menu > Entities > Paramedic Response > **Spine Board**)
   and drive to the red marker.

Run `nav_generate` on the map if it has no navmesh. Crash scenes go on open navmesh areas
(outdoors if it can find one). Without a navmesh they fall back to rough traces that only work
well on open maps.

## On scene

**Paramedic kit**

| Button | What it does |
|---|---|
| Left Mouse on a patient | Opens their chart (monitor, findings, treatments) |
| Left Mouse while carrying a patient on a board | Loads them into the ambulance (stand right next to it) |
| Right Mouse | The ambulance's patient list: open a chart or **Unload** |
| R on a vehicle | Mark / unmark it as the ambulance |

**Treatments** take a few seconds and you have to stay next to the patient with the kit out.
Each medic can do one thing at a time, so two of you get through a patient twice as fast.

| Treatment | For |
|---|---|
| Assess | Always first: reveals injuries, connects the monitor |
| Tourniquet | Arterial bleed (fast killer) |
| Pressure bandage | Deep laceration |
| C-collar | Suspected spinal injury. Move them without it and they get much worse |
| Splint | Fractured leg. Same deal, smaller penalty |
| Oxygen | Respiratory distress (helps anyone recover a bit faster) |
| CPR | Cardiac arrest: slows the clock and raises the odds of a shock working |
| Defibrillate | Cardiac arrest: chance to get a pulse back, better after CPR |
| Log-roll onto board | Needs a free spine board next to them. Twice as fast with two medics |

Head injuries and internal bleeding can't be fixed on scene. They slowly get worse until the
hospital takes over, so scoop and run. Untreated injuries drain the patient's stability; at zero
they go into cardiac arrest, and if the arrest clock runs out they die. Patients deteriorate at
half speed in the ambulance.

**Spine board:** press **E** on it to pick up the near end (E again to put it down). If your
partner grabs the other end you carry it between you. Carry it to the ambulance and press
Left Mouse to load. At the hospital, open the ambulance (Right Mouse), **Unload**, and carry the
board into the red circle to hand the patient over.

If no hospital is placed on the map, loading a patient into the ambulance counts as delivering them.

## Scoring

When every patient is handed over or dead, you get a report: each patient's outcome, what went
wrong (moved without a collar, never assessed, hurt at the scene...), the response time and a grade.
Delivered patients score more the more stable they arrive. Arriving within 90 seconds gives a bonus.
Shift totals carry across calls (`!resetshift` clears them).

## Commands

- `!duty` / `pmr_duty`: go on or off duty.
- `!board` / `pmr_board`: drop a spine board in front of you (2 per person).
- Admins: `!call` / `pmr_call` sends a call now, `!endcall` / `pmr_endcall` cancels the current
  one, `!resetshift` / `pmr_resetshift`.
- `!pmr`: help in chat.

## Settings (server convars)

| Convar | Default | |
|---|---|---|
| `pmr_auto_dispatch` | 1 | Calls come in on their own while anyone is on duty |
| `pmr_first_call` | 20 | Seconds before the first call |
| `pmr_call_gap` | 60 | Seconds between calls |
| `pmr_scene_min` / `pmr_scene_max` | 1500 / 6000 | How far from the hospital (or the medics) scenes are |
| `pmr_max_patients` | 3 | Most patients at one scene |
| `pmr_difficulty` | 1 | How fast patients deteriorate (0.5 relaxed, 2 brutal) |
| `pmr_arrest_time` | 150 | Seconds a patient in arrest lasts without CPR |
| `pmr_hospital_radius` | 260 | Size of the hospital drop-off circle |
| `pmr_auto_ambulance` | 1 | First vehicle a medic enters becomes the ambulance |
| `pmr_debug` | 0 | Print dispatch decisions to the console |

## Notes

- Wrecks and the dead stay at the scene for 45 seconds after a call, then they're cleared.
- Hospitals are saved in `data/paramedic_response/<map>.json`.
- Shooting or running over a patient hurts them (and your score).
