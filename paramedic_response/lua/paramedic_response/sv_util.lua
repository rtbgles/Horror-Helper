-- Server helpers: who is on duty, messages, finding places on the map.

local PMR = ParamedicResponse

local MIN_SCENE_AREA = 140 -- nav areas smaller than this (either side) can't fit a crash
local SCENE_CLEAR_HALF = 110 -- the scene needs this much room either side of its centre
local SCENE_CLEAR_HEIGHT = 90
local SKY_TRACE = 3000
local SCENE_TRIES = 40
local FALLBACK_TRIES = 80
local FALLBACK_DROP = 4000

function PMR.Debug( ... )
    if not PMR.CV.debug:GetBool() then return end

    print( "[Paramedic Response]", ... )
end

function PMR.Notify( ply, msg )
    if IsValid( ply ) then
        ply:ChatPrint( "[Dispatch] " .. msg )
    else
        print( "[Paramedic Response] " .. msg )
    end
end

function PMR.NotifyMedics( msg )
    for _, ply in ipairs( PMR.Medics() ) do
        ply:ChatPrint( "[Dispatch] " .. msg )
    end
end

function PMR.IsAdmin( ply )
    return not IsValid( ply ) or ply:IsAdmin()
end

function PMR.IsMedic( ply )
    return IsValid( ply ) and ply:IsPlayer() and ply:GetNW2Bool( "PMR_Duty" )
end

-- Everyone on duty (alive or not).
function PMR.Medics()
    local out = {}

    for _, ply in player.Iterator() do
        if ply:GetNW2Bool( "PMR_Duty" ) then
            table.insert( out, ply )
        end
    end

    return out
end

function PMR.HoldingKit( ply )
    local wep = ply:GetActiveWeapon()

    return IsValid( wep ) and wep:GetClass() == "weapon_pmr_kit"
end

function PMR.SafeModel( path )
    if path and util.IsValidModel( path ) then return path end

    return PMR.Models.fallback
end

-- A random model from `list` that exists on this server, or nil.
function PMR.PickModel( list )
    local valid = {}

    for _, path in ipairs( list ) do
        if util.IsValidModel( path ) then
            table.insert( valid, path )
        end
    end

    if #valid == 0 then return end

    return valid[math.random( #valid )]
end

function PMR.PickSound( list )
    if isstring( list ) then return list end

    return list[math.random( #list )]
end

-- The outermost parent: a seat parented to a car resolves to the car.
function PMR.TopParent( ent )
    local guard = 0

    while IsValid( ent:GetParent() ) and guard < 8 do
        ent = ent:GetParent()
        guard = guard + 1
    end

    return ent
end

-- The floor under `pos`, or nil if there isn't one within reach.
function PMR.Ground( pos, filter )
    local tr = util.TraceLine( {
        start = pos + Vector( 0, 0, 64 ),
        endpos = pos - Vector( 0, 0, FALLBACK_DROP ),
        mask = MASK_SOLID,
        filter = filter,
    } )

    if not tr.Hit or tr.HitSky then return end

    return tr.HitPos, tr.HitNormal
end

local function isOutdoors( pos )
    local tr = util.TraceLine( {
        start = pos + Vector( 0, 0, 40 ),
        endpos = pos + Vector( 0, 0, SKY_TRACE ),
        mask = MASK_SOLID_BRUSHONLY,
    } )

    return tr.HitSky or not tr.Hit
end

local function hasRoom( pos )
    local tr = util.TraceHull( {
        start = pos + Vector( 0, 0, 12 ),
        endpos = pos + Vector( 0, 0, 14 ),
        mins = Vector( -SCENE_CLEAR_HALF, -SCENE_CLEAR_HALF, 0 ),
        maxs = Vector( SCENE_CLEAR_HALF, SCENE_CLEAR_HALF, SCENE_CLEAR_HEIGHT ),
        mask = MASK_SOLID,
    } )

    return not tr.Hit and not tr.StartSolid
end

local function sceneFromNavmesh( origin, minDist, maxDist, wantOutdoors )
    local candidates = {}

    for _, area in ipairs( navmesh.GetAllNavAreas() ) do
        if area:GetSizeX() >= MIN_SCENE_AREA and area:GetSizeY() >= MIN_SCENE_AREA and not area:IsUnderwater() then
            local dist = area:GetCenter():Distance( origin )
            if dist >= minDist and dist <= maxDist then
                table.insert( candidates, area )
            end
        end
    end

    for _ = 1, math.min( SCENE_TRIES, #candidates ) do
        local index = math.random( #candidates )
        local area = candidates[index]
        table.remove( candidates, index )

        local pos = area:GetCenter()
        if hasRoom( pos ) and ( not wantOutdoors or isOutdoors( pos ) ) then return pos end
    end
end

local function sceneFromTraces( origin, minDist, maxDist )
    for _ = 1, FALLBACK_TRIES do
        local yaw = math.Rand( 0, 360 )
        local dist = math.Rand( minDist, maxDist )
        local probe = origin + Angle( 0, yaw, 0 ):Forward() * dist + Vector( 0, 0, 200 )
        local ground, normal = PMR.Ground( probe )

        if ground and normal.z > 0.85 and hasRoom( ground ) then return ground end
    end
end

-- Somewhere open between minDist and maxDist from `origin` to stage a crash.
-- Prefers outdoor navmesh areas and relaxes the rules until something fits.
function PMR.FindScenePos( origin, minDist, maxDist )
    local attempts = {
        { minDist, maxDist, true },
        { minDist, maxDist, false },
        { minDist * 0.5, maxDist * 1.5, false },
        { 300, maxDist * 3, false },
    }

    for _, attempt in ipairs( attempts ) do
        local pos = sceneFromNavmesh( origin, attempt[1], attempt[2], attempt[3] )
        if pos then return pos end
    end

    PMR.Debug( "No usable navmesh area, falling back to traces (run nav_generate for better scenes)" )

    return sceneFromTraces( origin, minDist, maxDist ) or sceneFromTraces( origin, 300, maxDist )
end
