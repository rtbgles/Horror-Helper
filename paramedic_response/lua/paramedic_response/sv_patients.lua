-- Patients: ragdolls with injuries and vitals that get worse until someone treats them.
-- Treatments are timed actions; the medic has to stay with the patient while they run.

local PMR = ParamedicResponse

PMR.Patients = PMR.Patients or {} -- id -> patient, current call only
PMR.Working = PMR.Working or {} -- player -> the action they're doing

local nextPatientId = 0

local SIM_INTERVAL = 1
local WORK_INTERVAL = 0.1
local ACTION_RANGE = 140
local AMBULANCE_TREAT_RANGE = 260
local BOARD_SEARCH_RANGE = 220
local AIM_RANGE = 160
local AIM_RADIUS = 14
local SPAWN_GRACE = 6 -- ignore damage while a freshly spawned patient falls over
local HARM_SCALE = 0.4
local HARM_MAX = 40
local RECOVERY_PER_MIN = 1
local O2_RECOVERY_PER_MIN = 1
local AMBULANCE_DRAIN_SCALE = 0.5
local CPR_COVER = 10 -- a round of CPR keeps the arrest clock slowed for this long
local CPR_ARREST_SCALE = 0.2
local COMPRESSION_EVERY = 0.55
local COMPRESSION_SPEED = 40 -- how hard each compression pushes the chest down (units/s)
local ROSC_BASE = 0.15
local ROSC_PER_CPR = 0.12
local ROSC_MAX = 0.8
local ROSC_STABILITY = 20
local SHOCK_SPEED = 220 -- the jolt a shock gives the chest (units/s)
local BONE_MASS_ON_BOARD = 2
local BACK_CLEARANCE = 6
local ARM_OUTWARD = 0.2
local KNOCKDOWN_SPEED = 160
local HARMFUL_DAMAGE = bit.bor( DMG_BULLET, DMG_SLASH, DMG_CLUB, DMG_BLAST, DMG_BURN, DMG_VEHICLE, DMG_BUCKSHOT )

local CHEST_BONE = "ValveBiped.Bip01_Spine2"
local HEAD_BONE = "ValveBiped.Bip01_Head1"

local ARM_CHAINS = {
    { "ValveBiped.Bip01_L_UpperArm", "ValveBiped.Bip01_L_Forearm", "ValveBiped.Bip01_L_Hand" },
    { "ValveBiped.Bip01_R_UpperArm", "ValveBiped.Bip01_R_Forearm", "ValveBiped.Bip01_R_Hand" },
}

--[[ Helpers ]]

local function hasUntreated( p, injuryType )
    for _, injury in ipairs( p.injuries ) do
        if injury.type == injuryType and not injury.treated then return true end
    end

    return false
end

local function physBoneMap( rag )
    local map = {}

    for i = 0, rag:GetPhysicsObjectCount() - 1 do
        map[rag:GetBoneName( rag:TranslatePhysBoneToBone( i ) )] = i
    end

    return map
end

local function chestPhys( p )
    local index = p.bones[CHEST_BONE] or 0

    return p.ragdoll:GetPhysicsObjectNum( index )
end

function PMR.PatientPos( p )
    if IsValid( p.ambulance ) then return p.ambulance:GetPos() end
    if IsValid( p.ragdoll ) then return p.ragdoll:GetPos() end

    return vector_origin
end

function PMR.SyncSoon()
    timer.Create( "PMR_SyncSoon", 0, 1, function()
        PMR.SyncPatients()
    end )
end

--[[ Ragdoll pose ]]

-- Every physics bone's position and angle relative to the ragdoll, as it stands when spawned.
local function capturePose( rag )
    local pose = {}
    local origin, angles = rag:GetPos(), rag:GetAngles()

    for i = 0, rag:GetPhysicsObjectCount() - 1 do
        local phys = rag:GetPhysicsObjectNum( i )
        if IsValid( phys ) then
            local pos, ang = WorldToLocal( phys:GetPos(), phys:GetAngles(), origin, angles )
            pose[i] = { pos = pos, ang = ang }
        end
    end

    return pose
end

-- The rotation that turns direction `from` into direction `to`, or nil if they already match.
local function rotationBetween( from, to )
    local axis = from:Cross( to )
    if axis:LengthSqr() < 1e-6 then return end

    axis:Normalize()
    local degrees = math.deg( math.acos( math.Clamp( from:Dot( to ), -1, 1 ) ) )

    for _, sign in ipairs( { 1, -1 } ) do
        local rot = Angle( 0, 0, 0 )
        rot:RotateAroundAxis( axis, degrees * sign )

        local test = Vector( from )
        test:Rotate( rot )
        if test:Dot( to ) > 0.99 then return rot end
    end
end

-- The spawn pose has the arms out; bring them down by the patient's sides so they fit on a board.
local function straightenArms( pose, bones )
    for _, chain in ipairs( ARM_CHAINS ) do
        local upper, hand = bones[chain[1]], bones[chain[3]]

        if upper and hand and pose[upper] and pose[hand] then
            local pivot = pose[upper].pos
            local reach = pose[hand].pos - pivot
            local side = pivot.y >= 0 and 1 or -1
            local target = Vector( 0, side * ARM_OUTWARD, -1 ):GetNormalized()
            local rot = reach:LengthSqr() > 1 and rotationBetween( reach:GetNormalized(), target )

            if rot then
                for _, name in ipairs( chain ) do
                    local index = bones[name]
                    local bone = index and pose[index]
                    if bone then
                        local rel = bone.pos - pivot
                        rel:Rotate( rot )
                        local _, ang = LocalToWorld( vector_origin, bone.ang, vector_origin, rot )
                        pose[index] = { pos = pivot + rel, ang = ang }
                    end
                end
            end
        end
    end
end

--[[ Creating patients ]]

local function randomName( female )
    local firstNames = female and PMR.FirstNamesFemale or PMR.FirstNamesMale

    return firstNames[math.random( #firstNames )] .. " " .. PMR.LastNames[math.random( #PMR.LastNames )]
end

-- 1-3 different injuries, more of them the worse the crash (severity 0-1).
local function rollInjuries( severity )
    local count = math.random( 1, 1 + math.Round( severity * 2 ) )
    local weights = {}

    for injuryType, info in pairs( PMR.Injuries ) do
        weights[injuryType] = info.weight
    end

    local picked = {}

    for _ = 1, count do
        local total = 0
        local last

        for injuryType, weight in pairs( weights ) do
            total = total + weight
            last = injuryType
        end

        if not last then break end

        local roll = math.Rand( 0, total )
        local chosen = last

        for injuryType, weight in pairs( weights ) do
            roll = roll - weight
            if roll <= 0 then
                chosen = injuryType
                break
            end
        end

        weights[chosen] = nil
        table.insert( picked, { type = chosen, treated = false } )
    end

    return picked
end

-- Spawns a casualty standing at `pos` and lets them crumple. Returns the patient, or nil.
function PMR.CreatePatient( pos, yaw, severity )
    local model = PMR.PickModel( PMR.PatientModels )
    if not model then return end

    local rag = ents.Create( "prop_ragdoll" )
    if not IsValid( rag ) then return end

    rag:SetModel( model )
    rag:SetPos( pos + Vector( 0, 0, 2 ) )
    rag:SetAngles( Angle( 0, yaw, 0 ) )
    rag:Spawn()
    rag:Activate()
    rag:SetCollisionGroup( COLLISION_GROUP_WEAPON )

    local bones = physBoneMap( rag )
    local pose = capturePose( rag )
    straightenArms( pose, bones )

    nextPatientId = nextPatientId % 65535 + 1

    local female = string.find( string.lower( model ), "female", 1, true ) ~= nil
    local p = {
        id = nextPatientId,
        name = randomName( female ),
        age = math.random( 17, 86 ),
        female = female,
        ragdoll = rag,
        bones = bones,
        pose = pose,
        injuries = rollInjuries( severity ),
        stability = math.Clamp( 85 - severity * 40 + math.Rand( -8, 8 ), 25, 95 ),
        assessed = false,
        arrest = false,
        arrestClock = 0,
        cprUntil = 0,
        cprCycles = 0,
        onO2 = false,
        state = PMR.STATE_SCENE,
        notes = {},
        penalty = 0,
        treatments = 0,
        spawnedAt = CurTime(),
        vitals = {},
    }

    rag.PMR_PatientId = p.id
    PMR.Patients[p.id] = p
    PMR.UpdateVitals( p )

    -- Knock the upper body over so they end up lying in a heap, not standing.
    local push = Angle( 0, math.Rand( 0, 360 ), 0 ):Forward() * KNOCKDOWN_SPEED
    for _, name in ipairs( { CHEST_BONE, HEAD_BONE } ) do
        local phys = bones[name] and rag:GetPhysicsObjectNum( bones[name] )
        if IsValid( phys ) then
            phys:SetVelocity( push )
        end
    end

    return p
end

--[[ Spine boards ]]

-- Lays the patient flat on `board` (head towards its +long end) and straps them on with welds.
function PMR.PlaceOnBoard( p, board )
    local rag = p.ragdoll
    local up = board:GetUp()
    local long = board:GetLongDir()
    local origin = board:GetPos()
    -- The standing pose's up becomes the board's length, its front becomes the board's up.
    local frameAng = up:AngleEx( long )

    local placed = {}
    local minAlong, maxAlong, minUp = math.huge, -math.huge, math.huge

    for index, bone in pairs( p.pose ) do
        local pos, ang = LocalToWorld( bone.pos, bone.ang, origin, frameAng )
        local rel = pos - origin
        local along = rel:Dot( long )

        placed[index] = { pos = pos, ang = ang }
        minAlong = math.min( minAlong, along )
        maxAlong = math.max( maxAlong, along )
        minUp = math.min( minUp, rel:Dot( up ) )
    end

    local deckTop = board:OBBMaxs().z
    local shift = long * -( ( minAlong + maxAlong ) / 2 ) + up * ( deckTop - minUp + BACK_CLEARANCE )

    constraint.RemoveConstraints( rag, "Weld" )
    rag:SetNoDraw( false )
    rag:SetNotSolid( false )
    p.masses = p.masses or {}

    for index, spot in pairs( placed ) do
        local phys = rag:GetPhysicsObjectNum( index )
        if IsValid( phys ) then
            p.masses[index] = p.masses[index] or phys:GetMass()
            phys:EnableMotion( true )
            phys:SetMass( BONE_MASS_ON_BOARD )
            phys:SetPos( spot.pos + shift, true )
            phys:SetAngles( spot.ang )
            phys:SetVelocity( vector_origin )
        end
    end

    for index in pairs( placed ) do
        constraint.Weld( rag, board, index, 0, 0, true, false )
    end

    rag:SetCollisionGroup( COLLISION_GROUP_DEBRIS )
    p.board = board
    board:SetPatient( p.id )
end

-- Unstraps the patient. They stay where they are (and flop off if the board is tilted).
function PMR.ReleaseFromBoard( p )
    local rag = p.ragdoll

    if IsValid( rag ) then
        constraint.RemoveConstraints( rag, "Weld" )
        rag:SetCollisionGroup( COLLISION_GROUP_WEAPON )

        for index, mass in pairs( p.masses or {} ) do
            local phys = rag:GetPhysicsObjectNum( index )
            if IsValid( phys ) then
                phys:SetMass( mass )
                phys:EnableMotion( true )
                phys:Wake()
            end
        end
    end

    p.masses = nil

    if IsValid( p.board ) then
        p.board:SetPatient( 0 )
    end

    p.board = nil
end

function PMR.FindFreeBoard( pos, range )
    local best, bestDist

    for _, board in ipairs( ents.FindByClass( "pmr_board" ) ) do
        if board:GetPatient() == 0 and not board.PMR_Stowed then
            local dist = board:GetPos():Distance( pos )
            if dist <= range and ( not bestDist or dist < bestDist ) then
                best, bestDist = board, dist
            end
        end
    end

    return best
end

--[[ Simulation ]]

local function drainPerMinute( p )
    local total = 0

    for _, injury in ipairs( p.injuries ) do
        if not injury.treated then
            total = total + PMR.Injuries[injury.type].drain
        end
    end

    return total
end

function PMR.UpdateVitals( p )
    local v = p.vitals

    if p.state == PMR.STATE_DEAD or p.arrest then
        v.hr, v.sys, v.dia, v.rr, v.gcs = 0, 0, 0, 0, 3
        v.spo2 = p.arrest and math.max( 0, math.Round( 70 - p.arrestClock * 0.4 ) ) or 0

        return
    end

    local loss = 100 - p.stability
    local bleeding = hasUntreated( p, PMR.INJ_ARTERIAL ) or hasUntreated( p, PMR.INJ_LACERATION ) or hasUntreated( p, PMR.INJ_INTERNAL )
    local breathless = hasUntreated( p, PMR.INJ_AIRWAY )

    local hr = 72 + loss * 0.75 + ( bleeding and 12 or 0 ) + math.random( -2, 2 )
    local sys = 124 - loss * 0.85 - ( bleeding and 8 or 0 ) + math.random( -2, 2 )
    local spo2 = 99 - loss * 0.12 - ( breathless and 10 or 0 ) + ( p.onO2 and 4 or 0 )
    local rr = 14 + loss * 0.14 + ( breathless and 9 or 0 )

    local gcs = hasUntreated( p, PMR.INJ_HEAD ) and 12 or 15
    if p.stability < 30 then gcs = math.min( gcs, 9 ) end
    if p.stability < 15 then gcs = math.min( gcs, 6 ) end

    v.hr = math.Clamp( math.Round( hr ), 0, 255 )
    v.sys = math.Clamp( math.Round( sys ), 40, 255 )
    v.dia = math.Round( v.sys * 0.65 )
    v.spo2 = math.Clamp( math.Round( spo2 ), 50, 100 )
    v.rr = math.Clamp( math.Round( rr ), 0, 63 )
    v.gcs = gcs
end

function PMR.StartArrest( p )
    p.arrest = true
    p.arrestClock = 0
    p.cprUntil = 0
    p.cprCycles = 0
    p.stability = 0

    PMR.NotifyMedics( p.name .. " has gone into cardiac arrest! Start CPR and get the defibrillator on." )
    PMR.SyncSoon()
end

-- Stops anyone working on this patient.
local function cancelWorkOn( p )
    for ply, work in pairs( PMR.Working ) do
        if work.patient == p.id then
            PMR.CancelAction( ply )
        end
    end
end

function PMR.KillPatient( p, reason )
    if p.state == PMR.STATE_DEAD or p.state == PMR.STATE_DELIVERED then return end

    p.state = PMR.STATE_DEAD
    p.arrest = false
    p.deathReason = reason
    cancelWorkOn( p )
    PMR.UpdateVitals( p )

    if IsValid( p.ragdoll ) then
        p.ragdoll:EmitSound( PMR.Sounds.death, 65 )
    end

    PMR.NotifyMedics( p.name .. " has died" .. ( reason and ( " (" .. reason .. ")" ) or "" ) .. "." )
    PMR.SyncSoon()
end

local function simulate( p, dt )
    if p.state == PMR.STATE_DELIVERED or p.state == PMR.STATE_DEAD then return end

    if not IsValid( p.ragdoll ) then
        PMR.KillPatient( p, "body removed" )

        return
    end

    if p.arrest then
        local scale = CurTime() < p.cprUntil and CPR_ARREST_SCALE or 1
        p.arrestClock = p.arrestClock + dt * scale

        if p.arrestClock >= PMR.CV.arrest_time:GetFloat() then
            PMR.KillPatient( p )
        end

        return
    end

    local drain = drainPerMinute( p ) * PMR.CV.difficulty:GetFloat()
    if p.state == PMR.STATE_AMBULANCE then
        drain = drain * AMBULANCE_DRAIN_SCALE
    end

    local change = -drain
    if drain <= 0 then
        change = RECOVERY_PER_MIN + ( p.onO2 and O2_RECOVERY_PER_MIN or 0 )
    end

    p.stability = math.Clamp( p.stability + change * dt / 60, 0, 100 )

    if p.stability <= 0 then
        PMR.StartArrest( p )
    end
end

timer.Create( "PMR_Simulate", SIM_INTERVAL, 0, function()
    if not next( PMR.Patients ) then return end

    for _, p in pairs( PMR.Patients ) do
        simulate( p, SIM_INTERVAL )
        PMR.UpdateVitals( p )
    end

    PMR.SyncPatients()
end )

-- Anything that really hurts a patient (gunfire, being run over...) costs stability.
hook.Add( "EntityTakeDamage", "PMR_HarmPatient", function( ent, dmg )
    local p = ent.PMR_PatientId and PMR.Patients[ent.PMR_PatientId]
    if not p or p.state == PMR.STATE_DEAD or p.state == PMR.STATE_DELIVERED then return end
    if CurTime() - p.spawnedAt < SPAWN_GRACE then return end
    if bit.band( dmg:GetDamageType(), HARMFUL_DAMAGE ) == 0 then return end

    local loss = math.min( dmg:GetDamage() * HARM_SCALE, HARM_MAX )
    p.stability = math.max( 0, p.stability - loss )

    if not p.harmed then
        p.harmed = true
        p.penalty = p.penalty + 25
        table.insert( p.notes, "Patient was hurt at the scene" )
    end

    if p.stability <= 0 and not p.arrest then
        PMR.StartArrest( p )
    end
end )

--[[ Networking ]]

function PMR.SyncPatients( recipients )
    local list = {}

    for _, p in pairs( PMR.Patients ) do
        table.insert( list, p )
    end

    table.sort( list, function( a, b ) return a.id < b.id end )

    net.Start( "PMR_Patients" )
    net.WriteUInt( #list, 4 )

    for _, p in ipairs( list ) do
        local v = p.vitals

        net.WriteUInt( p.id, 16 )
        net.WriteEntity( IsValid( p.ragdoll ) and p.ragdoll or NULL )
        net.WriteString( p.name )
        net.WriteUInt( p.age, 7 )
        net.WriteBool( p.female )
        net.WriteUInt( p.state, 3 )
        net.WriteBool( p.assessed )
        net.WriteUInt( math.Round( p.stability ), 7 )
        net.WriteBool( p.arrest )
        net.WriteBool( p.onO2 )
        net.WriteBool( CurTime() < p.cprUntil )
        net.WriteUInt( math.Round( math.max( 0, PMR.CV.arrest_time:GetFloat() - p.arrestClock ) ), 11 )
        net.WriteUInt( v.hr, 8 )
        net.WriteUInt( v.sys, 8 )
        net.WriteUInt( v.dia, 8 )
        net.WriteUInt( v.spo2, 7 )
        net.WriteUInt( v.rr, 6 )
        net.WriteUInt( v.gcs, 4 )

        -- Injuries stay hidden until someone has assessed the patient.
        local shown = p.assessed and p.injuries or {}
        net.WriteUInt( #shown, 4 )
        for _, injury in ipairs( shown ) do
            net.WriteUInt( injury.type, 4 )
            net.WriteBool( injury.treated )
        end

        net.WriteEntity( IsValid( p.ambulance ) and p.ambulance or NULL )
    end

    net.Send( recipients or PMR.Medics() )
end

function PMR.OpenChart( ply, p )
    PMR.SyncPatients( ply )

    net.Start( "PMR_Open" )
    net.WriteUInt( PMR.OPEN_CHART, 3 )
    net.WriteUInt( p.id, 16 )
    net.Send( ply )
end

local function sendAction( ply, work )
    net.Start( "PMR_Action" )
    net.WriteUInt( work and work.action or 0, 4 )

    if work then
        net.WriteUInt( work.patient, 16 )
        net.WriteDouble( work.start )
        net.WriteDouble( work.finish )
    end

    net.Send( ply )
end

--[[ Aiming ]]

-- The patient the player is looking at, if any is close enough to touch.
function PMR.AimedPatient( ply )
    local start, dir = ply:EyePos(), ply:GetAimVector()
    local best, bestAlong

    for _, p in pairs( PMR.Patients ) do
        local rag = p.ragdoll

        if not p.ambulance and IsValid( rag ) and rag:GetPos():Distance( start ) < AIM_RANGE + 80 then
            local along = PMR.RayNearRagdoll( start, dir, rag, AIM_RANGE, AIM_RADIUS )
            if along and ( not bestAlong or along < bestAlong ) then
                best, bestAlong = p, along
            end
        end
    end

    return best
end

--[[ Treatments ]]

function PMR.InReach( ply, p )
    if p.ambulance then
        local amb = p.ambulance

        return IsValid( amb ) and ply:GetPos():Distance( amb:NearestPoint( ply:GetPos() ) ) <= AMBULANCE_TREAT_RANGE
    end

    return IsValid( p.ragdoll ) and ply:GetPos():Distance( p.ragdoll:GetPos() ) <= ACTION_RANGE
end

local function anotherMedicHelping( ply, p )
    for _, other in ipairs( PMR.Medics() ) do
        if other ~= ply and other:Alive() and PMR.InReach( other, p ) then return true end
    end

    return false
end

function PMR.CancelAction( ply, quiet )
    if not PMR.Working[ply] then return end

    PMR.Working[ply] = nil

    if IsValid( ply ) then
        sendAction( ply, nil )
        if not quiet then
            PMR.Notify( ply, "Interrupted. Stay with the patient (and keep the kit out) until it's done." )
        end
    end
end

function PMR.StartAction( ply, p, actionId )
    if not PMR.IsMedic( ply ) or not ply:Alive() then return end

    if not PMR.HoldingKit( ply ) then
        PMR.Notify( ply, "Take out your paramedic kit first." )

        return
    end

    local blocker = PMR.ActionBlocker( p, actionId )
    if blocker then
        PMR.Notify( ply, blocker .. "." )

        return
    end

    if not PMR.InReach( ply, p ) then
        PMR.Notify( ply, "You need to be right next to " .. p.name .. "." )

        return
    end

    for other, work in pairs( PMR.Working ) do
        if other ~= ply and work.patient == p.id and work.action == actionId then
            PMR.Notify( ply, other:Nick() .. " is already doing that." )

            return
        end
    end

    local act = PMR.Actions[actionId]
    local work = { patient = p.id, action = actionId, start = CurTime(), nextBeat = 0 }
    local duration = act.time

    if actionId == PMR.ACT_BOARD then
        work.board = PMR.FindFreeBoard( p.ragdoll:GetPos(), BOARD_SEARCH_RANGE )

        if not IsValid( work.board ) then
            PMR.Notify( ply, "Put a spine board down next to the patient first (spawn menu > Entities > Paramedic Response)." )

            return
        end

        if act.helpedTime and anotherMedicHelping( ply, p ) then
            duration = act.helpedTime
        end
    end

    if actionId == PMR.ACT_DEFIB and IsValid( p.ragdoll ) then
        p.ragdoll:EmitSound( PMR.Sounds.defibCharge, 70, 140 )
    end

    PMR.CancelAction( ply, true )
    work.finish = work.start + duration
    PMR.Working[ply] = work
    sendAction( ply, work )
end

local function treatInjury( p, injuryType )
    for _, injury in ipairs( p.injuries ) do
        if injury.type == injuryType and not injury.treated then
            injury.treated = true

            return true
        end
    end

    return false
end

local function shock( ply, p )
    local rag = p.ragdoll
    if IsValid( rag ) then
        rag:EmitSound( PMR.Sounds.defibShock, 75 )

        local phys = chestPhys( p )
        if IsValid( phys ) then
            phys:ApplyForceCenter( Vector( 0, 0, SHOCK_SPEED * phys:GetMass() ) )
        end
    end

    local chance = math.min( ROSC_BASE + ROSC_PER_CPR * p.cprCycles, ROSC_MAX )

    if math.random() < chance then
        p.arrest = false
        p.stability = ROSC_STABILITY
        p.cprCycles = 0

        if IsValid( rag ) then
            rag:EmitSound( PMR.Sounds.rosc, 70 )
        end

        PMR.NotifyMedics( "Pulse is back! " .. p.name .. " has a heartbeat again." )
    else
        p.cprCycles = math.max( 0, p.cprCycles - 1 )
        PMR.Notify( ply, "No change. Keep up the CPR and shock again (CPR improves the odds)." )
    end
end

local function moveToBoard( ply, p, board )
    if not IsValid( board ) or board:GetPatient() ~= 0 or board.PMR_Stowed or board:GetPos():Distance( p.ragdoll:GetPos() ) > BOARD_SEARCH_RANGE then
        PMR.Notify( ply, "The spine board is gone." )

        return
    end

    for _, injury in ipairs( p.injuries ) do
        local info = PMR.Injuries[injury.type]

        if info.moveHit and not injury.treated and not p.movedWith then
            p.stability = math.max( 0, p.stability - info.moveHit )
            p.penalty = p.penalty + info.moveHit
            table.insert( p.notes, info.moveNote )
            PMR.Notify( ply, info.moveNote .. "! That hurt them." )
        end
    end

    p.movedWith = true
    PMR.PlaceOnBoard( p, board )
    p.state = PMR.STATE_BOARD
    board:EmitSound( PMR.Sounds.strap, 65 )

    if p.stability <= 0 and not p.arrest then
        PMR.StartArrest( p )
    end
end

local function completeAction( ply, p, work )
    local actionId = work.action
    local rag = p.ragdoll

    if actionId == PMR.ACT_ASSESS then
        p.assessed = true
    elseif actionId == PMR.ACT_CPR then
        p.cprCycles = p.cprCycles + 1
        p.cprUntil = CurTime() + CPR_COVER
    elseif actionId == PMR.ACT_DEFIB then
        shock( ply, p )
    elseif actionId == PMR.ACT_OXYGEN then
        p.onO2 = true
        treatInjury( p, PMR.INJ_AIRWAY )
        p.treatments = p.treatments + 1
        if IsValid( rag ) then rag:EmitSound( PMR.Sounds.oxygen, 60 ) end
    elseif actionId == PMR.ACT_BOARD then
        moveToBoard( ply, p, work.board )
    elseif actionId == PMR.ACT_UNBOARD then
        PMR.ReleaseFromBoard( p )
        p.state = PMR.STATE_SCENE
    else
        for injuryType, info in pairs( PMR.Injuries ) do
            if info.fix == actionId and treatInjury( p, injuryType ) then
                p.treatments = p.treatments + 1
                break
            end
        end

        if IsValid( rag ) then rag:EmitSound( PMR.Sounds.treated, 60 ) end
    end

    PMR.UpdateVitals( p )
    PMR.SyncSoon()
end

local function stillValid( ply, work )
    local p = PMR.Patients[work.patient]
    if not p then return false end
    if not IsValid( ply ) or not ply:Alive() or not PMR.IsMedic( ply ) or not PMR.HoldingKit( ply ) then return false end
    if PMR.ActionBlocker( p, work.action ) then return false end

    return PMR.InReach( ply, p ), p
end

timer.Create( "PMR_Work", WORK_INTERVAL, 0, function()
    if not next( PMR.Working ) then return end

    local now = CurTime()

    for ply, work in pairs( PMR.Working ) do
        local ok, p = stillValid( ply, work )

        if not ok then
            PMR.CancelAction( ply, not IsValid( ply ) )
        elseif now >= work.finish then
            PMR.Working[ply] = nil
            sendAction( ply, nil )
            completeAction( ply, p, work )
        elseif work.action == PMR.ACT_CPR and now >= work.nextBeat then
            -- Chest compressions you can see and hear.
            work.nextBeat = now + COMPRESSION_EVERY
            local phys = chestPhys( p )
            if IsValid( phys ) and not p.ambulance then
                phys:ApplyForceCenter( Vector( 0, 0, -COMPRESSION_SPEED * phys:GetMass() ) )
                p.ragdoll:EmitSound( PMR.PickSound( PMR.Sounds.compress ), 55 )
            end
        end
    end
end )

--[[ Clean-up ]]

-- Forget every patient. Ragdolls still in the world are returned so the caller can remove them
-- later (the dead stay at the scene for a while).
function PMR.ClearPatients()
    local leftovers = {}

    for ply in pairs( PMR.Working ) do
        PMR.CancelAction( ply, true )
    end

    for _, p in pairs( PMR.Patients ) do
        -- Still stowed (alive, or died on the way): give the board back.
        if p.ambulance or p.stowedBoard then
            PMR.RestoreFromAmbulance( p )
        end

        PMR.ReleaseFromBoard( p )

        if IsValid( p.ragdoll ) then
            p.ragdoll.PMR_PatientId = nil
            table.insert( leftovers, p.ragdoll )
        end
    end

    PMR.Patients = {}
    PMR.SyncPatients()

    return leftovers
end

hook.Add( "PlayerDisconnected", "PMR_StopWork", function( ply )
    PMR.Working[ply] = nil
end )

hook.Add( "PlayerDeath", "PMR_StopWork", function( ply )
    PMR.CancelAction( ply, true )
end )

--[[ Requests from the chart ]]

local REQUEST_COOLDOWN = 0.15

net.Receive( "PMR_Request", function( _, ply )
    if not PMR.IsMedic( ply ) then return end
    if ( ply.PMR_NextRequest or 0 ) > CurTime() then return end

    ply.PMR_NextRequest = CurTime() + REQUEST_COOLDOWN

    local kind = net.ReadUInt( 3 )

    if kind == PMR.REQ_ACTION then
        local p = PMR.Patients[net.ReadUInt( 16 )]
        local actionId = net.ReadUInt( 4 )
        if p then
            PMR.StartAction( ply, p, actionId )
        end
    elseif kind == PMR.REQ_CANCEL then
        PMR.CancelAction( ply, true )
    elseif kind == PMR.REQ_UNLOAD then
        local amb = net.ReadEntity()
        local p = PMR.Patients[net.ReadUInt( 16 )]
        if p and IsValid( amb ) then
            PMR.UnloadFromAmbulance( ply, amb, p )
        end
    end
end )
