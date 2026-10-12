--[[
    The opening film. One continuous take, about 14 seconds:

      Behind it.   Over the killer's shoulder, out in the dark, looking where it looks:
                   towards the cabin you're about to hide in.
      Round it.    The camera swings round its side and drops low, the gaze giving way to
                   the killer itself.
      Its face.    A slow push in from below with a slight Dutch tilt. Lightning. Its name
                   types in, "SURVIVE UNTIL SUNRISE" under it. Fade to black.

    Night starts out of the black, in your own eyes at the cabin. The fade is a cut on
    purpose: the cabin is far from where the killer stands, so no camera move could get
    there without giving away the map.

    The killer is a clientside stand-in (same model, skin and bodygroups as the real NPC),
    so the shot can't be ruined by AI wandering off.
]]

local HH = HorrorHelper

local K = {
    FADE_IN = 1.2,
    BEHIND_END = 4.5, -- over the shoulder until here...
    ORBIT_END = 9.0, -- ...swinging round to the front until here...
    PUSH_END = 12.6, -- ...pushing in on the face until here
    FADE_OUT_START = 12.4,
    FADE_OUT_END = 13.4,
    THUNDER_AT = 9.3,
    TITLE_AT = 9.6,
    SUBTITLE_AT = 10.7,
    TYPE_SPEED = 16, -- letters per second

    SHOULDER_ANGLE = 160, -- 180 is straight behind; a little off so its shoulder frames the shot
    FRONT_ANGLE = 24, -- where the orbit ends: just off its nose, a three-quarter view
    FACE_ANGLE = 8,
    BEHIND_RADIUS_START = 175,
    BEHIND_RADIUS_END = 130,
    FRONT_RADIUS = 95,
    FACE_RADIUS = 44,
    BEHIND_HEIGHT = 10, -- relative to its eyes
    FRONT_HEIGHT = -40, -- low: looking up at it
    FACE_HEIGHT = -12,
    GAZE_DISTANCE = 900, -- how far ahead its gaze point sits (towards the cabin)
    GAZE_DROP = 30,
    FOV_WIDE = 62,
    FOV_FRONT = 54,
    FOV_FACE = 34,
    FACE_ROLL = -5, -- Dutch tilt on the close-up
    CAMERA_HULL = 6,

    HANDHELD_POS = 0.6, -- units of positional sway
    HANDHELD_ANG = 0.35, -- degrees of wobble at 60 fov (scaled by fov)

    KEY_LIGHT_ID = 0x4848, -- a cold key light on the killer so it reads in the dark
    KEY_LIGHT_SIZE = 260,
    KEY_LIGHT_BRIGHTNESS = 0.9,
    -- A road flare burning in the grass by its feet: red light thrown up across it, on the
    -- side the camera swings round, so it reads in the dark.
    FLARE_LIGHT_ID = 0x484A,
    FLARE_FORWARD = 50, -- in front of it...
    FLARE_SIDE = 45, -- ...off to the camera's side...
    FLARE_HEIGHT = 8, -- ...lying on the ground
    FLARE_LIGHT_LIFT = 18, -- the light itself sits a little above the flare
    FLARE_SIZE = 380,
    FLARE_BRIGHTNESS = 2.4,
    FLARE_FLICKER = 0.18, -- how much it gutters (share of brightness)
    FLARE_SPRITE_SIZE = 26,
    FLASH_LIGHT_ID = 0x4849,
    FLASH_LIGHT_SIZE = 1400,
    FLASH_BRIGHTNESS = 5,
    FLASH_DECAY_TIME = 0.6,
    SCREEN_FLASH_TIME = 0.25,

    BAR_FRACTION = 0.11, -- letterbox bar height as a share of the screen
    BAR_EASE_TIME = 1.5,
}

local film

local function easeInOut( frac )
    return math.EaseInOut( math.Clamp( frac, 0, 1 ), 0.35, 0.35 )
end

local function stopFilm()
    if film and IsValid( film.puppet ) then
        film.puppet:Remove()
    end

    film = nil
end

local function sceneTime()
    return CurTime() - film.start
end

--[[ The camera path, as one function of time ]]

-- Where the camera wants to be (before clipping) and what it looks at.
local function cameraPlan( t, side )
    local head = film.head
    local yaw = film.yaw
    local gaze = head + Angle( 0, yaw, 0 ):Forward() * K.GAZE_DISTANCE - Vector( 0, 0, K.GAZE_DROP )

    local theta, radius, height, look, fov, roll

    if t < K.BEHIND_END then
        local f = easeInOut( t / K.BEHIND_END )
        theta = K.SHOULDER_ANGLE
        radius = Lerp( f, K.BEHIND_RADIUS_START, K.BEHIND_RADIUS_END )
        height = K.BEHIND_HEIGHT
        look = gaze
        fov = K.FOV_WIDE
        roll = 0
    elseif t < K.ORBIT_END then
        local f = easeInOut( ( t - K.BEHIND_END ) / ( K.ORBIT_END - K.BEHIND_END ) )
        theta = Lerp( f, K.SHOULDER_ANGLE, K.FRONT_ANGLE )
        radius = Lerp( f, K.BEHIND_RADIUS_END, K.FRONT_RADIUS )
        height = Lerp( f, K.BEHIND_HEIGHT, K.FRONT_HEIGHT )
        look = LerpVector( f, gaze, head )
        fov = Lerp( f, K.FOV_WIDE, K.FOV_FRONT )
        roll = 0
    else
        local f = easeInOut( ( t - K.ORBIT_END ) / ( K.PUSH_END - K.ORBIT_END ) )
        theta = Lerp( f, K.FRONT_ANGLE, K.FACE_ANGLE )
        radius = Lerp( f, K.FRONT_RADIUS, K.FACE_RADIUS )
        height = Lerp( f, K.FRONT_HEIGHT, K.FACE_HEIGHT )
        look = head
        fov = Lerp( f, K.FOV_FRONT, K.FOV_FACE )
        roll = Lerp( f, 0, K.FACE_ROLL )
    end

    local dir = Angle( 0, yaw + theta * side, 0 ):Forward()
    local pos = head + dir * radius + Vector( 0, 0, height )

    return pos, look, fov, roll
end

-- Built outward from the subject: trace from its head to where the camera wants to be and
-- stop short of anything in the way, so it is never filmed through a wall.
local function clipFromSubject( pos )
    local hull = Vector( K.CAMERA_HULL, K.CAMERA_HULL, K.CAMERA_HULL )
    local tr = util.TraceHull( {
        start = film.head,
        endpos = pos,
        mins = -hull,
        maxs = hull,
        mask = MASK_SOLID,
        filter = function( ent ) return not ent:IsPlayer() end,
    } )

    return tr.HitPos, tr.Fraction
end

-- Swing round its left or its right: whichever side has more room. Chosen once.
local function chooseSide()
    local samples = { 1, 3, 5.5, 7, 8.5, 10.5, 12 }
    local best, bestScore = 1, -1

    for _, side in ipairs( { 1, -1 } ) do
        local score = 0
        for _, t in ipairs( samples ) do
            local pos = cameraPlan( t, side )
            local _, fraction = clipFromSubject( pos )
            score = score + fraction
        end

        if score > bestScore then
            best, bestScore = side, score
        end
    end

    return best
end

local function findHead( puppet )
    puppet:SetupBones()

    local attachment = puppet:LookupAttachment( "eyes" )
    if attachment and attachment > 0 then
        local data = puppet:GetAttachment( attachment )
        if data then return data.Pos end
    end

    local bone = puppet:LookupBone( "ValveBiped.Bip01_Head1" )
    if bone then
        local pos = puppet:GetBonePosition( bone )
        if pos then return pos + Vector( 0, 0, 4 ) end
    end

    return puppet:GetPos() + Vector( 0, 0, puppet:OBBMaxs().z * 0.9 )
end

--[[ Starting the film ]]

net.Receive( "HH_Intro", function()
    local start = net.ReadDouble()
    local pos = net.ReadVector()
    local yaw = net.ReadFloat()
    local cabin = net.ReadVector()
    local model = net.ReadString()
    local skin = net.ReadUInt( 8 )
    local groupCount = net.ReadUInt( 6 )
    local bodygroups = {}
    for i = 1, groupCount do
        bodygroups[i] = net.ReadUInt( 8 )
    end
    local name = net.ReadString()

    HH.KillerLook = { model = model, skin = skin, bodygroups = bodygroups }

    stopFilm()
    film = {
        start = start,
        pos = pos,
        yaw = yaw,
        cabin = cabin,
        name = string.upper( name ),
        fired = {},
    }

    if model ~= "" and file.Exists( model, "GAME" ) then
        local puppet = ClientsideModel( model )
        if IsValid( puppet ) then
            puppet:SetPos( pos )
            puppet:SetAngles( Angle( 0, yaw, 0 ) )
            puppet:SetSkin( skin )
            for i, value in ipairs( bodygroups ) do
                puppet:SetBodygroup( i - 1, value )
            end

            local seq = HH.Cl.PickIdleSequence( puppet )
            puppet:ResetSequence( seq )
            film.puppet = puppet
            film.seqLength = math.max( puppet:SequenceDuration( seq ), 0.5 )
        end
    end
end )

--[[ Per frame: the stand-in, the lights, the cues ]]

local function fireOnce( key, t, at, fn )
    if film.fired[key] or t < at then return end

    film.fired[key] = true
    -- Joined late or hitched past it by more than a second: skip rather than fire stale.
    if t - at < 1 then fn() end
end

hook.Add( "Think", "HorrorHelper_Intro", function()
    if not film then return end

    local t = sceneTime()
    if t > HH.INTRO_LENGTH or ( t > 1 and HH.GetPhase() ~= HH.PHASE_INTRO ) then
        stopFilm()
        return
    end

    local puppet = film.puppet
    if not IsValid( puppet ) then return end

    if not film.head then
        film.head = findHead( puppet )
        film.side = chooseSide()
    end

    -- The flare gutters: a few uneven sines, the same on every screen.
    film.flareFlicker = 1 - K.FLARE_FLICKER * ( 0.5 + 0.3 * math.sin( t * 23 ) + 0.2 * math.sin( t * 37 + 1.3 ) )

    puppet:SetCycle( ( math.max( t, 0 ) / film.seqLength ) % 1 )
    puppet:InvalidateBoneCache()

    -- It stares down the cabin, then, once the camera is in front of it, straight down the lens.
    local eyesOnLens = t > K.ORBIT_END - 1 and film.camPos
    puppet:SetEyeTarget( eyesOnLens and film.camPos or film.head + Angle( 0, film.yaw, 0 ):Forward() * 500 )

    local fwd = Angle( 0, film.yaw, 0 ):Forward()
    local key = DynamicLight( K.KEY_LIGHT_ID )
    if key then
        key.pos = film.head + fwd * 70 + Vector( 0, 0, 30 )
        key.r, key.g, key.b = 120, 140, 200
        key.brightness = K.KEY_LIGHT_BRIGHTNESS
        key.size = K.KEY_LIGHT_SIZE
        key.decay = 1000
        key.dietime = CurTime() + 0.1
    end

    local flarePos = film.flarePos
    if not flarePos then
        local side = Angle( 0, film.yaw + 90 * film.side, 0 ):Forward()
        flarePos = film.pos + fwd * K.FLARE_FORWARD + side * K.FLARE_SIDE + Vector( 0, 0, K.FLARE_HEIGHT )
        film.flarePos = flarePos
    end

    local flare = DynamicLight( K.FLARE_LIGHT_ID )
    if flare then
        flare.pos = flarePos + Vector( 0, 0, K.FLARE_LIGHT_LIFT )
        flare.r, flare.g, flare.b = 255, 30, 20
        flare.brightness = K.FLARE_BRIGHTNESS * film.flareFlicker
        flare.size = K.FLARE_SIZE
        flare.decay = 1000
        flare.dietime = CurTime() + 0.1
    end

    local sinceFlash = t - K.THUNDER_AT
    if sinceFlash >= 0 and sinceFlash < K.FLASH_DECAY_TIME then
        local flash = DynamicLight( K.FLASH_LIGHT_ID )
        if flash then
            flash.pos = film.head + fwd * 220 + Vector( 0, 0, 320 )
            flash.r, flash.g, flash.b = 200, 215, 255
            flash.brightness = K.FLASH_BRIGHTNESS * ( 1 - sinceFlash / K.FLASH_DECAY_TIME )
            flash.size = K.FLASH_LIGHT_SIZE
            flash.decay = 4000
            flash.dietime = CurTime() + 0.1
        end
    end

    fireOnce( "thunder", t, K.THUNDER_AT, function()
        HH.PlayFlat( HH.Sounds.thunder, 0.8, math.random( 90, 100 ) )
    end )
end )

-- The flare itself: a hot core and a red bloom, so the light has a source on screen.
local flareGlow = Material( "sprites/light_glow02_add" )
local flareColor = Color( 255, 40, 25 )
local flareCore = Color( 255, 200, 170 )

hook.Add( "PostDrawTranslucentRenderables", "HorrorHelper_IntroFlare", function( _, drawingSkybox )
    if drawingSkybox or not film or not film.flarePos then return end

    local size = K.FLARE_SPRITE_SIZE * film.flareFlicker
    flareColor.a = 220 * film.flareFlicker
    render.SetMaterial( flareGlow )
    render.DrawSprite( film.flarePos, size * 3, size * 3, flareColor )
    render.DrawSprite( film.flarePos, size * 0.6, size * 0.6, flareCore )
end )

--[[ The camera ]]

local function handheld( t, fov )
    local scale = fov / 60
    local swayPos = Vector(
        math.sin( t * 0.9 ) + math.sin( t * 2.3 ) * 0.4,
        math.sin( t * 1.1 + 1.7 ) + math.sin( t * 2.9 ) * 0.3,
        math.sin( t * 0.7 + 0.4 ) * 0.6
    ) * K.HANDHELD_POS
    local swayAng = Angle(
        math.sin( t * 1.3 + 0.2 ) * K.HANDHELD_ANG * scale,
        math.sin( t * 0.8 + 2.1 ) * K.HANDHELD_ANG * scale,
        0
    )

    return swayPos, swayAng
end

hook.Add( "CalcView", "HorrorHelper_Intro", function()
    if not film or not film.head then return end

    local t = math.max( sceneTime(), 0 )
    local wanted, look, fov, roll = cameraPlan( t, film.side )
    local pos = clipFromSubject( wanted )
    local swayPos, swayAng = handheld( t, fov )
    pos = pos + swayPos

    local ang = ( look - pos ):Angle()
    ang.r = roll
    ang = ang + swayAng
    film.camPos = pos

    return {
        origin = pos,
        angles = ang,
        fov = fov,
        drawviewer = false,
    }
end )

hook.Add( "InputMouseApply", "HorrorHelper_Intro", function( cmd, _, _, ang )
    if HH.GetPhase() ~= HH.PHASE_INTRO then return end

    -- The mouse sits the film out.
    cmd:SetViewAngles( ang )

    return true
end )

hook.Add( "PreDrawViewModel", "HorrorHelper_Intro", function()
    if film then return true end
end )

local KEEP_HUD = { CHudGMod = true, CHudChat = true }

hook.Add( "HUDShouldDraw", "HorrorHelper_Intro", function( name )
    if HH.GetPhase() == HH.PHASE_INTRO and not KEEP_HUD[name] then return false end
end )

--[[ Bars, title card, fades ]]

local titleColor = Color( 235, 228, 215 )
local subColor = Color( 170, 24, 24 )

hook.Add( "HUDPaint", "HorrorHelper_Intro", function()
    if HH.GetPhase() ~= HH.PHASE_INTRO then return end

    local w, h = ScrW(), ScrH()

    if not film or not IsValid( film.puppet ) then
        -- No stand-in (model missing): a black card with the name is still an introduction.
        surface.SetDrawColor( 0, 0, 0, 255 )
        surface.DrawRect( 0, 0, w, h )
        if film then
            film.titleFont = film.titleFont or ( HH.UI.TextWidth( "HH_Title", film.name ) > w * 0.84 and "HH_Big" or "HH_Title" )
            HH.ShadowText( film.name, film.titleFont, w * 0.5, h * 0.45, titleColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
            HH.ShadowText( "SURVIVE UNTIL SUNRISE", "HH_Small", w * 0.5, h * 0.55, subColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
        end
        return
    end

    local t = sceneTime()

    local barIn = math.Clamp( t / K.BAR_EASE_TIME, 0, 1 )
    local barH = h * K.BAR_FRACTION * easeInOut( barIn )
    surface.SetDrawColor( 0, 0, 0, 255 )
    surface.DrawRect( 0, 0, w, barH )
    surface.DrawRect( 0, h - barH, w, barH )

    if t >= K.TITLE_AT then
        local letters = math.floor( ( t - K.TITLE_AT ) * K.TYPE_SPEED )
        local shown = string.sub( film.name, 1, letters )
        local x, y = w * 0.08, h * 0.66
        -- A long name drops to the smaller title size rather than running off screen.
        film.titleFont = film.titleFont or ( HH.UI.TextWidth( "HH_Title", film.name ) > w * 0.84 and "HH_Big" or "HH_Title" )

        HH.ShadowText( shown, film.titleFont, x, y, titleColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM )

        if t >= K.SUBTITLE_AT then
            local a = math.Clamp( ( t - K.SUBTITLE_AT ) / 0.6, 0, 1 )
            surface.SetDrawColor( subColor.r, subColor.g, subColor.b, 255 * a )
            surface.DrawRect( x, y + h * 0.01, w * 0.22 * a, 2 )
            HH.ShadowText( "SURVIVE UNTIL SUNRISE", "HH_Small", x, y + h * 0.02, HH.UI.Alpha( "introSub", subColor, 255 * a ), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
        end
    end

    local sinceFlash = t - K.THUNDER_AT
    if sinceFlash >= 0 and sinceFlash < K.SCREEN_FLASH_TIME then
        surface.SetDrawColor( 220, 230, 255, 160 * ( 1 - sinceFlash / K.SCREEN_FLASH_TIME ) )
        surface.DrawRect( 0, 0, w, h )
    end

    local black = 0
    if t < K.FADE_IN then
        black = 1 - math.max( t, 0 ) / K.FADE_IN
    elseif t > K.FADE_OUT_START then
        black = math.Clamp( ( t - K.FADE_OUT_START ) / ( K.FADE_OUT_END - K.FADE_OUT_START ), 0, 1 )
    end

    if black > 0 then
        surface.SetDrawColor( 0, 0, 0, 255 * black )
        surface.DrawRect( 0, 0, w, h )
    end
end )
