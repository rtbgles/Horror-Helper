-- Dispatch: going on duty, calls coming in, staging crash scenes, the end-of-call report,
-- and the chat / console commands.

local PMR = ParamedicResponse

local DISPATCH_INTERVAL = 1
local ARRIVE_RANGE = 600
local END_DELAY = 3 -- after the last patient is handed over (or lost)
local SCENE_CLEANUP_DELAY = 45 -- wrecks and the dead stay a while after the call ends
local RETRY_DELAY = 30
local PATIENT_DELAY = 0.5
local PATIENT_RING_MIN = 70
local PATIENT_RING_MAX = 170
local PATIENT_TRIES = 14
local DEBRIS_RANGE = 260
local DECAL_DELAY = 3
local SPARK_EVERY = 2.5
local SMOKE_CHANCE = 0.75
local MAX_BOARDS_PER_PLAYER = 2
local RESPONSE_FAST = 90
local RESPONSE_OK = 180

PMR.NextCallAt = PMR.NextCallAt or 0
PMR.Shift = PMR.Shift or { calls = 0, saved = 0, lost = 0, score = 0 }

local callCounter = 0

--[[ Duty ]]

function PMR.SyncCall( recipients )
    local call = PMR.Call

    net.Start( "PMR_Call" )
    net.WriteBool( call ~= nil )

    if call then
        net.WriteUInt( call.id, 16 )
        net.WriteVector( call.pos )
        net.WriteString( call.title )
        net.WriteString( call.desc )
        net.WriteDouble( call.start )
        net.WriteDouble( call.arrivedAt or 0 )
    else
        net.WriteDouble( PMR.CV.auto_dispatch:GetBool() and PMR.NextCallAt or 0 )
    end

    net.Send( recipients or PMR.Medics() )
end

local CONTROLS = {
    "Paramedic kit: Left Mouse on a patient = chart & treatments. Right Mouse = ambulance patient list. R on a vehicle = make it the ambulance.",
    "Spine board: E to pick up / put down an end (two of you can carry one). Left Mouse while carrying = load into the ambulance.",
    "!duty toggles duty, !board drops a spine board in front of you.",
}

function PMR.SetDuty( ply, on )
    if ply:GetNW2Bool( "PMR_Duty" ) == on then return end

    ply:SetNW2Bool( "PMR_Duty", on )

    if on then
        if #PMR.Medics() == 1 and not PMR.Call then
            PMR.NextCallAt = math.max( PMR.NextCallAt, CurTime() + PMR.CV.first_call:GetFloat() )
        end

        if ply:Alive() then
            ply:Give( "weapon_pmr_kit" )
            ply:SelectWeapon( "weapon_pmr_kit" )
        end

        PMR.Notify( ply, "You're on duty. Stand by for calls." )
        for _, line in ipairs( CONTROLS ) do
            ply:ChatPrint( line )
        end

        PMR.SyncCall()
        PMR.SyncPatients( ply )
    else
        PMR.CancelAction( ply, true )

        if IsValid( ply.PMR_Board ) then
            ply.PMR_Board:RemoveCarrier( ply )
        end

        PMR.Notify( ply, "You're off duty." )
    end
end

hook.Add( "PlayerSpawn", "PMR_DutyLoadout", function( ply )
    if not ply:GetNW2Bool( "PMR_Duty" ) then return end

    timer.Simple( 0, function()
        if IsValid( ply ) and ply:Alive() then
            ply:Give( "weapon_pmr_kit" )
        end
    end )
end )

--[[ Staging a crash ]]

-- How far below its origin the lowest corner of `ent` would be at angles `ang`.
local function lowestPoint( ent, ang )
    local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
    local lowest = math.huge

    for _, x in ipairs( { mins.x, maxs.x } ) do
        for _, y in ipairs( { mins.y, maxs.y } ) do
            for _, z in ipairs( { mins.z, maxs.z } ) do
                local corner = Vector( x, y, z )
                corner:Rotate( ang )
                lowest = math.min( lowest, corner.z )
            end
        end
    end

    return lowest
end

local function spawnProp( scene, model, pos, ang, frozen )
    local ent = ents.Create( "prop_physics" )
    if not IsValid( ent ) then return end

    ent:SetModel( model )
    ent:SetPos( pos )
    ent:SetAngles( ang )
    ent:Spawn()
    ent:Activate()

    local phys = ent:GetPhysicsObject()
    if frozen and IsValid( phys ) then
        phys:EnableMotion( false )
    end

    table.insert( scene.ents, ent )

    return ent
end

-- A frozen wrecked car sitting on the ground at `pos`, its length along `yaw`, rolled by `roll`.
local function spawnWreck( scene, pos, yaw, roll )
    local model = PMR.PickModel( PMR.CarModels )
    if not model then return end

    local ent = spawnProp( scene, model, pos, Angle( 0, yaw, 0 ), true )
    if not ent then return end

    -- Turn it so its longest side runs along `yaw`.
    local size = ent:OBBMaxs() - ent:OBBMins()
    local ang = Angle( 0, size.x >= size.y and yaw or yaw + 90, roll or 0 )
    local ground = PMR.Ground( pos, ent ) or pos

    ent:SetAngles( ang )
    ent:SetPos( Vector( pos.x, pos.y, ground.z - lowestPoint( ent, ang ) + 1 ) )
    table.insert( scene.wrecks, ent )

    return ent
end

local function addSmoke( scene, pos )
    local smoke = ents.Create( "env_smokestack" )
    if not IsValid( smoke ) then return end

    smoke:SetPos( pos )
    smoke:SetKeyValue( "InitialState", "1" )
    smoke:SetKeyValue( "BaseSpread", "12" )
    smoke:SetKeyValue( "SpreadSpeed", "8" )
    smoke:SetKeyValue( "Speed", "45" )
    smoke:SetKeyValue( "StartSize", "18" )
    smoke:SetKeyValue( "EndSize", "70" )
    smoke:SetKeyValue( "Rate", "14" )
    smoke:SetKeyValue( "JetLength", "180" )
    smoke:SetKeyValue( "SmokeMaterial", "particle/SmokeStack.vmt" )
    smoke:SetKeyValue( "rendercolor", "70 70 70" )
    smoke:SetKeyValue( "renderamt", "170" )
    smoke:Spawn()
    smoke:Activate()
    smoke:Fire( "TurnOn" )

    table.insert( scene.ents, smoke )
end

local function scatterDebris( scene, center )
    for _ = 1, math.random( 3, 6 ) do
        local model = PMR.PickModel( PMR.DebrisModels )
        if not model then return end

        local offset = Angle( 0, math.Rand( 0, 360 ), 0 ):Forward() * math.Rand( 40, DEBRIS_RANGE )
        local ground = PMR.Ground( center + offset )

        if ground then
            spawnProp( scene, model, ground + Vector( 0, 0, 20 ), AngleRand(), false )
        end
    end
end

local function finishScene( scene, center )
    scatterDebris( scene, center )

    local wreck = scene.wrecks[1]
    if IsValid( wreck ) and math.random() < SMOKE_CHANCE then
        addSmoke( scene, wreck:WorldSpaceCenter() + Vector( 0, 0, 20 ) )
    end
end

-- Each kind of call: what dispatch says, how many patients, how bad, and how to stage it.
local VARIANTS = {
    {
        title = "Two-vehicle collision",
        patients = { 2, 3 },
        severity = 0.55,
        flavor = {
            "Two cars, head-on. Caller can hear someone screaming.",
            "T-bone at speed. One driver isn't moving.",
            "Multiple people out of their cars, one lying in the road.",
        },
        build = function( scene, center, yaw )
            local first = spawnWreck( scene, center, yaw )
            local dir = Angle( 0, yaw, 0 ):Forward()
            local tBone = math.random() < 0.5
            -- Close enough that the bodywork overlaps a little: they hit each other.
            local reach = tBone and 1.25 or 1.8
            local gap = IsValid( first ) and first:BoundingRadius() * reach or 150

            spawnWreck( scene, center + dir * gap, tBone and yaw + 90 or yaw + 180 )
        end,
    },
    {
        title = "Rollover",
        patients = { 1, 2 },
        severity = 0.75,
        flavor = {
            "Car on its roof. Occupants were thrown out.",
            "Vehicle rolled several times. Caller says there's a lot of blood.",
        },
        build = function( scene, center, yaw )
            spawnWreck( scene, center, yaw, math.random() < 0.6 and 180 or 90 )
        end,
    },
    {
        title = "Pedestrian struck",
        patients = { 1, 1 },
        severity = 0.8,
        flavor = {
            "Car versus pedestrian. Driver fled, the pedestrian is down.",
            "Someone hit while crossing. They're breathing but not responding.",
        },
        build = function( scene, center, yaw )
            spawnWreck( scene, center - Angle( 0, yaw, 0 ):Forward() * 160, yaw )
        end,
    },
    {
        title = "Single-vehicle crash",
        patients = { 1, 2 },
        severity = 0.5,
        flavor = {
            "Car left the road and hit something. Smoke coming from the engine.",
            "Driver lost control. Caller says the driver is trapped and confused.",
        },
        build = function( scene, center, yaw )
            spawnWreck( scene, center, yaw, math.Rand( -12, 12 ) )
        end,
    },
}

local function patientSpot( center, filter )
    for _ = 1, PATIENT_TRIES do
        local offset = Angle( 0, math.Rand( 0, 360 ), 0 ):Forward() * math.Rand( PATIENT_RING_MIN, PATIENT_RING_MAX )
        local ground = PMR.Ground( center + offset, filter )

        if ground then
            local tr = util.TraceHull( {
                start = ground + Vector( 0, 0, 6 ),
                endpos = ground + Vector( 0, 0, 8 ),
                mins = Vector( -16, -16, 0 ),
                maxs = Vector( 16, 16, 64 ),
                mask = MASK_SOLID,
            } )

            if not tr.Hit and not tr.StartSolid then return ground end
        end
    end

    return PMR.Ground( center ) or center
end

local function spawnPatients( call, count )
    if PMR.Call ~= call then return end

    local center = call.pos

    for i = 1, count do
        -- The first patient is the worst off.
        local severity = math.Clamp( call.variant.severity + ( i == 1 and 0.2 or math.Rand( -0.3, 0.1 ) ), 0, 1 )
        local spot = patientSpot( center, call.scene.wrecks )
        local p = PMR.CreatePatient( spot, math.Rand( 0, 360 ), severity )

        if p then
            table.insert( call.patients, p.id )

            timer.Simple( DECAL_DELAY, function()
                if IsValid( p.ragdoll ) then
                    local pos = p.ragdoll:GetPos()
                    util.Decal( "Blood", pos + Vector( 0, 0, 10 ), pos - Vector( 0, 0, 40 ), p.ragdoll )
                end
            end )
        end
    end

    call.spawned = true
    PMR.SyncPatients()
end

local function dispatchOrigin()
    local hospitals = PMR.Hospitals()
    if #hospitals > 0 then return hospitals[math.random( #hospitals )]:GetPos() end

    local sum, count = Vector( 0, 0, 0 ), 0
    for _, ply in ipairs( PMR.Medics() ) do
        if ply:Alive() then
            sum = sum + ply:GetPos()
            count = count + 1
        end
    end

    if count == 0 then return end

    return sum / count
end

local function describe( variant, count )
    local who = count == 1 and "One patient" or ( count .. " patients" )

    return who .. ". " .. variant.flavor[math.random( #variant.flavor )]
end

local function sparks( call )
    if PMR.Call ~= call then return end

    local wreck = call.scene.wrecks[math.random( math.max( 1, #call.scene.wrecks ) )]
    if not IsValid( wreck ) then return end

    local data = EffectData()
    data:SetOrigin( wreck:WorldSpaceCenter() + VectorRand() * 30 )
    data:SetNormal( Vector( 0, 0, 1 ) )
    util.Effect( "ManhackSparks", data, true, true )
end

function PMR.StartCall()
    if PMR.Call then return false, "There's already an active call." end

    local origin = dispatchOrigin()
    if not origin then return false, "Nobody is on duty." end

    local pos = PMR.FindScenePos( origin, PMR.CV.scene_min:GetFloat(), PMR.CV.scene_max:GetFloat() )
    if not pos then return false, "Couldn't find anywhere open enough for a crash. Run nav_generate on this map." end

    callCounter = callCounter + 1

    local variant = VARIANTS[math.random( #VARIANTS )]
    local count = math.Clamp( math.random( variant.patients[1], variant.patients[2] ), 1, PMR.CV.max_patients:GetInt() )
    local yaw = math.Rand( 0, 360 )
    local scene = { ents = {}, wrecks = {} }

    variant.build( scene, pos, yaw )
    finishScene( scene, pos )

    local call = {
        id = callCounter,
        pos = pos,
        title = variant.title,
        desc = describe( variant, count ),
        start = CurTime(),
        variant = variant,
        scene = scene,
        patients = {},
    }

    PMR.Call = call
    timer.Simple( PATIENT_DELAY, function()
        spawnPatients( call, count )
    end )
    timer.Create( "PMR_Sparks", SPARK_EVERY, 0, function()
        sparks( call )
    end )

    PMR.NotifyMedics( "Call #" .. call.id .. ": " .. call.title .. ". " .. call.desc .. " Location is on your HUD." )
    PMR.SyncCall()
    PMR.Debug( "Call", call.id, variant.title, "at", pos, count, "patients" )

    return true
end

--[[ Ending a call ]]

local function gradeFor( average )
    if average >= 130 then return "A" end
    if average >= 105 then return "B" end
    if average >= 80 then return "C" end
    if average >= 50 then return "D" end

    return "F"
end

local function buildSummary( call, reason )
    local rows = {}
    local total = 0
    local saved, lost = 0, 0

    for _, id in ipairs( call.patients ) do
        local p = PMR.Patients[id]

        if p then
            local notes = table.Copy( p.notes )
            local outcome, score = PMR.OUTCOME_ABANDONED, 0

            if p.state == PMR.STATE_DELIVERED then
                outcome = PMR.OUTCOME_SAVED
                saved = saved + 1
                score = p.deliveredInArrest and 40 or ( 100 + math.Round( p.stability / 2 ) )

                if p.deliveredInArrest then
                    table.insert( notes, "Handed over still in cardiac arrest" )
                end

                if not p.assessed then
                    score = score - 20
                    table.insert( notes, "Never assessed" )
                end

                score = math.max( 0, score - p.penalty )
            elseif p.state == PMR.STATE_DEAD then
                outcome = PMR.OUTCOME_DIED
                lost = lost + 1

                if p.deathReason then
                    table.insert( notes, "Died: " .. p.deathReason )
                end
            else
                table.insert( notes, "Left at the scene" )
            end

            if p.treatments > 0 then
                table.insert( notes, p.treatments .. " treatment" .. ( p.treatments == 1 and "" or "s" ) .. " given" )
            end

            total = total + score
            table.insert( rows, {
                name = p.name,
                outcome = outcome,
                score = score,
                stability = math.Round( p.stability ),
                notes = notes,
            } )
        end
    end

    local response = call.arrivedAt and ( call.arrivedAt - call.start )
    local bonus = 0
    if response and response <= RESPONSE_FAST then
        bonus = 25
    elseif response and response <= RESPONSE_OK then
        bonus = 10
    end

    total = total + bonus

    local grade = "-"
    if reason ~= "cancelled" and #rows > 0 then
        grade = gradeFor( total / #rows )
    end

    local shift = PMR.Shift
    shift.calls = shift.calls + 1
    shift.saved = shift.saved + saved
    shift.lost = shift.lost + lost
    shift.score = shift.score + total

    return {
        id = call.id,
        title = call.title,
        reason = reason,
        response = response or -1,
        duration = CurTime() - call.start,
        rows = rows,
        bonus = bonus,
        total = total,
        grade = grade,
    }
end

local function sendSummary( summary )
    net.Start( "PMR_Summary" )
    net.WriteUInt( summary.id, 16 )
    net.WriteString( summary.title )
    net.WriteString( summary.reason )
    net.WriteDouble( summary.response )
    net.WriteDouble( summary.duration )
    net.WriteUInt( #summary.rows, 4 )

    for _, row in ipairs( summary.rows ) do
        net.WriteString( row.name )
        net.WriteUInt( row.outcome, 2 )
        net.WriteInt( row.score, 16 )
        net.WriteUInt( row.stability, 7 )
        net.WriteUInt( math.min( #row.notes, 15 ), 4 )
        for i = 1, math.min( #row.notes, 15 ) do
            net.WriteString( row.notes[i] )
        end
    end

    net.WriteInt( summary.bonus, 16 )
    net.WriteInt( summary.total, 16 )
    net.WriteString( summary.grade )

    local shift = PMR.Shift
    net.WriteUInt( shift.calls, 16 )
    net.WriteUInt( shift.saved, 16 )
    net.WriteUInt( shift.lost, 16 )
    net.WriteInt( shift.score, 32 )
    net.Send( PMR.Medics() )
end

-- reason: "complete" or "cancelled". Cancelled calls are cleared away immediately.
function PMR.EndCall( reason )
    local call = PMR.Call
    if not call then return end

    timer.Remove( "PMR_Sparks" )

    local summary = buildSummary( call, reason )
    local doomed = table.Add( call.scene.ents, PMR.ClearPatients() )

    local function clearScene()
        for _, ent in ipairs( doomed ) do
            SafeRemoveEntity( ent )
        end
    end

    if reason == "cancelled" then
        clearScene()
    else
        timer.Simple( SCENE_CLEANUP_DELAY, clearScene )
    end

    PMR.Call = nil
    PMR.NextCallAt = CurTime() + PMR.CV.call_gap:GetFloat()

    sendSummary( summary )
    PMR.SyncCall()
end

--[[ The dispatcher ]]

local function callResolved( call )
    if not call.spawned then return false end

    for _, id in ipairs( call.patients ) do
        local p = PMR.Patients[id]
        if p and p.state ~= PMR.STATE_DELIVERED and p.state ~= PMR.STATE_DEAD then return false end
    end

    return true
end

timer.Create( "PMR_Dispatch", DISPATCH_INTERVAL, 0, function()
    local call = PMR.Call
    local now = CurTime()

    if not call then
        if not PMR.CV.auto_dispatch:GetBool() or #PMR.Medics() == 0 or now < PMR.NextCallAt then return end

        local ok, err = PMR.StartCall()
        if not ok then
            PMR.Debug( "Dispatch failed:", err )
            PMR.NextCallAt = now + RETRY_DELAY
            PMR.SyncCall()
        end

        return
    end

    if not call.arrivedAt then
        for _, ply in ipairs( PMR.Medics() ) do
            if ply:Alive() and ply:GetPos():Distance( call.pos ) <= ARRIVE_RANGE then
                call.arrivedAt = now
                PMR.NotifyMedics( "On scene. Response time " .. string.FormattedTime( now - call.start, "%02i:%02i" ) .. "." )
                PMR.SyncCall()
                break
            end
        end
    end

    if callResolved( call ) then
        call.endingAt = call.endingAt or now + END_DELAY

        if now >= call.endingAt then
            PMR.EndCall( "complete" )
        end
    end
end )

--[[ Commands ]]

local function spawnBoardFor( ply )
    if not PMR.IsMedic( ply ) or not ply:Alive() then
        PMR.Notify( ply, "Go on duty first (!duty)." )

        return
    end

    local owned = 0
    for _, board in ipairs( ents.FindByClass( "pmr_board" ) ) do
        if board.PMR_Owner == ply then
            owned = owned + 1
        end
    end

    if owned >= MAX_BOARDS_PER_PLAYER then
        PMR.Notify( ply, "You already have " .. MAX_BOARDS_PER_PLAYER .. " spine boards out." )

        return
    end

    local forward = Angle( 0, ply:EyeAngles().y, 0 ):Forward()
    local ground = PMR.Ground( ply:GetPos() + forward * 70, ply ) or ply:GetPos()

    local board = ents.Create( "pmr_board" )
    if not IsValid( board ) then return end

    board:SetPos( ground + Vector( 0, 0, 8 ) )
    board:SetAngles( Angle( 0, ply:EyeAngles().y, 0 ) )
    board:Spawn()
    board.PMR_Owner = ply
end

local function forceCall( ply )
    if not PMR.IsAdmin( ply ) then return end

    if PMR.Call then
        PMR.Notify( ply, "There's already an active call. End it first (!endcall)." )

        return
    end

    local ok, err = PMR.StartCall()
    if not ok then
        PMR.Notify( ply, err )
    end
end

local function cancelCall( ply )
    if not PMR.IsAdmin( ply ) then return end

    if not PMR.Call then
        PMR.Notify( ply, "There's no active call." )

        return
    end

    PMR.EndCall( "cancelled" )
    PMR.NotifyMedics( "Call cancelled." )
end

local function toggleDuty( ply )
    if not IsValid( ply ) then return end

    PMR.SetDuty( ply, not ply:GetNW2Bool( "PMR_Duty" ) )
end

local function resetShift( ply )
    if not PMR.IsAdmin( ply ) then return end

    PMR.Shift = { calls = 0, saved = 0, lost = 0, score = 0 }
    PMR.Notify( ply, "Shift stats reset." )
end

local COMMANDS = {
    duty = toggleDuty,
    board = spawnBoardFor,
    call = forceCall,
    endcall = cancelCall,
    resetshift = resetShift,
}

for name, func in pairs( COMMANDS ) do
    concommand.Add( "pmr_" .. name, function( ply )
        func( ply )
    end )
end

local HELP = {
    "Paramedic Response: !duty (go on/off duty), !board (spine board in front of you).",
    "Admins: !call (send a call now), !endcall (cancel the current call), !resetshift.",
}

hook.Add( "PlayerSay", "PMR_ChatCommands", function( ply, text )
    local command = string.match( string.lower( string.Trim( text ) ), "^[!/](%a+)$" )
    if not command then return end

    if command == "pmr" or command == "paramedic" then
        for _, line in ipairs( HELP ) do
            ply:ChatPrint( line )
        end

        return ""
    end

    local func = COMMANDS[command]
    if not func then return end

    func( ply )

    return ""
end )

hook.Add( "PlayerDisconnected", "PMR_Duty", function( ply )
    if IsValid( ply.PMR_Board ) then
        ply.PMR_Board:RemoveCarrier( ply )
    end
end )
