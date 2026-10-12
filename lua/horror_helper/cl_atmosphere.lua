-- The night itself: fog, a dark sky, a cold grade, the heartbeat and chase music when the
-- killer is close, distant noises, glimpses of the killer, and footsteps that belong to no one.

local HH = HorrorHelper

local FOG_START = 80
local NIGHT_FOG = { 7, 9, 13 }
local DAWN_FOG = { 125, 104, 96 }
local NIGHT_SKY = { 4, 5, 8 }
local DAWN_SKY = { 120, 96, 84 }
local DAWN_BLEND_TIME = 120 -- the last two minutes of the night: fog thins, sky warms
local NIGHT_FOG_DENSITY = 0.97
local DAWN_FOG_DENSITY = 0.6
local DAWN_FOG_STRETCH = 3 -- fog reaches this many times further at sunrise

local HEARTBEAT_RANGE = 1300
local HEARTBEAT_SLOW = 1.15
local HEARTBEAT_FAST = 0.38
local HIDDEN_KILLER_FACTOR = 0.45 -- near but out of sight still raises the pulse, less so
local CHASE_THRESHOLD = 0.3
local CHASE_FADE_SPEED = 0.6 -- volume per second

local AMBIENT_MIN_GAP = 18
local AMBIENT_MAX_GAP = 45
local AMBIENT_MIN_DIST = 300
local AMBIENT_MAX_DIST = 900

local FLICKER_SIEGE = 2.5
local FLICKER_POWER = 1.1

local SIGHT_STARE_DOT = 0.97 -- looking right at it...
local SIGHT_STARE_TIME = 0.45 -- ...this long and it's gone
local SIGHT_TOO_CLOSE = 380
local SIGHT_LIFETIME = 14
local SIGHT_FADE_TIME = 0.35

local PHANTOM_STEP_GAP = 0.42
local PHANTOM_START_DIST = 230
local PHANTOM_STEP_CLOSER = 32

HH.Flicker = HH.Flicker or { untilTime = 0 }
HH.Cl = HH.Cl or {}

local function isNightPhase()
    local phase = HH.GetPhase()

    return phase == HH.PHASE_INTRO or phase == HH.PHASE_NIGHT
end

-- 0 at night, rising to 1 over the last stretch before sunrise.
function HH.DawnFraction()
    if HH.GetPhase() ~= HH.PHASE_NIGHT then return 0 end

    local remaining = GetGlobal2Float( "HH_PhaseEnd", 0 ) - CurTime()

    return math.Clamp( 1 - remaining / DAWN_BLEND_TIME, 0, 1 )
end

local availableCache = {}

-- Only the sounds in a list that exist on this client.
function HH.AvailableSounds( list )
    if isstring( list ) then list = { list } end
    if availableCache[list] then return availableCache[list] end

    local found = {}
    for _, path in ipairs( list ) do
        if file.Exists( "sound/" .. path, "GAME" ) then
            table.insert( found, path )
        end
    end

    availableCache[list] = found
    return found
end

function HH.RandomSound( list )
    local found = HH.AvailableSounds( list )
    if #found == 0 then return nil end

    return found[math.random( #found )]
end

-- Plays a sound "in your head": no position, no falloff.
function HH.PlayFlat( list, volume, pitch )
    local path = HH.RandomSound( list )
    local ply = LocalPlayer()
    if not path or not IsValid( ply ) then return end

    ply:EmitSound( path, 0, pitch or 100, volume or 1, CHAN_STATIC )
end

function HH.IsLampFlickering( lamp )
    if CurTime() >= HH.Flicker.untilTime then return false end

    -- Each lamp stutters on its own beat.
    local beat = math.floor( CurTime() * 14 + lamp:EntIndex() * 3 )

    return beat % 3 ~= 0
end

--[[ Lighting, fog, sky, grade ]]

net.Receive( "HH_Lights", function()
    -- Static props too, or furniture stays daylight-bright. Hitches once; it's under a fade.
    render.RedownloadAllLightmaps( true )
end )

local function fogValues( scale )
    local dawn = HH.DawnFraction()
    local fogEnd = HH.CV.fog_end:GetFloat()
    fogEnd = Lerp( dawn, fogEnd, fogEnd * DAWN_FOG_STRETCH )

    render.FogMode( MATERIAL_FOG_LINEAR )
    render.FogStart( FOG_START * scale )
    render.FogEnd( fogEnd * scale )
    render.FogMaxDensity( Lerp( dawn, NIGHT_FOG_DENSITY, DAWN_FOG_DENSITY ) )
    render.FogColor(
        Lerp( dawn, NIGHT_FOG[1], DAWN_FOG[1] ),
        Lerp( dawn, NIGHT_FOG[2], DAWN_FOG[2] ),
        Lerp( dawn, NIGHT_FOG[3], DAWN_FOG[3] )
    )
end

hook.Add( "SetupWorldFog", "HorrorHelper_Fog", function()
    if not isNightPhase() or not HH.CV.fog:GetBool() then return end

    fogValues( 1 )
    return true
end )

hook.Add( "SetupSkyboxFog", "HorrorHelper_Fog", function( scale )
    if not isNightPhase() or not HH.CV.fog:GetBool() then return end

    fogValues( scale )
    return true
end )

hook.Add( "PostDraw2DSkyBox", "HorrorHelper_Sky", function()
    if not isNightPhase() or not HH.CV.darkness:GetBool() then return end

    local dawn = HH.DawnFraction()
    render.Clear(
        Lerp( dawn, NIGHT_SKY[1], DAWN_SKY[1] ),
        Lerp( dawn, NIGHT_SKY[2], DAWN_SKY[2] ),
        Lerp( dawn, NIGHT_SKY[3], DAWN_SKY[3] ),
        255
    )
end )

local grade = {
    ["$pp_colour_addr"] = 0,
    ["$pp_colour_addg"] = 0,
    ["$pp_colour_addb"] = 0,
    ["$pp_colour_brightness"] = 0,
    ["$pp_colour_contrast"] = 1,
    ["$pp_colour_colour"] = 1,
    ["$pp_colour_mulr"] = 0,
    ["$pp_colour_mulg"] = 0,
    ["$pp_colour_mulb"] = 0,
}

local fear = 0 -- 0..1, how close and visible the killer is; drives the pulse and the grade

hook.Add( "RenderScreenspaceEffects", "HorrorHelper_Grade", function()
    if not isNightPhase() then return end

    local dawn = HH.DawnFraction()
    -- Drained and a touch blue at night; fear pulls the colour out further.
    grade["$pp_colour_addb"] = Lerp( dawn, 0.012, 0 )
    grade["$pp_colour_brightness"] = Lerp( dawn, -0.02, 0 ) - fear * 0.02
    grade["$pp_colour_contrast"] = 1.04 + fear * 0.08
    grade["$pp_colour_colour"] = Lerp( dawn, 0.62, 0.9 ) - fear * 0.25

    DrawColorModify( grade )
end )

--[[ Heartbeat and chase music ]]

local nextBeat = 0
local chase = { channel = nil, loading = false, volume = 0, path = nil }

local function stopChase()
    if IsValid( chase.channel ) then
        chase.channel:Stop()
    end

    chase.channel = nil
    chase.loading = false
    chase.volume = 0
end

local function updateChase( wanted, dt )
    local path = string.Trim( HH.CV.chase_music:GetString() )
    if path ~= chase.path then
        stopChase()
        chase.path = path
    end
    if path == "" or not file.Exists( "sound/" .. path, "GAME" ) then return end

    local target = wanted and 1 or 0
    chase.volume = math.Approach( chase.volume, target, CHASE_FADE_SPEED * dt )

    if chase.volume > 0 and not IsValid( chase.channel ) and not chase.loading then
        chase.loading = true

        sound.PlayFile( "sound/" .. path, "noblock", function( channel )
            chase.loading = false
            if not IsValid( channel ) then return end
            if chase.path ~= path or chase.volume <= 0 then
                channel:Stop()
                return
            end

            channel:EnableLooping( true )
            channel:SetVolume( chase.volume )
            chase.channel = channel
        end )
    end

    if IsValid( chase.channel ) then
        chase.channel:SetVolume( chase.volume )

        if chase.volume <= 0 then
            stopChase()
        end
    end
end

local function measureFear( ply )
    local killer = GetGlobal2Entity( "HH_Killer" )
    if not IsValid( killer ) or killer:IsDormant() then return 0 end

    local eye = ply:EyePos()
    local center = killer:WorldSpaceCenter()
    local dist = eye:Distance( center )
    if dist >= HEARTBEAT_RANGE then return 0 end

    local tr = util.TraceLine( { start = eye, endpos = center, mask = MASK_BLOCKLOS, filter = ply } )
    local closeness = 1 - dist / HEARTBEAT_RANGE

    return tr.Hit and closeness * HIDDEN_KILLER_FACTOR or closeness
end

--[[ Glimpses: a stand-in of the killer, seen by one survivor, gone when they look properly ]]

local sighting
local sightColor = Color( 255, 255, 255, 255 )

local function removeSighting()
    if sighting and IsValid( sighting.ent ) then
        sighting.ent:Remove()
    end

    sighting = nil
end

local function applyLook( ent, look )
    if not look then return end

    ent:SetSkin( look.skin or 0 )
    for i, value in ipairs( look.bodygroups or {} ) do
        ent:SetBodygroup( i - 1, value )
    end
end

function HH.Cl.PickIdleSequence( ent )
    local seq = ent:SelectWeightedSequence( ACT_IDLE )
    if seq and seq >= 0 then return seq end

    for _, name in ipairs( { "idle", "idle01", "idle1", "Idle01", "idle_all_01" } ) do
        seq = ent:LookupSequence( name )
        if seq and seq >= 0 then return seq end
    end

    return 0
end

net.Receive( "HH_Sight", function()
    local pos = net.ReadVector()
    local yaw = net.ReadFloat()

    local look = HH.KillerLook
    local model = look and look.model or GetGlobal2String( "HH_KillerModel", "" )
    if model == "" or not file.Exists( model, "GAME" ) then return end

    removeSighting()

    local ent = ClientsideModel( model, RENDERGROUP_TRANSLUCENT )
    if not IsValid( ent ) then return end

    ent:SetPos( pos )
    ent:SetAngles( Angle( 0, yaw, 0 ) )
    applyLook( ent, look )
    ent:SetRenderMode( RENDERMODE_TRANSCOLOR )
    ent:ResetSequence( HH.Cl.PickIdleSequence( ent ) )

    sighting = { ent = ent, born = CurTime(), staredFor = 0, fadeStart = nil, wasStared = false }
end )

local function thinkSighting( ply, dt )
    if not sighting then return end

    local ent = sighting.ent
    if not IsValid( ent ) or HH.GetPhase() ~= HH.PHASE_NIGHT then
        removeSighting()
        return
    end

    ent:SetCycle( ( CurTime() * 0.25 ) % 1 )
    ent:SetEyeTarget( ply:EyePos() )

    if not sighting.fadeStart then
        local head = ent:GetPos() + Vector( 0, 0, 60 )
        local eye = ply:EyePos()
        local dir = ( head - eye ):GetNormalized()
        local staring = ply:GetAimVector():Dot( dir ) > SIGHT_STARE_DOT

        sighting.staredFor = staring and sighting.staredFor + dt or 0

        local tooClose = eye:Distance( head ) < SIGHT_TOO_CLOSE
        local tooOld = CurTime() - sighting.born > SIGHT_LIFETIME

        if sighting.staredFor > SIGHT_STARE_TIME or tooClose or tooOld then
            sighting.fadeStart = CurTime()
            sighting.wasStared = sighting.staredFor > SIGHT_STARE_TIME or tooClose
        end
    end

    local alpha = 255
    if sighting.fadeStart then
        alpha = 255 * ( 1 - ( CurTime() - sighting.fadeStart ) / SIGHT_FADE_TIME )

        if alpha <= 0 then
            if sighting.wasStared then
                HH.PlayFlat( HH.Sounds.stinger, 0.35, 70 )
            end
            removeSighting()
            return
        end
    end

    sightColor.a = alpha
    ent:SetColor( sightColor )
end

--[[ Footsteps behind you ]]

local function phantomSteps()
    local steps = math.random( 3, 5 )
    local stepSound = HH.RandomSound( HH.Sounds.footsteps )
    if not stepSound then return end

    for i = 1, steps do
        timer.Simple( i * PHANTOM_STEP_GAP, function()
            local ply = LocalPlayer()
            if not IsValid( ply ) or HH.GetPhase() ~= HH.PHASE_NIGHT then return end

            local back = -ply:GetAimVector()
            back.z = 0
            back:Normalize()

            local pos = ply:GetPos() + back * ( PHANTOM_START_DIST - i * PHANTOM_STEP_CLOSER ) + Vector( 0, 0, 4 )
            sound.Play( stepSound, pos, 72, math.random( 92, 104 ), 0.85 )
        end )
    end
end

--[[ Cues from the server ]]

HH.Cl.EncounterAt = 0
HH.Cl.BlinkUntil = 0

net.Receive( "HH_Cue", function()
    local id = net.ReadUInt( 4 )
    local pos = net.ReadVector()

    if id == HH.CUE_SIEGE then
        HH.PlayFlat( HH.Sounds.distantScream, 0.3, math.random( 80, 92 ) )
        HH.Flicker.untilTime = CurTime() + FLICKER_SIEGE
    elseif id == HH.CUE_ENCOUNTER then
        HH.PlayFlat( HH.Sounds.stinger, 0.9, 90 )
        HH.Cl.EncounterAt = CurTime()
        util.ScreenShake( LocalPlayer():GetPos(), 3, 15, 0.6, 100 )
    elseif id == HH.CUE_BLINK then
        HH.Cl.BlinkUntil = CurTime() + 0.18
    elseif id == HH.CUE_PHANTOM then
        phantomSteps()
    elseif id == HH.CUE_POWER then
        HH.PlayFlat( HH.Sounds.powerOn, 0.6 )
        HH.Flicker.untilTime = CurTime() + FLICKER_POWER
        if HH.ShowMessage then
            HH.ShowMessage( "The lights are on.", 4 )
        end
    elseif id == HH.CUE_RETREAT then
        if HH.ShowMessage and LocalPlayer():GetPos():Distance( pos ) < 2500 then
            HH.ShowMessage( "It slips back into the dark. For now.", 4 )
        end
    end
end )

--[[ Per-frame ]]

local nextAmbient = 0
local lastThink = CurTime()

hook.Add( "Think", "HorrorHelper_Atmosphere", function()
    local now = CurTime()
    local dt = math.Clamp( now - lastThink, 0, 0.25 )
    lastThink = now

    local ply = LocalPlayer()
    if not IsValid( ply ) then return end

    if HH.GetPhase() ~= HH.PHASE_NIGHT then
        fear = 0
        stopChase()
        removeSighting()
        return
    end

    thinkSighting( ply, dt )

    local alive = ply:Alive() and not HH.IsOut( ply )
    local target = alive and measureFear( ply ) or 0
    fear = math.Approach( fear, target, dt * 1.5 )

    if fear > 0.05 and now >= nextBeat then
        HH.PlayFlat( HH.Sounds.heartbeat, Lerp( fear, 0.35, 1 ) )
        nextBeat = now + Lerp( fear, HEARTBEAT_SLOW, HEARTBEAT_FAST )
    end

    updateChase( fear > CHASE_THRESHOLD, dt )

    if now >= nextAmbient then
        nextAmbient = now + math.Rand( AMBIENT_MIN_GAP, AMBIENT_MAX_GAP )

        local path = HH.RandomSound( HH.Sounds.ambience )
        if path then
            local offset = Angle( 0, math.Rand( 0, 360 ), 0 ):Forward() * math.Rand( AMBIENT_MIN_DIST, AMBIENT_MAX_DIST )
            sound.Play( path, ply:GetPos() + offset + Vector( 0, 0, 64 ), 75, math.random( 90, 105 ), 0.5 )
        end
    end
end )
