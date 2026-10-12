-- Getting patients to hospital: ambulances, loading and unloading spine boards, the hospital
-- drop-off (saved per map) and handing patients over. Also what the paramedic kit's buttons do.

local PMR = ParamedicResponse

local LOAD_RANGE = 170 -- how close a carried board has to be to the ambulance's body
local UNLOAD_RANGE = 280
local UNLOAD_OFFSET = 60
local UNLOAD_HEIGHT = 30
local AIM_AMBULANCE_RANGE = 400
local NEAR_AMBULANCE_RANGE = 220
local HANDOVER_TIME = 1.5
local DELIVERY_INTERVAL = 0.25
local DATA_DIR = "paramedic_response"

PMR.Ambulances = PMR.Ambulances or {} -- ent -> true

--[[ Hiding things "inside" the ambulance ]]

local function stow( ent )
    ent:SetNoDraw( true )
    ent:SetNotSolid( true )

    for i = 0, ent:GetPhysicsObjectCount() - 1 do
        local phys = ent:GetPhysicsObjectNum( i )
        if IsValid( phys ) then
            phys:EnableMotion( false )
        end
    end
end

local function unstow( ent )
    ent:SetNoDraw( false )
    ent:SetNotSolid( false )

    for i = 0, ent:GetPhysicsObjectCount() - 1 do
        local phys = ent:GetPhysicsObjectNum( i )
        if IsValid( phys ) then
            phys:EnableMotion( true )
            phys:Wake()
        end
    end
end

--[[ Ambulances ]]

local function ambulanceCandidate( ent )
    if not IsValid( ent ) or ent:IsWorld() or ent:IsPlayer() or ent:IsNPC() or ent:IsRagdoll() then return false end

    return not string.StartsWith( ent:GetClass(), "pmr_" )
end

local function updateLoad( amb )
    amb:SetNW2Int( "PMR_Load", #amb.PMR_Load )
end

local function removeFromLoad( amb, id )
    if not IsValid( amb ) or not amb.PMR_Load then return end

    table.RemoveByValue( amb.PMR_Load, id )
    updateLoad( amb )
end

function PMR.MarkAmbulance( ent, ply )
    ent.PMR_IsAmbulance = true
    ent.PMR_Load = ent.PMR_Load or {}
    ent:SetNW2Bool( "PMR_Ambulance", true )
    updateLoad( ent )
    PMR.Ambulances[ent] = true

    local who = IsValid( ply ) and ply:Nick() or "Dispatch"
    PMR.NotifyMedics( who .. " marked a vehicle as the ambulance. Carry spine boards up to it and press Left Mouse to load." )
end

function PMR.UnmarkAmbulance( ent, ply )
    ent.PMR_IsAmbulance = nil
    ent:SetNW2Bool( "PMR_Ambulance", false )
    PMR.Ambulances[ent] = nil

    PMR.Notify( ply, "That vehicle is no longer an ambulance." )
end

function PMR.HasAmbulance()
    for ent in pairs( PMR.Ambulances ) do
        if IsValid( ent ) then return true end

        PMR.Ambulances[ent] = nil
    end

    return false
end

function PMR.NearestAmbulance( pos, range )
    local best, bestDist

    for ent in pairs( PMR.Ambulances ) do
        if IsValid( ent ) then
            local dist = pos:Distance( ent:NearestPoint( pos ) )
            if dist <= range and ( not bestDist or dist < bestDist ) then
                best, bestDist = ent, dist
            end
        end
    end

    return best
end

local function aimedAmbulance( ply )
    local tr = ply:GetEyeTrace()
    if not IsValid( tr.Entity ) or tr.HitPos:Distance( ply:EyePos() ) > AIM_AMBULANCE_RANGE then return end

    local ent = PMR.TopParent( tr.Entity )
    if ent.PMR_IsAmbulance then return ent end
end

-- The first vehicle a medic gets into becomes the ambulance, if there isn't one yet.
hook.Add( "PlayerEnteredVehicle", "PMR_AutoAmbulance", function( ply, veh )
    if not PMR.CV.auto_ambulance:GetBool() or not PMR.IsMedic( ply ) or PMR.HasAmbulance() then return end

    local ent = PMR.TopParent( veh )
    -- A lone seat is a chair, not a vehicle worth marking.
    if ent == veh and veh:GetClass() == "prop_vehicle_prisoner_pod" then return end
    if not ambulanceCandidate( ent ) then return end

    PMR.MarkAmbulance( ent, ply )
end )

--[[ Hospitals ]]

function PMR.Hospitals()
    return ents.FindByClass( "pmr_hospital" )
end

function PMR.NearHospital( pos )
    local radius = PMR.CV.hospital_radius:GetFloat()

    for _, hospital in ipairs( PMR.Hospitals() ) do
        if hospital:GetPos():Distance( pos ) <= radius then return hospital end
    end
end

--[[ Loading, unloading, handing over ]]

-- Takes the patient off the board and puts board and patient back in the world beside `amb`,
-- or at `fallbackPos` if the ambulance is gone. Returns the board (nil if it was removed).
local function bringOut( p, spot, yaw )
    local board = p.stowedBoard

    p.stowedBoard = nil
    removeFromLoad( p.ambulance, p.id )
    p.ambulance = nil

    if not IsValid( board ) then
        board = ents.Create( "pmr_board" )
        if not IsValid( board ) then return end

        board:SetPos( spot )
        board:Spawn()
    end

    board.PMR_Stowed = nil
    board:SetPos( spot )
    board:SetAngles( Angle( 0, yaw, 0 ) )
    unstow( board )

    return board
end

local function unloadSpot( amb, towards )
    local edge = amb:NearestPoint( towards )
    local out = towards - edge
    out.z = 0

    if out:LengthSqr() < 1 then
        out = -amb:GetForward()
        out.z = 0
    end

    out:Normalize()

    local ground = PMR.Ground( edge + out * UNLOAD_OFFSET, amb ) or towards

    return ground + Vector( 0, 0, UNLOAD_HEIGHT )
end

function PMR.Deliver( p )
    if p.state == PMR.STATE_DELIVERED or p.state == PMR.STATE_DEAD then return end

    for ply, work in pairs( PMR.Working ) do
        if work.patient == p.id then
            PMR.CancelAction( ply, true )
        end
    end

    if p.state == PMR.STATE_AMBULANCE then
        -- Handed over straight from the ambulance: give the crew their empty board back.
        local amb = p.ambulance
        local spot = IsValid( amb ) and unloadSpot( amb, amb:GetPos() - amb:GetForward() * 200 ) or PMR.PatientPos( p )
        local board = bringOut( p, spot, IsValid( amb ) and amb:GetAngles().y or 0 )
        if IsValid( board ) then
            board:EmitSound( PMR.Sounds.deliver, 70 )
        end
    else
        if IsValid( p.board ) then
            p.board:EmitSound( PMR.Sounds.deliver, 70 )
        end

        PMR.ReleaseFromBoard( p )
    end

    local condition = PMR.Triage( p )
    p.deliveredInArrest = p.arrest
    p.state = PMR.STATE_DELIVERED
    p.arrest = false

    SafeRemoveEntity( p.ragdoll )
    p.ragdoll = nil

    PMR.NotifyMedics( p.name .. " handed over to the hospital team (" .. string.lower( condition ) .. ")." )
    PMR.SyncSoon()
end

function PMR.LoadIntoAmbulance( ply, board )
    local p = PMR.Patients[board:GetPatient()]

    if not p then
        PMR.Notify( ply, "Strap a patient onto the board first (patient chart > Log-roll onto board)." )

        return
    end

    if p.state ~= PMR.STATE_BOARD or not IsValid( p.ragdoll ) then
        PMR.Notify( ply, p.name .. " has died. There's no one to transport." )

        return
    end

    local amb = PMR.NearestAmbulance( board:GetPos(), LOAD_RANGE )

    if not amb then
        if PMR.HasAmbulance() then
            PMR.Notify( ply, "Carry the board right up to the ambulance, then press Left Mouse." )
        else
            PMR.Notify( ply, "You don't have an ambulance. Look at a vehicle and press R with the kit (or just get in one)." )
        end

        return
    end

    board:ReleaseAll()
    PMR.ReleaseFromBoard( p )
    stow( board )
    stow( p.ragdoll )
    board.PMR_Stowed = true

    p.state = PMR.STATE_AMBULANCE
    p.ambulance = amb
    p.stowedBoard = board
    table.insert( amb.PMR_Load, p.id )
    updateLoad( amb )
    amb:EmitSound( PMR.Sounds.load, 70 )

    if #PMR.Hospitals() == 0 then
        PMR.Notify( ply, "No hospital drop-off on this map (admins: spawn menu > Entities > Paramedic Response), so loading counts as transport." )
        PMR.Deliver( p )

        return
    end

    PMR.NotifyMedics( p.name .. " is loaded. Get them to the hospital and unload at the drop-off." )
    PMR.SyncSoon()
end

function PMR.UnloadFromAmbulance( ply, amb, p )
    if p.ambulance ~= amb then return end
    if not ply:Alive() or ply:InVehicle() then return end

    if ply:GetPos():Distance( amb:NearestPoint( ply:GetPos() ) ) > UNLOAD_RANGE then
        PMR.Notify( ply, "Stand next to the ambulance to unload." )

        return
    end

    if IsValid( ply.PMR_Board ) then
        PMR.Notify( ply, "Put down the board you're carrying first (E)." )

        return
    end

    local board = bringOut( p, unloadSpot( amb, ply:GetPos() ), ply:EyeAngles().y )
    if not IsValid( board ) then return end

    board:AddCarrier( ply )
    if not IsValid( p.ragdoll ) then return end

    unstow( p.ragdoll )
    PMR.PlaceOnBoard( p, board )

    if p.state ~= PMR.STATE_DEAD then
        p.state = PMR.STATE_BOARD
    end

    PMR.SyncSoon()
end

-- At the end of a call: put a stowed patient's board back beside the ambulance and remove them.
function PMR.RestoreFromAmbulance( p )
    local amb = p.ambulance
    local spot = IsValid( amb ) and unloadSpot( amb, amb:GetPos() - amb:GetForward() * 200 ) or PMR.PatientPos( p )

    bringOut( p, spot, IsValid( amb ) and amb:GetAngles().y or 0 )
    SafeRemoveEntity( p.ragdoll )
    p.ragdoll = nil
end

-- An ambulance that disappears drops its patients where it was.
hook.Add( "EntityRemoved", "PMR_AmbulanceRemoved", function( ent )
    if not ent.PMR_IsAmbulance then return end

    PMR.Ambulances[ent] = nil

    for _, id in ipairs( table.Copy( ent.PMR_Load or {} ) ) do
        local p = PMR.Patients[id]

        if p and p.ambulance == ent then
            local board = bringOut( p, unloadSpot( ent, ent:GetPos() - ent:GetForward() * 200 ), ent:GetAngles().y )
            if IsValid( board ) and IsValid( p.ragdoll ) then
                unstow( p.ragdoll )
                PMR.PlaceOnBoard( p, board )
            end

            if p.state ~= PMR.STATE_DEAD then
                p.state = PMR.STATE_BOARD
            end
        end
    end

    PMR.SyncSoon()
end )

-- Boards with a patient on them inside a hospital drop-off hand the patient over.
timer.Create( "PMR_Delivery", DELIVERY_INTERVAL, 0, function()
    for _, p in pairs( PMR.Patients ) do
        if p.state == PMR.STATE_BOARD and IsValid( p.board ) and PMR.NearHospital( p.board:GetPos() ) then
            p.handover = ( p.handover or 0 ) + DELIVERY_INTERVAL

            if p.handover >= HANDOVER_TIME then
                PMR.Deliver( p )
            end
        else
            p.handover = 0
        end
    end
end )

--[[ The paramedic kit's buttons (weapon_pmr_kit calls these serverside) ]]

-- Left mouse: load the (occupied) board you're carrying, or open the chart of the patient you're looking at.
function PMR.KitPrimary( ply )
    local board = ply.PMR_Board

    if IsValid( board ) and board:GetPatient() ~= 0 then
        PMR.LoadIntoAmbulance( ply, board )

        return
    end

    local p = PMR.AimedPatient( ply )
    if p then
        PMR.OpenChart( ply, p )
    end
end

-- Right mouse: the ambulance's patient list.
function PMR.KitSecondary( ply )
    local amb = aimedAmbulance( ply ) or PMR.NearestAmbulance( ply:GetPos(), NEAR_AMBULANCE_RANGE )

    if not amb then
        PMR.Notify( ply, "No ambulance here. Look at a vehicle and press R with the kit to make it the ambulance." )

        return
    end

    PMR.SyncPatients( ply )

    net.Start( "PMR_Open" )
    net.WriteUInt( PMR.OPEN_AMBULANCE, 3 )
    net.WriteEntity( amb )
    net.Send( ply )
end

-- Reload: mark / unmark the vehicle you're looking at as the ambulance.
function PMR.KitReload( ply )
    local tr = ply:GetEyeTrace()

    if not IsValid( tr.Entity ) or tr.HitPos:Distance( ply:EyePos() ) > AIM_AMBULANCE_RANGE then
        PMR.Notify( ply, "Look at a vehicle to mark it as the ambulance." )

        return
    end

    local ent = PMR.TopParent( tr.Entity )

    if ent.PMR_IsAmbulance then
        if #ent.PMR_Load > 0 then
            PMR.Notify( ply, "Unload the patients before you stop using this ambulance." )

            return
        end

        PMR.UnmarkAmbulance( ent, ply )

        return
    end

    if not ambulanceCandidate( ent ) then
        PMR.Notify( ply, "That can't be an ambulance." )

        return
    end

    PMR.MarkAmbulance( ent, ply )
end

--[[ Hospital drop-offs are saved per map ]]

local cleaningUp = false
local shuttingDown = false

local function dataPath()
    return DATA_DIR .. "/" .. string.lower( game.GetMap() ) .. ".json"
end

function PMR.SaveHospitals()
    local list = {}

    for _, hospital in ipairs( PMR.Hospitals() ) do
        local pos = hospital:GetPos()
        table.insert( list, { x = pos.x, y = pos.y, z = pos.z, yaw = hospital:GetAngles().y } )
    end

    file.CreateDir( DATA_DIR )
    file.Write( dataPath(), util.TableToJSON( { hospitals = list }, true ) )
    PMR.Debug( "Saved", #list, "hospital drop-off(s) for", game.GetMap() )
end

local function saveSoon()
    if cleaningUp or shuttingDown then return end

    timer.Create( "PMR_SaveHospitals", 0.5, 1, PMR.SaveHospitals )
end

function PMR.LoadHospitals()
    if #PMR.Hospitals() > 0 then return end

    local raw = file.Read( dataPath(), "DATA" )
    if not raw then return end

    local data = util.JSONToTable( raw )
    if not istable( data ) or not istable( data.hospitals ) then return end

    for _, saved in ipairs( data.hospitals ) do
        if isnumber( saved.x ) and isnumber( saved.y ) and isnumber( saved.z ) then
            local hospital = ents.Create( "pmr_hospital" )
            hospital:SetPos( Vector( saved.x, saved.y, saved.z ) )
            hospital:SetAngles( Angle( 0, tonumber( saved.yaw ) or 0, 0 ) )
            hospital:Spawn()
        end
    end
end

hook.Add( "InitPostEntity", "PMR_LoadHospitals", function()
    timer.Simple( 1, PMR.LoadHospitals )
end )

hook.Add( "PreCleanupMap", "PMR_Hospitals", function()
    cleaningUp = true
end )

hook.Add( "PostCleanupMap", "PMR_Hospitals", function()
    cleaningUp = false
    PMR.Ambulances = {}
    timer.Simple( 0.5, PMR.LoadHospitals )
end )

hook.Add( "ShutDown", "PMR_Hospitals", function()
    shuttingDown = true
end )

hook.Add( "PlayerSpawnedSENT", "PMR_SaveHospitals", function( _, ent )
    if ent:GetClass() == "pmr_hospital" then saveSoon() end
end )

hook.Add( "PhysgunDrop", "PMR_SaveHospitals", function( _, ent )
    if ent:GetClass() == "pmr_hospital" then saveSoon() end
end )

hook.Add( "EntityRemoved", "PMR_SaveHospitals", function( ent )
    if ent:GetClass() == "pmr_hospital" then saveSoon() end
end )
