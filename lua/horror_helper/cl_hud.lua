-- Fonts, the night HUD (time to sunrise, objectives, what you carry, what E does),
-- short messages, the spectator note, and the result screen.

local HH = HorrorHelper

local PALETTE = {
    text = Color( 228, 222, 210 ),
    dim = Color( 150, 144, 136 ),
    faint = Color( 150, 144, 136, 90 ),
    blood = Color( 170, 24, 24 ),
    panel = Color( 6, 6, 8, 170 ),
    shadow = Color( 0, 0, 0, 200 ),
    good = Color( 230, 200, 120 ),
}
HH.PALETTE = PALETTE

local HINT_REACH = 110
local NIGHT_FADE_IN = 2
local ENCOUNTER_FLASH = 1.6
local MESSAGE_FADE = 0.6

local function createFonts()
    local scale = ScrH() / 1080

    surface.CreateFont( "HH_Title", { font = "Roboto", size = math.Round( 110 * scale ), weight = 900, extended = true } )
    surface.CreateFont( "HH_Big", { font = "Roboto", size = math.Round( 54 * scale ), weight = 800, extended = true } )
    surface.CreateFont( "HH_Med", { font = "Roboto", size = math.Round( 28 * scale ), weight = 600, extended = true } )
    surface.CreateFont( "HH_Small", { font = "Roboto", size = math.Round( 20 * scale ), weight = 500, extended = true } )
    surface.CreateFont( "HH_Tiny", { font = "Roboto", size = math.Round( 16 * scale ), weight = 500, extended = true } )
    surface.CreateFont( "HH_World", { font = "Roboto", size = 40, weight = 700, extended = true } )
end

createFonts()
hook.Add( "OnScreenSizeChanged", "HorrorHelper_Fonts", createFonts )

function HH.ShadowText( text, font, x, y, color, alignX, alignY )
    draw.SimpleText( text, font, x + 2, y + 2, PALETTE.shadow, alignX, alignY )
    draw.SimpleText( text, font, x, y, color, alignX, alignY )
end

local function formatTime( seconds )
    seconds = math.max( 0, math.floor( seconds ) )

    return string.format( "%d:%02d", math.floor( seconds / 60 ), seconds % 60 )
end
HH.FormatTime = formatTime

--[[ Messages ]]

local message = { text = "", untilTime = 0, start = 0 }

function HH.ShowMessage( text, duration )
    message.text = text
    message.start = CurTime()
    message.untilTime = CurTime() + ( duration or 3 )
end

local function drawMessage( w, h )
    local now = CurTime()
    if now >= message.untilTime then return end

    local alpha = math.min( 1, ( now - message.start ) / MESSAGE_FADE, ( message.untilTime - now ) / MESSAGE_FADE )
    local col = ColorAlpha( PALETTE.text, 255 * alpha )

    HH.ShadowText( message.text, "HH_Med", w * 0.5, h * 0.72, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
end

--[[ Objectives ]]

local STAGE_HEADINGS = {
    [HH.STAGE_REGROUP] = function() return "FIND THE OTHERS" end,
    [HH.STAGE_TO_CABIN] = function() return "GET TO " .. string.upper( GetGlobal2String( "HH_CabinName", "the cabin" ) ) end,
}

local function drawBar( x, y, w, h, frac, color )
    surface.SetDrawColor( 255, 255, 255, 18 )
    surface.DrawRect( x, y, w, h )
    surface.SetDrawColor( color.r, color.g, color.b, 220 )
    surface.DrawRect( x, y, math.floor( w * math.Clamp( frac, 0, 1 ) ), h )
end

local function drawObjectives( ply, w, h )
    local pad = math.Round( h * 0.022 )
    local boxW = math.Round( h * 0.3 )
    local x, y = pad, pad
    local lineH = math.Round( h * 0.032 )
    local barH = math.max( 3, math.Round( h * 0.005 ) )

    local fusesIn = GetGlobal2Int( "HH_FusesIn", 0 )
    local fusesNeeded = GetGlobal2Int( "HH_FusesNeeded", 0 )
    local boards = GetGlobal2Int( "HH_Boards", 0 )
    local boardsMax = GetGlobal2Int( "HH_BoardsMax", 0 )
    local powered = GetGlobal2Bool( "HH_Power", false )

    local stage = HH.GetStage()
    local preparing = stage == HH.STAGE_PREPARE
    local heading = STAGE_HEADINGS[stage]

    local rows = 1
    if heading then rows = rows + 1 end
    if preparing and fusesNeeded > 0 then rows = rows + 1 end
    if preparing and boardsMax > 0 then rows = rows + 1 end

    draw.RoundedBox( 4, x, y, boxW, pad + rows * lineH * 1.45, PALETTE.panel )

    local cx = x + pad * 0.7
    local cy = y + pad * 0.6

    if heading then
        draw.SimpleText( heading(), "HH_Small", cx, cy, PALETTE.blood )
        cy = cy + lineH * 1.45
    end

    if preparing and fusesNeeded > 0 then
        local cut = CurTime() < GetGlobal2Float( "HH_PowerCutUntil", 0 )
        local label = powered and ( cut and "POWER  OUT" or "POWER  ON" ) or string.format( "POWER  %d / %d fuses", fusesIn, fusesNeeded )
        draw.SimpleText( label, "HH_Small", cx, cy, powered and PALETTE.good or PALETTE.text )
        drawBar( cx, cy + lineH, boxW - pad * 1.4, barH, fusesIn / fusesNeeded, powered and PALETTE.good or PALETTE.blood )
        cy = cy + lineH * 1.45
    end

    if preparing and boardsMax > 0 then
        draw.SimpleText( string.format( "BARRICADES  %d / %d boards", boards, boardsMax ), "HH_Small", cx, cy, PALETTE.text )
        drawBar( cx, cy + lineH, boxW - pad * 1.4, barH, boards / boardsMax, PALETTE.blood )
        cy = cy + lineH * 1.45
    end

    local fuses = ply:GetNW2Int( "HH_Fuses", 0 )
    local planks = ply:GetNW2Int( "HH_Planks", 0 )
    local carry = string.format( "CARRYING  %d fuse%s  ·  %d plank%s", fuses, fuses == 1 and "" or "s", planks, planks == 1 and "" or "s" )
    draw.SimpleText( carry, "HH_Small", cx, cy, PALETTE.dim )
end

local function drawClock( w, h )
    local remaining = GetGlobal2Float( "HH_PhaseEnd", 0 ) - CurTime()
    local text = formatTime( remaining ) .. "  UNTIL SUNRISE"

    HH.ShadowText( text, "HH_Small", w * 0.5, h * 0.025, PALETTE.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP )
end

--[[ Things in the world: the cabin once it's revealed, voices you heard ]]

local UNITS_TO_METERS = 0.01905
local EDGE_MARGIN = 0.08 -- off-screen markers sit this far in from the screen edge

-- Where on screen a world position is, pinned to the edge when it's off screen or behind you.
local function screenPoint( pos, w, h )
    local scr = pos:ToScreen()
    local margin = h * EDGE_MARGIN
    if scr.visible and scr.x > margin and scr.x < w - margin and scr.y > margin and scr.y < h - margin then
        return scr.x, scr.y, true
    end

    local dir = pos - EyePos()
    local ang = EyeAngles()
    local right = dir:Dot( ang:Right() )
    local up = dir:Dot( ang:Up() )
    local theta = math.atan2( -up, right )

    return w * 0.5 + math.cos( theta ) * ( w * 0.5 - margin ), h * 0.5 + math.sin( theta ) * ( h * 0.5 - margin ), false
end

local function drawDiamond( x, y, size, color )
    surface.SetDrawColor( color.r, color.g, color.b, color.a )
    draw.NoTexture()
    surface.DrawPoly( {
        { x = x, y = y - size },
        { x = x + size, y = y },
        { x = x, y = y + size },
        { x = x - size, y = y },
    } )
end

local markerColor = Color( 0, 0, 0 )

local function drawCabinMarker( ply, w, h )
    local stage = HH.GetStage()
    if stage ~= HH.STAGE_TO_CABIN and stage ~= HH.STAGE_PREPARE then return end

    local center = GetGlobal2Vector( "HH_CabinCenter", vector_origin )
    local dist = ply:GetPos():Distance( center )
    -- Once you're set up there, it's only shown while you're away from it.
    if stage == HH.STAGE_PREPARE and dist < GetGlobal2Float( "HH_CabinRadius", 600 ) then return end

    local x, y = screenPoint( center + Vector( 0, 0, 72 ), w, h )
    local alpha = stage == HH.STAGE_TO_CABIN and 230 or 120
    local col = PALETTE.good
    markerColor.r, markerColor.g, markerColor.b, markerColor.a = col.r, col.g, col.b, alpha

    drawDiamond( x, y, h * 0.008, markerColor )
    local label = string.format( "%s  %dm", GetGlobal2String( "HH_CabinName", "Cabin" ), math.Round( dist * UNITS_TO_METERS ) )
    HH.ShadowText( label, "HH_Tiny", x, y + h * 0.014, markerColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP )
end

local function drawCalls( w, h )
    local calls, showTime = HH.Cl.ActiveCalls()

    for _, call in ipairs( calls ) do
        local fade = 1 - ( CurTime() - call.at ) / showTime
        local x, y = screenPoint( call.pos, w, h )
        local col = ColorAlpha( PALETTE.text, 200 * fade )

        HH.ShadowText( call.name .. "  calling out", "HH_Small", x, y, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    end
end

-- The edges of the world close in as dread rises.
local gradients = {
    l = Material( "vgui/gradient-l" ),
    r = Material( "vgui/gradient-r" ),
    u = Material( "vgui/gradient-u" ),
    d = Material( "vgui/gradient-d" ),
}
local VIGNETTE_MAX_ALPHA = 210

local function drawVignette( w, h )
    local dread = HH.GetDread() * ( 1 - HH.DawnFraction() )
    if dread <= 0.05 then return end

    local alpha = VIGNETTE_MAX_ALPHA * dread
    local side = w * Lerp( dread, 0.08, 0.22 )
    local band = h * Lerp( dread, 0.08, 0.22 )

    surface.SetDrawColor( 0, 0, 0, alpha )
    surface.SetMaterial( gradients.l )
    surface.DrawTexturedRect( 0, 0, side, h )
    surface.SetMaterial( gradients.r )
    surface.DrawTexturedRect( w - side, 0, side, h )
    surface.SetMaterial( gradients.u )
    surface.DrawTexturedRect( 0, 0, w, band )
    surface.SetMaterial( gradients.d )
    surface.DrawTexturedRect( 0, h - band, w, band )
end

--[[ What pressing E would do ]]

local function hintFor( ply )
    local tr = ply:GetEyeTrace()
    local ent = tr.Entity

    if IsValid( ent ) and tr.HitPos:Distance( ply:EyePos() ) < HINT_REACH then
        local class = ent:GetClass()

        if class == "hh_fuse" then return "[E]  Take the fuse" end
        if class == "hh_planks" then return "[E]  Take the plank" end
        if class == "hh_fusebox" then
            if ent:GetFuses() >= ent:GetNeeded() then return "Fuse box full" end
            if ply:GetNW2Int( "HH_Fuses", 0 ) > 0 then return "[E]  Put the fuses in" end

            return string.format( "Fuse box  %d / %d  (find fuses)", ent:GetFuses(), ent:GetNeeded() )
        end
    end

    local barricade = HH.FindAimedBarricade( ply )
    if IsValid( barricade ) then
        local boards = barricade:GetBoards()
        if boards >= barricade.MaxBoards then return "Boarded up" end
        if ply:GetNW2Int( "HH_Planks", 0 ) > 0 then return "[E]  Nail a plank  (" .. boards .. " / " .. barricade.MaxBoards .. ")" end

        return "Needs planks  (" .. boards .. " / " .. barricade.MaxBoards .. ")"
    end

    return nil
end

--[[ Result screen ]]

local OUTCOME_TEXT = {
    [HH.OUTCOME_SURVIVED] = { "SUNRISE", "You made it through the night." },
    [HH.OUTCOME_KILLED] = { "NOBODY SAW THE SUN", nil },
    [HH.OUTCOME_ABORTED] = { "THE NIGHT WAS CALLED OFF", nil },
}

local function drawResults( w, h )
    local outcome = GetGlobal2Int( "HH_Outcome", HH.OUTCOME_NONE )
    local info = OUTCOME_TEXT[outcome]
    if not info then return end

    local started = GetGlobal2Float( "HH_PhaseEnd", 0 ) - HH.RESULTS_LENGTH
    local alpha = math.Clamp( ( CurTime() - started ) / 1.5, 0, 1 )

    surface.SetDrawColor( 0, 0, 0, 200 * alpha )
    surface.DrawRect( 0, 0, w, h )

    local titleColor = outcome == HH.OUTCOME_SURVIVED and PALETTE.good or PALETTE.blood
    HH.ShadowText( info[1], "HH_Title", w * 0.5, h * 0.38, ColorAlpha( titleColor, 255 * alpha ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )

    local sub = info[2] or ( GetGlobal2String( "HH_KillerName", "The killer" ) .. " wins." )
    HH.ShadowText( sub, "HH_Med", w * 0.5, h * 0.48, ColorAlpha( PALETTE.text, 255 * alpha ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )

    local survivors = {}
    for _, ply in player.Iterator() do
        if ply:Alive() and not HH.IsOut( ply ) then
            table.insert( survivors, ply:Nick() )
        end
    end

    if #survivors > 0 and outcome == HH.OUTCOME_SURVIVED then
        HH.ShadowText( "Survivors:  " .. table.concat( survivors, ",  " ), "HH_Small", w * 0.5, h * 0.55, ColorAlpha( PALETTE.dim, 255 * alpha ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    end
end

--[[ The HUD ]]

hook.Add( "HUDPaint", "HorrorHelper_HUD", function()
    local phase = HH.GetPhase()
    local w, h = ScrW(), ScrH()
    local ply = LocalPlayer()
    if not IsValid( ply ) then return end

    if phase == HH.PHASE_RESULTS then
        drawResults( w, h )
        return
    end

    if phase ~= HH.PHASE_NIGHT then return end

    local now = CurTime()

    -- Red edge pulse when the chase begins.
    local sinceEncounter = now - ( HH.Cl.EncounterAt or 0 )
    if sinceEncounter < ENCOUNTER_FLASH then
        local a = 120 * ( 1 - sinceEncounter / ENCOUNTER_FLASH )
        surface.SetDrawColor( 120, 0, 0, a )
        surface.DrawRect( 0, 0, w, h * 0.06 )
        surface.DrawRect( 0, h * 0.94, w, h * 0.06 )
        surface.DrawRect( 0, 0, w * 0.04, h )
        surface.DrawRect( w * 0.96, 0, w * 0.04, h )
    end

    if HH.IsOut( ply ) then
        HH.ShadowText( "YOU DIDN'T MAKE IT", "HH_Big", w * 0.5, h * 0.1, PALETTE.blood, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
        local remaining = GetGlobal2Float( "HH_PhaseEnd", 0 ) - now
        HH.ShadowText( "Watching the others.  Sunrise in " .. formatTime( remaining ), "HH_Small", w * 0.5, h * 0.15, PALETTE.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    elseif ply:Alive() then
        drawVignette( w, h )
        drawCabinMarker( ply, w, h )
        drawCalls( w, h )
        drawClock( w, h )
        drawObjectives( ply, w, h )

        local hint = hintFor( ply )
        if hint then
            HH.ShadowText( hint, "HH_Small", w * 0.5, h * 0.56, PALETTE.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
        end
    end

    drawMessage( w, h )

    -- Fade up from the black the opening film ends on.
    local sinceStart = now - GetGlobal2Float( "HH_NightStart", 0 )
    if sinceStart < NIGHT_FADE_IN then
        surface.SetDrawColor( 0, 0, 0, 255 * ( 1 - sinceStart / NIGHT_FADE_IN ) )
        surface.DrawRect( 0, 0, w, h )
    end

    if now < ( HH.Cl.BlinkUntil or 0 ) then
        surface.SetDrawColor( 0, 0, 0, 255 )
        surface.DrawRect( 0, 0, w, h )
    end
end )
