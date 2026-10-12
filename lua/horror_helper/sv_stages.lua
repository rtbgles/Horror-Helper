--[[
    The night's opening objectives, before the home defense starts:

      REGROUP    Everyone wakes up scattered in the dark, out of sight of each other. Survivors
                 who are on their own call out every so often (others hear it, and see which way
                 it came from). Bind a key to `hh_call` to shout yourself.
      TO_CABIN   Once everyone is together (or after hh_regroup_timeout), the cabin is marked
                 on screen. Get there.
      PREPARE    Everyone is inside: power it, board it up, survive until sunrise.

    With hh_regroup 0 (or no room to scatter) everyone starts at the cabin in PREPARE.
]]

local HH = HorrorHelper

local REGROUP_LINK = 450 -- survivors this close to each other count as together
local ANCHOR_TRIES = 80
local SPOT_TRIES = 40
local CALLOUT_GAP_MIN = 20
local CALLOUT_GAP_MAX = 35
local CALLOUT_HEAR_DIST = 5000
local MANUAL_CALL_COOLDOWN = 6
local ARRIVAL_WAIT = 60 -- once someone is inside, stragglers get this long before the defense starts anyway
local ARRIVAL_EDGE = 0.9 -- "inside" is this fraction of the cabin radius

util.AddNetworkString( "HH_Call" )

local S = HH.State
local nextCall = {}

local function now()
    return CurTime()
end

function HH.SetStage( stage )
    S.stage = stage
    S.stageStart = now()
    S.firstInsideAt = nil
    SetGlobal2Int( "HH_Stage", stage )
    SetGlobal2Float( "HH_StageStart", S.stageStart )
    HH.Debug( "stage ->", stage )

    if stage ~= HH.STAGE_NONE then
        HH.SendCue( HH.CUE_STAGE )
    end
end

--[[ Scattered start ]]

-- Spawn spots for each player: far out from the cabin, spread apart from each other.
-- Returns nil if the map has no room for it (they then start at the cabin).
function HH.ScatterSpots( cabin, players )
    local spread = HH.CV.regroup_spread:GetFloat()
    local far = cabin.radius + HH.CV.regroup_distance:GetFloat()
    local near = math.max( cabin.radius + 600, far * 0.5 )

    local anchor = HH.FindPoint( cabin.center, near, far, ANCHOR_TRIES, function( point )
        return HH.HullClear( point, true )
    end )
    if not anchor then return nil end

    local spots = {}

    for i, _ in ipairs( players ) do
        local spot

        if i == 1 then
            spot = anchor
        else
            spot = HH.FindPoint( anchor, spread * 0.5, spread, SPOT_TRIES, function( point )
                if not HH.HullClear( point, true ) then return false end
                if point:Distance( cabin.center ) < cabin.radius + 400 then return false end

                for _, other in ipairs( spots ) do
                    if other:Distance( point ) < spread * 0.5 then return false end
                end

                return true
            end )
        end

        spots[i] = spot or HH.FindPlayerSpot( anchor, spots )
    end

    return spots
end

--[[ Calling out ]]

local function calloutSound( ply )
    local model = string.lower( ply:GetModel() or "" )
    local list = string.find( model, "female", 1, true ) and HH.Sounds.calloutFemale or HH.Sounds.calloutMale

    return HH.PickSound( list )
end

-- Tell players to hear `who` calling from pos. fake = it isn't really them.
function HH.SendCall( recipients, pos, name, soundPath )
    net.Start( "HH_Call" )
    net.WriteVector( pos )
    net.WriteString( name )
    net.WriteString( soundPath )
    net.Send( recipients )
end

function HH.CallOut( ply )
    local pos = ply:EyePos()
    local hearers = {}

    for _, other in player.Iterator() do
        if other:GetPos():Distance( pos ) < CALLOUT_HEAR_DIST then
            table.insert( hearers, other )
        end
    end

    if #hearers > 0 then
        HH.SendCall( hearers, pos, ply:Nick(), calloutSound( ply ) )
    end
end

concommand.Add( "hh_call", function( ply )
    if not IsValid( ply ) or HH.GetPhase() ~= HH.PHASE_NIGHT then return end
    if not ply:Alive() or HH.IsOut( ply ) then return end
    if ( ply.hhNextManualCall or 0 ) > now() then return end

    ply.hhNextManualCall = now() + MANUAL_CALL_COOLDOWN
    HH.CallOut( ply )
end )

--[[ Stage logic, run every second of the night ]]

local function allTogether( alive )
    if #alive <= 1 then return true end

    -- Everyone reachable from the first survivor through chains of nearby survivors.
    local reached = { [alive[1]] = true }
    local queue = { alive[1] }
    local count = 1

    while #queue > 0 do
        local current = table.remove( queue )

        for _, other in ipairs( alive ) do
            if not reached[other] and current:GetPos():Distance( other:GetPos() ) <= REGROUP_LINK then
                reached[other] = true
                count = count + 1
                table.insert( queue, other )
            end
        end
    end

    return count == #alive
end

local function isAlone( ply, alive )
    for _, other in ipairs( alive ) do
        if other ~= ply and other:GetPos():Distance( ply:GetPos() ) <= REGROUP_LINK then return false end
    end

    return true
end

function HH.StageThink()
    if HH.GetPhase() ~= HH.PHASE_NIGHT then return end

    local alive = HH.AlivePlayers()
    if #alive == 0 then return end

    local stage = S.stage

    if stage == HH.STAGE_REGROUP then
        local timedOut = now() - S.stageStart > HH.CV.regroup_timeout:GetFloat()

        if allTogether( alive ) or timedOut then
            HH.SetStage( HH.STAGE_TO_CABIN )
            return
        end

        for _, ply in ipairs( alive ) do
            if isAlone( ply, alive ) and now() >= ( nextCall[ply] or 0 ) then
                -- The first call comes a few seconds in, so nobody shouts over the fade-in.
                if nextCall[ply] then
                    HH.CallOut( ply )
                end
                nextCall[ply] = now() + math.Rand( CALLOUT_GAP_MIN, CALLOUT_GAP_MAX )
            end
        end

        return
    end

    if stage == HH.STAGE_TO_CABIN then
        local center = S.cabin.center
        local edge = S.cabin.radius * ARRIVAL_EDGE
        local inside = 0

        for _, ply in ipairs( alive ) do
            if ply:GetPos():Distance( center ) <= edge then
                inside = inside + 1
            end
        end

        if inside > 0 and not S.firstInsideAt then
            S.firstInsideAt = now()
        end

        local everyone = inside == #alive
        local waitedLongEnough = S.firstInsideAt and now() - S.firstInsideAt > ARRIVAL_WAIT

        if everyone or waitedLongEnough then
            HH.SetStage( HH.STAGE_PREPARE )
        end
    end
end

function HH.ResetStages()
    nextCall = {}
end
