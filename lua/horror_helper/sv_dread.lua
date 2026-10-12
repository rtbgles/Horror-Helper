--[[
    Dread and the psychological scares.

    Dread (0..1) climbs through the night: with time, with how set up the cabin is (the more
    you have to lose...), once the sieges have started, and a little with every time the killer
    shows itself. Clients read it too (HH_Dread): fog closes in, colour drains, the edges of the
    screen darken.

    While the killer is NOT on the map, the director asks this file for scares. How often scales
    with dread and with being alone; which ones are possible depends on dread:

      any time   footsteps behind you, a glimpse of it standing far off
      0.30+      breathing behind your head, the cabin lamps stutter
      0.35+      your flashlight stutters, knocking on the boards from outside
      0.55+      a teammate's voice calling from where no teammate is
      0.70+      the power dies for a while
      0.75+      a glimpse of it standing inside the cabin with you
]]

local HH = HorrorHelper

HH.Psych = HH.Psych or {}
local Psych = HH.Psych

local DREAD_BASE = 0.08
local DREAD_TIME = 0.55 -- from the night passing (reached at dawn with hh_dread_speed 1)
local DREAD_PROGRESS = 0.2 -- from the cabin being set up
local DREAD_SIEGE = 0.12 -- once the attacks on the cabin have begun
local DREAD_PER_CONTACT = 0.03 -- every appearance leaves a mark...
local DREAD_CONTACT_CAP = 0.15 -- ...up to this much

local RATE_CALM = 0.6 -- scares per survivor per minute at no dread (times hh_psych_rate)
local RATE_PEAK = 3 -- at full dread
local ALONE_FACTOR = 1.6
local ALONE_RADIUS = 600
local COOLDOWN_CALM = 50 -- seconds between scares for one survivor at no dread
local COOLDOWN_PEAK = 14 -- at full dread

local SIGHT_FAR = { 700, 1500 } -- glimpse distance at no dread
local SIGHT_NEAR = { 350, 800 } -- at full dread
local SIGHT_INSIDE = { 220, 520 }
local SIGHT_MAX_DOT = 0.85 -- off to the side, not dead centre
local SIGHT_MIN_DOT = -0.1
local KNOCKS = 3
local KNOCK_GAP = 0.45
local FAKE_CALL_DIST = { 700, 1100 }
local POWER_CUT_LENGTH = { 6, 14 }
local POWER_CUT_COOLDOWN = 90
local FLICKER_COOLDOWN = 25

local nextScare = {}
local globalCooldown = { powerCut = 0, flicker = 0 }

local function now()
    return CurTime()
end

function Psych.Reset()
    nextScare = {}
    globalCooldown = { powerCut = 0, flicker = 0 }
    SetGlobal2Float( "HH_Dread", 0 )
    SetGlobal2Float( "HH_PowerCutUntil", 0 )
end

function Psych.UpdateDread( contacts, siegeStarted )
    local S = HH.State
    local frac = ( now() - ( S.nightStart or now() ) ) / ( S.nightLength or 1 )
    frac = math.Clamp( frac * HH.CV.dread_speed:GetFloat(), 0, 1 )

    local progress = HH.GetStage() == HH.STAGE_PREPARE and HH.GetSetupProgress() or 0
    local dread = DREAD_BASE + DREAD_TIME * frac + DREAD_PROGRESS * progress
    if siegeStarted then
        dread = dread + DREAD_SIEGE
    end
    dread = dread + math.min( DREAD_CONTACT_CAP, contacts * DREAD_PER_CONTACT )
    dread = math.Clamp( dread, 0, 1 )

    SetGlobal2Float( "HH_Dread", dread )

    return dread
end

local function cabin()
    return HH.State.cabin
end

local function isInside( ply )
    local c = cabin()

    return c and ply:GetPos():Distance( c.center ) <= c.radius
end

local function hasPower()
    return GetGlobal2Bool( "HH_Power", false ) and now() >= GetGlobal2Float( "HH_PowerCutUntil", 0 )
end

local function isAlone( ply, alive )
    for _, other in ipairs( alive ) do
        if other ~= ply and other:GetPos():Distance( ply:GetPos() ) < ALONE_RADIUS then return false end
    end

    return true
end

--[[ The scares ]]

local function sighting( ply, dread, inside )
    if not HH.CV.sightings:GetBool() then return false end
    if GetGlobal2String( "HH_KillerModel", "" ) == "" then return false end

    local range
    if inside then
        range = SIGHT_INSIDE
    else
        range = { Lerp( dread, SIGHT_FAR[1], SIGHT_NEAR[1] ), Lerp( dread, SIGHT_FAR[2], SIGHT_NEAR[2] ) }
    end

    local c = cabin()
    local eye = ply:EyePos()
    local aim = ply:GetAimVector()

    local spot = HH.FindPoint( ply:GetPos(), range[1], range[2], 30, function( point )
        local inCabin = c ~= nil and point:Distance( c.center ) < c.radius
        if inside ~= inCabin then return false end

        local head = point + Vector( 0, 0, 60 )
        local dot = aim:Dot( ( head - eye ):GetNormalized() )
        if dot > SIGHT_MAX_DOT or dot < SIGHT_MIN_DOT then return false end

        local tr = util.TraceLine( { start = eye, endpos = head, mask = MASK_BLOCKLOS, filter = ply } )

        return not tr.Hit
    end )
    if not spot then return false end

    net.Start( "HH_Sight" )
    net.WriteVector( spot )
    net.WriteFloat( ( ply:GetPos() - spot ):Angle().y )
    net.Send( ply )

    return true
end

local function knock( ply )
    local barricades = {}
    for _, ent in ipairs( HH.State.roundEnts or {} ) do
        if IsValid( ent ) and ent.HHBarricade then
            table.insert( barricades, ent )
        end
    end
    if #barricades == 0 then return false end

    -- The nearest door or window to them, from the outside.
    table.sort( barricades, function( a, b )
        return a:GetPos():DistToSqr( ply:GetPos() ) < b:GetPos():DistToSqr( ply:GetPos() )
    end )

    local target = barricades[math.random( math.min( 2, #barricades ) )]
    local fwd = target:GetForward()
    local center = cabin().center
    local a = target:GetPos() + fwd * 30 + Vector( 0, 0, 50 )
    local b = target:GetPos() - fwd * 30 + Vector( 0, 0, 50 )
    local pos = a:Distance( center ) > b:Distance( center ) and a or b
    local pitch = math.random( 80, 95 )

    for i = 1, KNOCKS do
        timer.Simple( ( i - 1 ) * KNOCK_GAP, function()
            if HH.GetPhase() ~= HH.PHASE_NIGHT then return end

            sound.Play( HH.PickSound( HH.Sounds.bash ), pos, 75, pitch, 0.7 )
        end )
    end

    return true
end

local function flashlightStutter( ply )
    if not ply:FlashlightIsOn() then return false end

    local steps = { { 0, false }, { 0.12, true }, { 0.22, false }, { 0.5, true }, { 0.58, false }, { 1.3, true } }
    for _, step in ipairs( steps ) do
        timer.Simple( step[1], function()
            if IsValid( ply ) and ply:Alive() and HH.GetPhase() == HH.PHASE_NIGHT then
                ply:Flashlight( step[2] )
            end
        end )
    end

    return true
end

local function fakeCall( ply, alive )
    local others = {}
    for _, other in ipairs( alive ) do
        if other ~= ply then
            table.insert( others, other )
        end
    end
    if #others == 0 then return false end

    -- One of your friends' voices, from somewhere none of them are.
    local who = others[math.random( #others )]
    local dir = Angle( 0, math.Rand( 0, 360 ), 0 ):Forward()
    local pos = ply:GetPos() + dir * math.Rand( FAKE_CALL_DIST[1], FAKE_CALL_DIST[2] ) + Vector( 0, 0, 60 )

    for _, other in ipairs( others ) do
        if other:GetPos():Distance( pos ) < FAKE_CALL_DIST[1] * 0.6 then return false end
    end

    local model = string.lower( who:GetModel() or "" )
    local list = string.find( model, "female", 1, true ) and HH.Sounds.calloutFemale or HH.Sounds.calloutMale
    HH.SendCall( ply, pos, who:Nick(), HH.PickSound( list ) )

    return true
end

local function flicker()
    if now() < globalCooldown.flicker then return false end

    globalCooldown.flicker = now() + FLICKER_COOLDOWN
    HH.SendCue( HH.CUE_FLICKER )

    return true
end

local function powerCut()
    if now() < globalCooldown.powerCut then return false end

    local length = math.Rand( POWER_CUT_LENGTH[1], POWER_CUT_LENGTH[2] )
    globalCooldown.powerCut = now() + length + POWER_CUT_COOLDOWN
    SetGlobal2Float( "HH_PowerCutUntil", now() + length )
    HH.SendCue( HH.CUE_POWERCUT )
    HH.Debug( "power cut for", math.Round( length ), "s" )

    return true
end

-- minDread: when it becomes possible. weight: how likely among what's possible.
local SCARES = {
    { name = "footsteps", minDread = 0, weight = 3, run = function( ply, ctx )
        if not HH.CV.phantoms:GetBool() then return false end
        if ctx.inside and ctx.dread < 0.5 then return false end

        HH.SendCue( HH.CUE_PHANTOM, ply:GetPos(), ply )
        return true
    end },
    { name = "glimpse", minDread = 0, weight = 3, run = function( ply, ctx )
        if ctx.inside then return false end

        return sighting( ply, ctx.dread, false )
    end },
    { name = "breath", minDread = 0.3, weight = 2, run = function( ply )
        if not HH.CV.phantoms:GetBool() then return false end

        HH.SendCue( HH.CUE_BREATH, ply:GetPos(), ply )
        return true
    end },
    { name = "flicker", minDread = 0.3, weight = 1, run = function( _, ctx )
        if not HH.CV.phantoms:GetBool() or not ctx.inside or not hasPower() then return false end

        return flicker()
    end },
    { name = "flashlight", minDread = 0.35, weight = 2, run = function( ply )
        if not HH.CV.phantoms:GetBool() then return false end

        return flashlightStutter( ply )
    end },
    { name = "knock", minDread = 0.35, weight = 2, run = function( ply, ctx )
        if not HH.CV.phantoms:GetBool() or not ctx.inside then return false end

        return knock( ply )
    end },
    { name = "voice", minDread = 0.55, weight = 2, run = function( ply, ctx )
        if not HH.CV.phantoms:GetBool() then return false end

        return fakeCall( ply, ctx.alive )
    end },
    { name = "powercut", minDread = 0.7, weight = 1, run = function( _, ctx )
        if not HH.CV.phantoms:GetBool() or not ctx.inside or not hasPower() then return false end

        return powerCut()
    end },
    { name = "intruder", minDread = 0.75, weight = 1, run = function( ply, ctx )
        if not ctx.inside then return false end

        return sighting( ply, ctx.dread, true )
    end },
}

local function pickScare( ply, ctx )
    local pool, total = {}, 0
    for _, scare in ipairs( SCARES ) do
        if ctx.dread >= scare.minDread then
            table.insert( pool, scare )
            total = total + scare.weight
        end
    end

    -- Draw without replacement until one actually fits the moment.
    while #pool > 0 do
        local roll = math.Rand( 0, total )
        local chosen = #pool
        for i, scare in ipairs( pool ) do
            roll = roll - scare.weight
            if roll <= 0 then
                chosen = i
                break
            end
        end

        local scare = pool[chosen]
        if scare.run( ply, ctx ) then
            HH.Debug( "scare:", scare.name, "for", ply:Nick() )
            return true
        end

        total = total - scare.weight
        table.remove( pool, chosen )
    end

    return false
end

-- Called by the director every second while the killer is not on the map.
function Psych.Think( alive, dread, interval )
    local rate = HH.CV.psych_rate:GetFloat() * Lerp( dread, RATE_CALM, RATE_PEAK )
    if rate <= 0 then return end

    for _, ply in ipairs( alive ) do
        if now() >= ( nextScare[ply] or 0 ) then
            local chance = rate / 60 * interval
            if isAlone( ply, alive ) then
                chance = chance * ALONE_FACTOR
            end

            if math.random() < chance then
                local ctx = { dread = dread, alive = alive, inside = isInside( ply ) }

                if pickScare( ply, ctx ) then
                    nextScare[ply] = now() + Lerp( dread, COOLDOWN_CALM, COOLDOWN_PEAK ) * math.Rand( 0.7, 1.3 )
                end
            end
        end
    end
end
