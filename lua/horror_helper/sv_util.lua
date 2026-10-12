-- Server helpers: who can see what, finding places on the map, small utilities.

local HH = HorrorHelper

local SEEN_COS = math.cos( math.rad( 62 ) ) -- a little wider than a 90 degree view
local SEEN_ALWAYS_DIST = 260 -- this close you'd hear or feel it even facing away
local SEEN_MAX_DIST = 7000
local MIN_NAV_AREA_SIZE = 24
local NPC_HULL_MINS = Vector( -18, -18, 0 )
local NPC_HULL_MAXS = Vector( 18, 18, 72 )
local PLAYER_HULL_MINS = Vector( -16, -16, 0 )
local PLAYER_HULL_MAXS = Vector( 16, 16, 72 )
local FALLBACK_TRACE_HEIGHT = 1024
local LOCAL_SEARCH_MAX = 6000 -- searches this small walk the navmesh around the centre instead of sampling the whole map
local NAV_STEP = 1000

function HH.Debug( ... )
    if not HH.CV.debug:GetBool() then return end

    print( "[Horror Helper]", ... )
end

function HH.Notify( ply, msg )
    if IsValid( ply ) then
        ply:ChatPrint( "[Horror Helper] " .. msg )
    else
        print( "[Horror Helper] " .. msg )
    end
end

function HH.NotifyAll( msg )
    for _, ply in player.Iterator() do
        ply:ChatPrint( msg )
    end
end

function HH.IsAdmin( ply )
    return not IsValid( ply ) or ply:IsAdmin()
end

function HH.SafeModel( path )
    if path and util.IsValidModel( path ) then return path end

    return HH.Models.fallback
end

function HH.PickSound( list )
    if isstring( list ) then return list end

    return list[math.random( #list )]
end

-- Players still in the night: in the roster, alive, not spectating.
function HH.AlivePlayers()
    local out = {}
    local roster = HH.State and HH.State.roster or {}

    for _, ply in player.Iterator() do
        if roster[ply] and ply:Alive() and not HH.IsOut( ply ) then
            table.insert( out, ply )
        end
    end

    return out
end

function HH.CanPlayerSee( ply, pos )
    local eye = ply:EyePos()
    local delta = pos - eye
    local dist = delta:Length()

    if dist < SEEN_ALWAYS_DIST then return true end
    if dist > SEEN_MAX_DIST then return false end
    if ply:GetAimVector():Dot( delta / dist ) < SEEN_COS then return false end

    local tr = util.TraceLine( {
        start = eye,
        endpos = pos,
        mask = MASK_BLOCKLOS,
        filter = ply,
    } )

    return not tr.Hit
end

-- Is a standing figure at pos (feet) visible to any living survivor?
function HH.IsSpotSeen( pos )
    local head = pos + Vector( 0, 0, 64 )
    local chest = pos + Vector( 0, 0, 36 )

    for _, ply in ipairs( HH.AlivePlayers() ) do
        if HH.CanPlayerSee( ply, head ) or HH.CanPlayerSee( ply, chest ) then return true end
    end

    return false
end

function HH.IsEntitySeen( ent )
    local center = ent:WorldSpaceCenter()
    local top = ent:GetPos() + Vector( 0, 0, ent:OBBMaxs().z * 0.9 )

    for _, ply in ipairs( HH.AlivePlayers() ) do
        if HH.CanPlayerSee( ply, center ) or HH.CanPlayerSee( ply, top ) then return true end
    end

    return false
end

function HH.HullClear( pos, forPlayer )
    local tr = util.TraceHull( {
        start = pos + Vector( 0, 0, 4 ),
        endpos = pos + Vector( 0, 0, 4 ),
        mins = forPlayer and PLAYER_HULL_MINS or NPC_HULL_MINS,
        maxs = forPlayer and PLAYER_HULL_MAXS or NPC_HULL_MAXS,
        mask = forPlayer and MASK_PLAYERSOLID or MASK_NPCSOLID,
    } )

    return not tr.StartSolid and not tr.Hit
end

function HH.NearestPlayer( pos, list )
    local best, bestDist

    for _, ply in ipairs( list or HH.AlivePlayers() ) do
        local dist = ply:GetPos():Distance( pos )
        if not bestDist or dist < bestDist then
            best = ply
            bestDist = dist
        end
    end

    return best, bestDist
end

--[[
    Places on the map. The navmesh is preferred (it knows where things can stand); without
    one, points are found by dropping traces around a centre, which works on open maps only.
]]
HH.NavAreas = HH.NavAreas or {}

function HH.BuildNavCache()
    HH.NavAreas = {}
    if not navmesh.IsLoaded() then return 0 end

    for _, area in ipairs( navmesh.GetAllNavAreas() ) do
        if not area:IsUnderwater() and area:GetSizeX() >= MIN_NAV_AREA_SIZE and area:GetSizeY() >= MIN_NAV_AREA_SIZE then
            table.insert( HH.NavAreas, area )
        end
    end

    return #HH.NavAreas
end

local function fallbackPoint( center, minDist, maxDist )
    local yaw = math.Rand( 0, 360 )
    local dist = math.Rand( minDist, maxDist )
    local offset = Angle( 0, yaw, 0 ):Forward() * dist
    local top = center + offset + Vector( 0, 0, FALLBACK_TRACE_HEIGHT )
    if not util.IsInWorld( top ) then
        top = center + offset + Vector( 0, 0, 64 )
        if not util.IsInWorld( top ) then return nil end
    end

    local tr = util.TraceLine( {
        start = top,
        endpos = top - Vector( 0, 0, FALLBACK_TRACE_HEIGHT * 2 ),
        mask = MASK_SOLID_BRUSHONLY,
    } )
    if not tr.Hit or tr.StartSolid or tr.HitSky then return nil end
    if tr.HitNormal.z < 0.7 then return nil end

    return tr.HitPos
end

-- A random standable point between minDist and maxDist of center, or nil.
function HH.RandomPointAround( center, minDist, maxDist, areas )
    areas = areas or HH.NavAreas

    if #areas > 0 then
        local area = areas[math.random( #areas )]
        local point = area:GetRandomPoint()
        local dist = point:Distance( center )
        if dist >= minDist and dist <= maxDist then return point end

        return nil
    end

    return fallbackPoint( center, minDist, maxDist )
end

-- Tries up to `tries` random points; returns the first one `accept( point )` likes.
function HH.FindPoint( center, minDist, maxDist, tries, accept )
    local areas
    if #HH.NavAreas > 0 and maxDist <= LOCAL_SEARCH_MAX and tries > 1 then
        areas = {}
        for _, area in ipairs( navmesh.Find( center, maxDist, NAV_STEP, NAV_STEP ) ) do
            if not area:IsUnderwater() then
                table.insert( areas, area )
            end
        end
        if #areas == 0 then return nil end
    end

    for _ = 1, tries do
        local point = HH.RandomPointAround( center, minDist, maxDist, areas )
        if point and ( not accept or accept( point ) ) then return point end
    end

    return nil
end

-- A free spot for a player near pos, searched in rings, never through a wall.
function HH.FindPlayerSpot( pos, taken )
    local rings = { 0, 48, 96, 144, 192, 240 }

    for _, radius in ipairs( rings ) do
        local steps = radius == 0 and 1 or 8

        for i = 1, steps do
            local yaw = i * ( 360 / steps )
            local spot = pos + Angle( 0, yaw, 0 ):Forward() * radius

            local wall = util.TraceLine( {
                start = pos + Vector( 0, 0, 40 ),
                endpos = spot + Vector( 0, 0, 40 ),
                mask = MASK_PLAYERSOLID_BRUSHONLY,
            } )

            local free = not wall.Hit and HH.HullClear( spot, true )
            if free then
                for _, other in ipairs( taken ) do
                    if other:Distance( spot ) < 40 then
                        free = false
                        break
                    end
                end
            end

            if free then return spot end
        end
    end

    return pos
end
