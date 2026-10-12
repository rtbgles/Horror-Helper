-- Shared definitions: patient states, injuries, treatments, triage and every setting.
-- Convars are replicated so clients can show the server's values; change them in
-- server.cfg or the server console.

local PMR = ParamedicResponse

-- Where a patient is.
PMR.STATE_SCENE = 1 -- lying where they were found
PMR.STATE_BOARD = 2 -- strapped to a spine board
PMR.STATE_AMBULANCE = 3 -- loaded in an ambulance
PMR.STATE_DELIVERED = 4 -- handed over at the hospital
PMR.STATE_DEAD = 5

PMR.STATE_NAMES = {
    [PMR.STATE_SCENE] = "On scene",
    [PMR.STATE_BOARD] = "On spine board",
    [PMR.STATE_AMBULANCE] = "In ambulance",
    [PMR.STATE_DELIVERED] = "Handed over",
    [PMR.STATE_DEAD] = "Deceased",
}

-- Injuries. `drain` is stability lost per minute while untreated, `fix` the treatment that
-- deals with it (nil = only the hospital can), `moveHit` the stability lost if the patient
-- is moved onto a board while it is still untreated.
PMR.INJ_ARTERIAL = 1
PMR.INJ_LACERATION = 2
PMR.INJ_SPINAL = 3
PMR.INJ_FRACTURE = 4
PMR.INJ_AIRWAY = 5
PMR.INJ_HEAD = 6
PMR.INJ_INTERNAL = 7

-- Treatments and other things a medic can do to a patient (all timed).
PMR.ACT_ASSESS = 1
PMR.ACT_TOURNIQUET = 2
PMR.ACT_BANDAGE = 3
PMR.ACT_COLLAR = 4
PMR.ACT_SPLINT = 5
PMR.ACT_OXYGEN = 6
PMR.ACT_CPR = 7
PMR.ACT_DEFIB = 8
PMR.ACT_BOARD = 9
PMR.ACT_UNBOARD = 10

PMR.Injuries = {
    [PMR.INJ_ARTERIAL] = {
        name = "Arterial bleed",
        detail = "Bright red blood pumping from a leg wound.",
        drain = 16,
        fix = PMR.ACT_TOURNIQUET,
        weight = 3,
    },
    [PMR.INJ_LACERATION] = {
        name = "Deep laceration",
        detail = "A long cut on the forearm, bleeding steadily.",
        drain = 4,
        fix = PMR.ACT_BANDAGE,
        weight = 5,
    },
    [PMR.INJ_SPINAL] = {
        name = "Suspected spinal injury",
        detail = "Neck pain and tingling hands. Collar before you move them.",
        drain = 0,
        fix = PMR.ACT_COLLAR,
        moveHit = 30,
        moveNote = "Moved without a C-collar",
        weight = 4,
    },
    [PMR.INJ_FRACTURE] = {
        name = "Fractured leg",
        detail = "Deformed, swollen lower leg. Splint it before moving.",
        drain = 1,
        fix = PMR.ACT_SPLINT,
        moveHit = 12,
        moveNote = "Moved with an unsplinted fracture",
        weight = 4,
    },
    [PMR.INJ_AIRWAY] = {
        name = "Respiratory distress",
        detail = "Fast, shallow breathing. Oxygen saturation is dropping.",
        drain = 9,
        fix = PMR.ACT_OXYGEN,
        weight = 3,
    },
    [PMR.INJ_HEAD] = {
        name = "Head injury",
        detail = "Confused and drowsy. Needs a hospital scan, so move quickly.",
        drain = 2,
        weight = 3,
    },
    [PMR.INJ_INTERNAL] = {
        name = "Internal bleeding",
        detail = "Rigid, bruised abdomen. Only surgery fixes this. Transport fast.",
        drain = 4,
        weight = 2,
    },
}

PMR.Actions = {
    [PMR.ACT_ASSESS] = { name = "Assess", verb = "Assessing", time = 3 },
    [PMR.ACT_TOURNIQUET] = { name = "Tourniquet", verb = "Applying tourniquet", time = 4 },
    [PMR.ACT_BANDAGE] = { name = "Pressure bandage", verb = "Bandaging", time = 5 },
    [PMR.ACT_COLLAR] = { name = "C-collar", verb = "Fitting C-collar", time = 5 },
    [PMR.ACT_SPLINT] = { name = "Splint", verb = "Splinting", time = 6 },
    [PMR.ACT_OXYGEN] = { name = "Oxygen", verb = "Fitting oxygen mask", time = 3 },
    [PMR.ACT_CPR] = { name = "CPR", verb = "Chest compressions", time = 6 },
    [PMR.ACT_DEFIB] = { name = "Defibrillate", verb = "Charging defibrillator", time = 3 },
    [PMR.ACT_BOARD] = { name = "Log-roll onto board", verb = "Log-rolling onto board", time = 5, helpedTime = 2.5 },
    [PMR.ACT_UNBOARD] = { name = "Take off board", verb = "Unstrapping", time = 3 },
}

-- Order the chart shows the action buttons in.
PMR.ACTION_ORDER = {
    PMR.ACT_ASSESS, PMR.ACT_TOURNIQUET, PMR.ACT_BANDAGE, PMR.ACT_COLLAR, PMR.ACT_SPLINT,
    PMR.ACT_OXYGEN, PMR.ACT_CPR, PMR.ACT_DEFIB, PMR.ACT_BOARD, PMR.ACT_UNBOARD,
}

local NEEDS_ASSESSMENT = {
    [PMR.ACT_TOURNIQUET] = true,
    [PMR.ACT_BANDAGE] = true,
    [PMR.ACT_COLLAR] = true,
    [PMR.ACT_SPLINT] = true,
    [PMR.ACT_OXYGEN] = true,
    [PMR.ACT_CPR] = true,
    [PMR.ACT_DEFIB] = true,
}

local function hasUntreated( p, injuryType )
    for _, injury in ipairs( p.injuries ) do
        if injury.type == injuryType and not injury.treated then return true end
    end

    return false
end

-- Why `actionId` can't be done to patient `p` right now, or nil if it can.
-- `p` is a server patient or the client's synced copy (same field names).
function PMR.ActionBlocker( p, actionId )
    if p.state == PMR.STATE_DELIVERED or p.state == PMR.STATE_DEAD then return "No longer in your care" end
    if not PMR.Actions[actionId] then return "Unknown action" end

    if actionId == PMR.ACT_ASSESS then
        if p.assessed then return "Already assessed" end

        return
    end

    if NEEDS_ASSESSMENT[actionId] and not p.assessed then return "Assess the patient first" end

    if actionId == PMR.ACT_CPR or actionId == PMR.ACT_DEFIB then
        if not p.arrest then return "The patient has a pulse" end

        return
    end

    if actionId == PMR.ACT_OXYGEN then
        if p.onO2 then return "Already on oxygen" end

        return
    end

    if actionId == PMR.ACT_BOARD then
        if p.state ~= PMR.STATE_SCENE then return "Already on a board" end

        return
    end

    if actionId == PMR.ACT_UNBOARD then
        if p.state ~= PMR.STATE_BOARD then return "Not on a board" end

        return
    end

    for injuryType, info in pairs( PMR.Injuries ) do
        if info.fix == actionId then
            if hasUntreated( p, injuryType ) then return end

            return "No injury needs this"
        end
    end

    return "No injury needs this"
end

PMR.COLOR_STABLE = Color( 80, 200, 120 )
PMR.COLOR_SERIOUS = Color( 240, 180, 50 )
PMR.COLOR_CRITICAL = Color( 230, 60, 60 )
PMR.COLOR_UNKNOWN = Color( 160, 165, 175 )
PMR.COLOR_DEAD = Color( 70, 70, 75 )
PMR.COLOR_DONE = Color( 90, 160, 240 )

local CRITICAL_BELOW = 35
local SERIOUS_BELOW = 65

-- Triage label and colour for a patient.
function PMR.Triage( p )
    if p.state == PMR.STATE_DEAD then return "Deceased", PMR.COLOR_DEAD end
    if p.state == PMR.STATE_DELIVERED then return "Handed over", PMR.COLOR_DONE end
    if not p.assessed then return "Unassessed", PMR.COLOR_UNKNOWN end
    if p.arrest then return "Cardiac arrest", PMR.COLOR_CRITICAL end
    if p.stability < CRITICAL_BELOW then return "Critical", PMR.COLOR_CRITICAL end
    if p.stability < SERIOUS_BELOW then return "Serious", PMR.COLOR_SERIOUS end

    return "Stable", PMR.COLOR_STABLE
end

-- Is the ray from `start` along `dir` within `radius` of any bone of `rag`, no further than `maxDist`?
-- Returns the distance along the ray of the closest bone, or nil.
function PMR.RayNearRagdoll( start, dir, rag, maxDist, radius )
    local finish = start + dir * maxDist
    local best

    for bone = 0, rag:GetBoneCount() - 1 do
        local pos = rag:GetBonePosition( bone )
        if pos then
            local dist, _, along = util.DistanceToLine( start, finish, pos )
            if dist <= radius and along > 0 and ( not best or along < best ) then
                best = along
            end
        end
    end

    return best
end

PMR.METERS_PER_UNIT = 0.01905

--[[ Content. Stock Half-Life 2 / Garry's Mod only; missing models are skipped. ]]

PMR.Models = {
    board = "models/hunter/plates/plate1x2.mdl",
    hospital = "models/hunter/plates/plate1x1.mdl",
    fallback = "models/hunter/blocks/cube025x025x025.mdl",
}

PMR.PatientModels = {
    "models/Humans/Group01/Male_01.mdl",
    "models/Humans/Group01/Male_02.mdl",
    "models/Humans/Group01/Male_03.mdl",
    "models/Humans/Group01/Male_04.mdl",
    "models/Humans/Group01/Male_05.mdl",
    "models/Humans/Group01/Male_06.mdl",
    "models/Humans/Group01/Male_07.mdl",
    "models/Humans/Group01/Male_08.mdl",
    "models/Humans/Group01/Male_09.mdl",
    "models/Humans/Group01/Female_01.mdl",
    "models/Humans/Group01/Female_02.mdl",
    "models/Humans/Group01/Female_03.mdl",
    "models/Humans/Group01/Female_04.mdl",
    "models/Humans/Group01/Female_06.mdl",
    "models/Humans/Group01/Female_07.mdl",
}

PMR.CarModels = {
    "models/props_vehicles/car001a_hatchback.mdl",
    "models/props_vehicles/car001b_hatchback.mdl",
    "models/props_vehicles/car002a_physics.mdl",
    "models/props_vehicles/car002b_physics.mdl",
    "models/props_vehicles/car003a_physics.mdl",
    "models/props_vehicles/car003b_physics.mdl",
    "models/props_vehicles/car004a_physics.mdl",
    "models/props_vehicles/car004b_physics.mdl",
    "models/props_vehicles/car005a_physics.mdl",
    "models/props_vehicles/car005b_physics.mdl",
}

PMR.DebrisModels = {
    "models/props_vehicles/carparts_tire01a.mdl",
    "models/props_vehicles/carparts_door01a.mdl",
    "models/props_vehicles/carparts_wheel01a.mdl",
    "models/props_vehicles/carparts_muffler01a.mdl",
    "models/props_vehicles/carparts_axel01a.mdl",
    "models/props_debris/metal_panel01a.mdl",
    "models/props_debris/metal_panel02a.mdl",
}

PMR.FirstNamesMale = {
    "James", "Daniel", "Marcus", "Tom", "Luis", "Owen", "Sam", "Victor", "Eli", "Raj",
    "Connor", "Ahmed", "Pete", "Jamal", "Hugo", "Mike", "Theo", "Kenji", "Adam", "Ray",
}

PMR.FirstNamesFemale = {
    "Sarah", "Maria", "Emily", "Grace", "Priya", "Hannah", "Lucy", "Nina", "Chloe", "Ava",
    "Fatima", "Rosa", "Jess", "Mei", "Olivia", "Kate", "Zoe", "Amara", "Beth", "Ines",
}

PMR.LastNames = {
    "Walker", "Chen", "Okafor", "Novak", "Garcia", "Murphy", "Patel", "Schmidt", "Kowalski", "Reyes",
    "Brooks", "Larsen", "Haddad", "Bennett", "Ito", "Moreau", "Adeyemi", "Fischer", "Quinn", "Silva",
}

-- Clients check sounds with file.Exists before playing them, so a missing one is skipped.
PMR.Sounds = {
    dispatch = "npc/combine_soldier/vo/on1.wav",
    dispatchEnd = "npc/combine_soldier/vo/off1.wav",
    dispatchTone = "buttons/blip1.wav",
    monitorBeep = "buttons/blip1.wav",
    treated = "items/smallmedkit1.wav",
    oxygen = "items/medshot4.wav",
    collar = "items/medshot4.wav",
    compress = {
        "physics/body/body_medium_impact_soft1.wav",
        "physics/body/body_medium_impact_soft2.wav",
        "physics/body/body_medium_impact_soft3.wav",
    },
    defibCharge = "buttons/blip1.wav",
    defibShock = "ambient/energy/zap1.wav",
    rosc = "items/suitchargeok1.wav",
    load = "physics/metal/metal_box_impact_hard1.wav",
    strap = "physics/plastic/plastic_box_impact_soft1.wav",
    deliver = "buttons/button14.wav",
    death = "buttons/button10.wav",
}

--[[
    Convars. Each entry: short name, default, help, min, max.
    Access with PMR.CV.<short name> (the convar is "pmr_<short name>").
]]
PMR.CV = PMR.CV or {}
PMR.CvarList = {}

local CVAR_FLAGS = { FCVAR_ARCHIVE, FCVAR_REPLICATED }

local function addCvar( short, default, help, min, max )
    local name = "pmr_" .. short
    PMR.CV[short] = CreateConVar( name, tostring( default ), CVAR_FLAGS, help, min, max )
    table.insert( PMR.CvarList, { name = name, help = help } )
end

addCvar( "auto_dispatch", 1, "Dispatch sends calls on its own while anyone is on duty.", 0, 1 )
addCvar( "first_call", 20, "Seconds after the first medic goes on duty before the first call.", 0, 600 )
addCvar( "call_gap", 60, "Seconds between one call ending and the next one coming in.", 5, 1800 )
addCvar( "scene_min", 1500, "Crash scenes are at least this far from the hospital (or the medics, without one).", 0, 50000 )
addCvar( "scene_max", 6000, "Crash scenes are at most this far away.", 500, 100000 )
addCvar( "max_patients", 3, "Most patients at one scene.", 1, 6 )
addCvar( "difficulty", 1, "How fast patients deteriorate (1 = normal, 0.5 = relaxed, 2 = brutal).", 0.1, 5 )
addCvar( "arrest_time", 150, "Seconds a patient in cardiac arrest survives with no CPR. CPR makes it last ~5x longer.", 20, 1200 )
addCvar( "hospital_radius", 260, "How close to the hospital drop-off a spine board has to be to hand the patient over.", 50, 2000 )
addCvar( "auto_ambulance", 1, "The first vehicle a medic gets into becomes the ambulance if there isn't one yet.", 0, 1 )
addCvar( "debug", 0, "Print dispatch decisions to the server console.", 0, 1 )

if SERVER then
    util.AddNetworkString( "PMR_Patients" )
    util.AddNetworkString( "PMR_Call" )
    util.AddNetworkString( "PMR_Action" )
    util.AddNetworkString( "PMR_Open" )
    util.AddNetworkString( "PMR_Request" )
    util.AddNetworkString( "PMR_Summary" )
end

-- PMR_Open kinds (server tells a client to open a window).
PMR.OPEN_CHART = 1
PMR.OPEN_AMBULANCE = 2

-- PMR_Request kinds (client asks the server to do something).
PMR.REQ_ACTION = 1
PMR.REQ_CANCEL = 2
PMR.REQ_UNLOAD = 3

-- Patient outcomes in the call summary.
PMR.OUTCOME_SAVED = 1
PMR.OUTCOME_DIED = 2
PMR.OUTCOME_ABANDONED = 3
