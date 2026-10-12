-- Every setting lives here. Convars are replicated so the admin menu can show the server's
-- values; change them with the Horror Helper menu (Utilities tab), `hh_set <name> <value>`,
-- or server.cfg.

local HH = HorrorHelper

HH.PHASE_IDLE = 0
HH.PHASE_LOBBY = 1
HH.PHASE_INTRO = 2
HH.PHASE_NIGHT = 3
HH.PHASE_RESULTS = 4

HH.OUTCOME_NONE = 0
HH.OUTCOME_SURVIVED = 1
HH.OUTCOME_KILLED = 2
HH.OUTCOME_ABORTED = 3

-- One-off moments the server tells clients about (net "HH_Cue").
HH.CUE_SIEGE = 1 -- the killer is coming for the cabin: a far scream, the lamps stutter
HH.CUE_ENCOUNTER = 2 -- the hunted survivor has just seen it
HH.CUE_BLINK = 3 -- a blink of black to cover the killer vanishing in plain sight
HH.CUE_PHANTOM = 4 -- footsteps behind you that belong to no one
HH.CUE_POWER = 5 -- the fuse boxes are full, the lamps come on
HH.CUE_SUNRISE = 6
HH.CUE_RETREAT = 7 -- the survivors drove it off
HH.CUE_STAGE = 8 -- the objective changed (the client words it from HH_Stage)
HH.CUE_NOTICE = 9 -- you've just noticed it watching you
HH.CUE_BREATH = 10 -- breathing right behind your head
HH.CUE_FLICKER = 11 -- the cabin lamps stutter
HH.CUE_POWERCUT = 12 -- the lights die for a while

-- What the survivors are doing right now, inside the night.
HH.STAGE_NONE = 0
HH.STAGE_REGROUP = 1 -- scattered in the dark: find each other
HH.STAGE_TO_CABIN = 2 -- together: the cabin is marked, get there
HH.STAGE_PREPARE = 3 -- at the cabin: power it, board it, survive

-- Length of the opening film, in seconds. The client film is timed against this.
HH.INTRO_LENGTH = 14

-- How long the result screen stays up before everyone is back in Sandbox.
HH.RESULTS_LENGTH = 10

-- Entities an admin places to build a cabin layout (saved per map).
HH.SETUP_CLASSES = {
    hh_fusebox = true,
    hh_barricade = true,
    hh_barricade_window = true,
    hh_lamp = true,
}

-- Stock Half-Life 2 / Garry's Mod content, so nothing has to be downloaded.
-- A model that is missing on the server falls back to HH.Models.fallback.
HH.Models = {
    fuse = "models/items/battery.mdl",
    planks = "models/props_debris/wood_board04a.mdl",
    board = "models/props_debris/wood_board04a.mdl",
    fusebox = "models/props_lab/powerbox01a.mdl",
    lamp = "models/props_interiors/furniture_lamp01a.mdl",
    fallback = "models/hunter/blocks/cube025x025x025.mdl",
}

-- Sounds are checked with file.Exists on the client before they play, so a missing one is skipped.
HH.Sounds = {
    pickup = "items/itempickup.wav",
    fuseIn = "buttons/lever7.wav",
    powerOn = "buttons/button1.wav",
    hammer = {
        "physics/wood/wood_box_impact_hard1.wav",
        "physics/wood/wood_box_impact_hard2.wav",
        "physics/wood/wood_box_impact_hard3.wav",
    },
    bash = {
        "physics/wood/wood_plank_impact_hard1.wav",
        "physics/wood/wood_plank_impact_hard2.wav",
        "physics/wood/wood_plank_impact_hard3.wav",
    },
    boardBreak = {
        "physics/wood/wood_plank_break1.wav",
        "physics/wood/wood_crate_break1.wav",
        "physics/wood/wood_crate_break3.wav",
    },
    thunder = {
        "ambient/atmosphere/thunder1.wav",
        "ambient/atmosphere/thunder2.wav",
        "ambient/atmosphere/thunder3.wav",
    },
    heartbeat = "player/heartbeat1.wav",
    breath = {
        "npc/stalker/breathing3.wav",
        "player/breathe1.wav",
    },
    powerCut = {
        "ambient/energy/powerdown2.wav",
        "buttons/button19.wav",
    },
    -- Survivors calling out to find each other (and, late at night, voices that aren't them).
    calloutMale = {
        "vo/npc/male01/overhere01.wav",
        "vo/npc/male01/hi01.wav",
        "vo/npc/male01/hi02.wav",
    },
    calloutFemale = {
        "vo/npc/female01/overhere01.wav",
        "vo/npc/female01/hi01.wav",
        "vo/npc/female01/hi02.wav",
    },
    stinger = "npc/stalker/go_alert2a.wav",
    distantScream = {
        "ambient/creatures/town_scared_scream1.wav",
        "ambient/voices/f_scream1.wav",
        "npc/fast_zombie/fz_alert_far1.wav",
    },
    footsteps = {
        "player/footsteps/wood1.wav",
        "player/footsteps/wood2.wav",
        "player/footsteps/wood3.wav",
        "player/footsteps/wood4.wav",
        "player/footsteps/dirt1.wav",
        "player/footsteps/dirt2.wav",
        "player/footsteps/dirt3.wav",
        "player/footsteps/dirt4.wav",
    },
    ambience = {
        "ambient/wind/wind_snippet1.wav",
        "ambient/wind/wind_snippet2.wav",
        "ambient/wind/wind_snippet3.wav",
        "ambient/materials/wood_creak1.wav",
        "ambient/materials/wood_creak2.wav",
        "ambient/materials/wood_creak3.wav",
        "ambient/creatures/owl1.wav",
        "ambient/levels/forest/dist_birds1.wav",
    },
}

--[[
    Convars. Each entry: short name, default, help, kind, min, max, menu category.
    Access with HH.CV.<short name> (the convar is "hh_<short name>").
]]
HH.CV = HH.CV or {}
HH.CvarList = {}

local CVAR_FLAGS = { FCVAR_ARCHIVE, FCVAR_REPLICATED }

local function addCvar( short, default, help, kind, min, max, category )
    local name = "hh_" .. short
    HH.CV[short] = CreateConVar( name, tostring( default ), CVAR_FLAGS, help, min, max )
    table.insert( HH.CvarList, {
        short = short,
        name = name,
        help = help,
        kind = kind,
        min = min,
        max = max,
        category = category,
    } )
end

-- The killer
addCvar( "killer_class", "npc_zombie", "NPC class the killer spawns as. Paste a VJ Base class here (e.g. npc_vj_...).", "string", nil, nil, "Killer" )
addCvar( "killer_name", "", "Name shown on the title card. Empty uses the NPC's spawn menu name.", "string", nil, nil, "Killer" )
addCvar( "killer_can_die", 0, "If 1, the killer can be killed (it still comes back next wave). If 0, damage only drives it off.", "bool", 0, 1, "Killer" )
addCvar( "retreat_damage", 250, "Damage the survivors must deal in one attack before the killer retreats into the dark.", "int", 25, 5000, "Killer" )
addCvar( "bash_damage", 35, "Damage the killer does to a barricade per hit.", "int", 1, 500, "Killer" )

-- The night
addCvar( "night_minutes", 15, "How long the night lasts, in minutes, before sunrise.", "float", 2, 90, "Night" )
addCvar( "intro", 1, "Play the opening film of the killer before the night starts.", "bool", 0, 1, "Night" )
addCvar( "lobby_countdown", 10, "Seconds of countdown once everyone in the waiting room is ready.", "int", 3, 60, "Night" )
addCvar( "loadout", "weapon_crowbar", "Comma-separated weapons survivors start with. Physgun and toolgun are removed for the night.", "string", nil, nil, "Night" )
addCvar( "regroup", 1, "Survivors start scattered in the dark and must find each other before the cabin is revealed.", "bool", 0, 1, "Night" )
addCvar( "regroup_spread", 1400, "How far apart scattered survivors start.", "float", 300, 8000, "Night" )
addCvar( "regroup_distance", 3200, "How far beyond the cabin's edge the survivors start.", "float", 500, 15000, "Night" )
addCvar( "regroup_timeout", 240, "Seconds before the cabin is revealed even if the survivors haven't found each other.", "float", 30, 1200, "Night" )
addCvar( "restrict", 1, "Block spawning, toolgun, physgun, noclip and the spawn menu during a round.", "bool", 0, 1, "Night" )
addCvar( "admin_bypass", 0, "Superadmins ignore the restrictions above.", "bool", 0, 1, "Night" )

-- Scavenging
addCvar( "fuses_per_box", 3, "Fuses each fuse box needs before the cabin has power.", "int", 1, 10, "Scavenging" )
addCvar( "spare_planks", 4, "Planks scattered on top of what it takes to board everything once.", "int", 0, 40, "Scavenging" )
addCvar( "plank_carry", 4, "How many planks one survivor can carry at a time.", "int", 1, 20, "Scavenging" )
addCvar( "board_health", 120, "Health of each board nailed over a door or window.", "int", 10, 2000, "Scavenging" )
addCvar( "scavenge_min", 900, "Items never spawn closer than this to the cabin (forces you to go out).", "float", 100, 10000, "Scavenging" )
addCvar( "scavenge_max", 6000, "Items never spawn further than this from the cabin.", "float", 500, 40000, "Scavenging" )

-- The director
addCvar( "grace", 45, "Seconds at the start of the night where the killer never appears.", "float", 0, 900, "Director" )
addCvar( "siege_progress", 0.5, "Setup progress (fuses + boards, 0-1) before the first attack on the cabin can happen.", "float", 0, 1, "Director" )
addCvar( "siege_earliest", 0.2, "No attack on the cabin before this fraction of the night has passed.", "float", 0, 1, "Director" )
addCvar( "siege_latest", 0.65, "The first attack on the cabin happens by this fraction of the night, ready or not.", "float", 0, 1, "Director" )
addCvar( "wave_min", 90, "Shortest attack on the cabin, in seconds, before the killer melts back into the dark.", "float", 15, 900, "Director" )
addCvar( "wave_max", 200, "Longest attack on the cabin, in seconds.", "float", 15, 900, "Director" )
addCvar( "respite_min", 45, "Shortest quiet stretch between attacks, in seconds.", "float", 5, 900, "Director" )
addCvar( "respite_max", 120, "Longest quiet stretch between attacks, in seconds.", "float", 5, 900, "Director" )
addCvar( "first_contact", 150, "The killer shows itself (watching, prowling or chasing) by this many seconds into the night.", "float", 30, 900, "Director" )
addCvar( "contact_gap_max", 150, "Gap between the killer's appearances early in the night, in seconds.", "float", 20, 900, "Director" )
addCvar( "contact_gap_min", 45, "Gap between the killer's appearances once dread is at its peak, in seconds.", "float", 10, 900, "Director" )
addCvar( "encounter_chance", 0.15, "Extra chance per minute, on top of the paced appearances, that a lone scavenger runs into the killer.", "float", 0, 5, "Director" )
addCvar( "encounter_max", 6, "Most chases per night (paced or chance).", "int", 0, 30, "Director" )
addCvar( "pursuit_max", 90, "A chase gives up after this many seconds.", "float", 10, 600, "Director" )
addCvar( "safe_margin", 300, "A chase ends once the hunted survivor is this close to the cabin's edge.", "float", 0, 3000, "Director" )
addCvar( "dread_speed", 1, "How fast dread builds over the night (1 = reaches its peak around dawn).", "float", 0.2, 4, "Director" )
addCvar( "psych_rate", 1, "How often psychological scares happen. They also get more frequent and nastier as dread rises.", "float", 0, 5, "Director" )
addCvar( "sightings", 1, "Glimpses of the killer that only one survivor sees (late at night, even inside the cabin).", "bool", 0, 1, "Director" )
addCvar( "phantoms", 1, "Fake footsteps, breathing, knocking, voices and failing lights.", "bool", 0, 1, "Director" )

-- Atmosphere
addCvar( "darkness", 1, "Darken the map's lighting for the night.", "bool", 0, 1, "Atmosphere" )
addCvar( "darkness_style", "b", "Light style for the night: a (pitch black) to m (normal).", "string", nil, nil, "Atmosphere" )
addCvar( "fog", 1, "Night fog.", "bool", 0, 1, "Atmosphere" )
addCvar( "fog_end", 1800, "Distance at which the fog is fully opaque.", "float", 300, 20000, "Atmosphere" )
addCvar( "proxvoice", 1, "Proximity voice chat during a round (the dead hear everyone, the living don't hear the dead).", "bool", 0, 1, "Atmosphere" )
addCvar( "voice_range", 900, "Proximity voice range.", "float", 100, 10000, "Atmosphere" )
addCvar( "chase_music", "", "Sound file (relative to sound/) looped while the killer is close and in sight. Empty = heartbeat only.", "string", nil, nil, "Atmosphere" )

addCvar( "debug", 0, "Print director decisions to the server console.", "bool", 0, 1, "Debug" )

HH.CvarByName = {}
for _, info in ipairs( HH.CvarList ) do
    HH.CvarByName[info.name] = info
end
