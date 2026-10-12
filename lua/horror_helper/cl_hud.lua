-- Fonts, shared UI helpers, the night HUD (time to sunrise, objectives, what you carry, what
-- E does, the cabin marker, voices you heard), queued messages, the spectator note and the
-- result screen.

local HH = HorrorHelper

-- One accent (blood), warm off-white text, near-black panels with a hint of the accent.
local PALETTE = {
    text = Color( 228, 222, 210 ),
    dim = Color( 150, 144, 136 ),
    faint = Color( 150, 144, 136, 90 ),
    blood = Color( 170, 24, 24 ),
    panel = Color( 16, 13, 14, 185 ),
    panelEdge = Color( 170, 24, 24, 50 ),
    shadow = Color( 0, 0, 0, 200 ),
    good = Color( 230, 200, 120 ),
}
HH.PALETTE = PALETTE

local HINT_REACH = 110
local NIGHT_FADE_IN = 2
local ENCOUNTER_FLASH = 1.6
local MESSAGE_FADE = 0.6
local MESSAGE_QUEUE_MAX = 3
local RESULTS_NAMES_MAX = 6

--[[ Fonts ]]

local function createFonts()
    local scale = ScrH() / 1080

    surface.CreateFont( "HH_Title", { font = "Roboto", size = math.Round( 104 * scale ), weight = 900, extended = true } )
    surface.CreateFont( "HH_Big", { font = "Roboto", size = math.Round( 52 * scale ), weight = 800, extended = true } )
    surface.CreateFont( "HH_Med", { font = "Roboto", size = math.Round( 28 * scale ), weight = 600, extended = true } )
    surface.CreateFont( "HH_Small", { font = "Roboto", size = math.Round( 20 * scale ), weight = 500, extended = true } )
    surface.CreateFont( "HH_SmallBold", { font = "Roboto", size = math.Round( 20 * scale ), weight = 800, extended = true } )
    surface.CreateFont( "HH_Tiny", { font = "Roboto", size = math.Round( 16 * scale ), weight = 500, extended = true } )
    surface.CreateFont( "HH_World", { font = "Roboto", size = 40, weight = 700, extended = true } )
end

createFonts()

--[[ Shared UI helpers ]]

HH.UI = HH.UI or {}
local UI = HH.UI

local fitCache = {}

hook.Add( "OnScreenSizeChanged", "HorrorHelper_Fonts", function()
    createFonts()
    fitCache = {}
end )

function UI.TextWidth( font, text )
    surface.SetFont( font )

    return ( surface.GetTextSize( text ) )
end

-- The text, shortened with an ellipsis if it is wider than maxW. Cached: names and titles
-- are measured once, not every frame.
function UI.FitText( text, font, maxW )
    local key = font .. "\0" .. maxW .. "\0" .. text
    local cached = fitCache[key]
    if cached then return cached end

    local fitted = text
    if UI.TextWidth( font, text ) > maxW then
        -- Cut on character boundaries so names in other scripts don't turn into garbage.
        local chars = utf8.len( text ) or #text
        local count = chars
        repeat
            count = count - 1
            local byteEnd = ( utf8.offset( text, count + 1 ) or ( count + 1 ) ) - 1
            fitted = string.sub( text, 1, byteEnd ) .. "…"
        until count <= 1 or UI.TextWidth( font, fitted ) <= maxW
    end

    fitCache[key] = fitted
    return fitted
end

-- A reusable colour per call site, so animated alphas don't allocate every frame.
local scratch = {}

function UI.Alpha( slot, base, alpha )
    local col = scratch[slot]
    if not col then
        col = Color( 0, 0, 0 )
        scratch[slot] = col
    end

    col.r, col.g, col.b, col.a = base.r, base.g, base.b, math.Clamp( alpha, 0, 255 )
    return col
end

function HH.ShadowText( text, font, x, y, color, alignX, alignY )
    local shadow = UI.Alpha( "shadow", PALETTE.shadow, PALETTE.shadow.a * ( color.a / 255 ) )
    draw.SimpleText( text, font, x + 2, y + 2, shadow, alignX, alignY )
    draw.SimpleText( text, font, x, y, color, alignX, alignY )
end

local gradients = {
    l = Material( "vgui/gradient-l" ),
    r = Material( "vgui/gradient-r" ),
    u = Material( "vgui/gradient-u" ),
    d = Material( "vgui/gradient-d" ),
}

-- Soft colour creeping in from all four edges of the screen.
function UI.EdgeGlow( w, h, r, g, b, alpha, size )
    local side = w * size
    local band = h * size

    surface.SetDrawColor( r, g, b, alpha )
    surface.SetMaterial( gradients.l )
    surface.DrawTexturedRect( 0, 0, side, h )
    surface.SetMaterial( gradients.r )
    surface.DrawTexturedRect( w - side, 0, side, h )
    surface.SetMaterial( gradients.u )
    surface.DrawTexturedRect( 0, 0, w, band )
    surface.SetMaterial( gradients.d )
    surface.DrawTexturedRect( 0, h - band, w, band )
end

local function formatTime( seconds )
    seconds = math.max( 0, math.floor( seconds ) )

    return string.format( "%d:%02d", math.floor( seconds / 60 ), seconds % 60 )
end
HH.FormatTime = formatTime

--[[ Messages: one at a time, the next waits its turn ]]

local messages = {}

function HH.ShowMessage( text, duration )
    -- The same line twice in a row (two cues at once) shows once.
    local last = messages[#messages]
    if last and last.text == text then return end
    if #messages >= MESSAGE_QUEUE_MAX then
        table.remove( messages, 2 )
    end

    table.insert( messages, { text = text, duration = duration or 3 } )
end

local function drawMessage( w, h )
    local current = messages[1]
    if not current then return end

    local now = CurTime()
    if not current.start then
        current.start = now
    end

    local age = now - current.start
    if age >= current.duration then
        table.remove( messages, 1 )
        return
    end

    local alpha = math.min( 1, age / MESSAGE_FADE, ( current.duration - age ) / MESSAGE_FADE )
    local col = UI.Alpha( "message", PALETTE.text, 255 * alpha )
    local shadow = UI.Alpha( "messageShadow", PALETTE.shadow, PALETTE.shadow.a * alpha )

    -- Wrapped to the middle of the screen so long lines stay readable.
    if not current.wrapped then
        current.wrapped = UI.Wrap( current.text, "HH_Med", w * 0.6 )
    end

    draw.DrawText( current.wrapped, "HH_Med", w * 0.5 + 2, h * 0.72 + 2, shadow, TEXT_ALIGN_CENTER )
    draw.DrawText( current.wrapped, "HH_Med", w * 0.5, h * 0.72, col, TEXT_ALIGN_CENTER )
end

-- Breaks text into lines no wider than maxW (returned as one string with newlines).
function UI.Wrap( text, font, maxW )
    local lines, line = {}, ""

    for word in string.gmatch( text, "%S+" ) do
        local candidate = line == "" and word or ( line .. " " .. word )
        if line ~= "" and UI.TextWidth( font, candidate ) > maxW then
            table.insert( lines, line )
            line = word
        else
            line = candidate
        end
    end
    if line ~= "" then
        table.insert( lines, line )
    end

    return table.concat( lines, "\n" )
end

--[[ Objectives ]]

local STAGE_HEADINGS = {
    [HH.STAGE_REGROUP] = function() return "FIND THE OTHERS" end,
    [HH.STAGE_TO_CABIN] = function() return "GET TO " .. string.upper( GetGlobal2String( "HH_CabinName", "the cabin" ) ) end,
}

local BAR_BACK = Color( 255, 255, 255, 18 )

local function drawBar( x, y, w, h, frac, color )
    surface.SetDrawColor( BAR_BACK )
    surface.DrawRect( x, y, w, h )
    surface.SetDrawColor( color.r, color.g, color.b, 220 )
    surface.DrawRect( x, y, math.floor( w * math.Clamp( frac, 0, 1 ) ), h )
end

-- Rows: { text, font, color, barFraction, barColor }, reused frame to frame.
local objectiveRows = {}
local rowCount = 0

local function addRow( text, font, color, frac, barColor )
    rowCount = rowCount + 1
    local row = objectiveRows[rowCount] or {}
    objectiveRows[rowCount] = row
    row[1], row[2], row[3], row[4], row[5] = text, font, color, frac, barColor
end

local function drawObjectives( ply, w, h )
    local pad = math.Round( h * 0.018 )
    local lineH = math.Round( h * 0.03 )
    local barH = math.max( 3, math.Round( h * 0.004 ) )
    local rowGap = math.Round( lineH * 0.45 )
    local maxW = math.Round( w * 0.3 )

    local fusesIn = GetGlobal2Int( "HH_FusesIn", 0 )
    local fusesNeeded = GetGlobal2Int( "HH_FusesNeeded", 0 )
    local boards = GetGlobal2Int( "HH_Boards", 0 )
    local boardsMax = GetGlobal2Int( "HH_BoardsMax", 0 )
    local powered = GetGlobal2Bool( "HH_Power", false )
    local stage = HH.GetStage()
    local preparing = stage == HH.STAGE_PREPARE
    local heading = STAGE_HEADINGS[stage]

    local rows = objectiveRows
    rowCount = 0

    if heading then
        addRow( heading(), "HH_SmallBold", PALETTE.blood )
    end

    if preparing and fusesNeeded > 0 then
        local cut = CurTime() < GetGlobal2Float( "HH_PowerCutUntil", 0 )
        local label = powered and ( cut and "POWER  OUT" or "POWER  ON" ) or string.format( "POWER  %d / %d fuses", fusesIn, fusesNeeded )
        local color = powered and not cut and PALETTE.good or PALETTE.text
        addRow( label, "HH_Small", color, fusesIn / fusesNeeded, powered and PALETTE.good or PALETTE.blood )
    end

    if preparing and boardsMax > 0 then
        addRow( string.format( "BARRICADES  %d / %d boards", boards, boardsMax ), "HH_Small", PALETTE.text, boards / boardsMax, PALETTE.blood )
    end

    local fuses = ply:GetNW2Int( "HH_Fuses", 0 )
    local planks = ply:GetNW2Int( "HH_Planks", 0 )
    addRow( string.format( "CARRYING  %d fuse%s  ·  %d plank%s", fuses, fuses == 1 and "" or "s", planks, planks == 1 and "" or "s" ), "HH_Small", PALETTE.dim )
    for i = rowCount + 1, #rows do
        rows[i] = nil
    end

    -- Size the box to its widest line, within limits.
    local innerW = math.Round( h * 0.26 )
    for _, row in ipairs( rows ) do
        innerW = math.max( innerW, UI.TextWidth( row[2], row[1] ) )
    end
    innerW = math.min( innerW, maxW - pad * 2 )

    local boxH = pad * 2 - rowGap
    for _, row in ipairs( rows ) do
        boxH = boxH + lineH + ( row[4] and barH + 2 or 0 ) + rowGap
    end

    local x, y = pad, pad
    draw.RoundedBox( 4, x, y, innerW + pad * 2, boxH, PALETTE.panel )
    surface.SetDrawColor( PALETTE.panelEdge )
    surface.DrawRect( x, y, 2, boxH )

    local cx, cy = x + pad, y + pad
    for _, row in ipairs( rows ) do
        draw.SimpleText( UI.FitText( row[1], row[2], innerW ), row[2], cx, cy, row[3] )
        cy = cy + lineH

        if row[4] then
            drawBar( cx, cy, innerW, barH, row[4], row[5] )
            cy = cy + barH + 2
        end

        cy = cy + rowGap
    end
end

local function drawClock( w, h )
    local remaining = GetGlobal2Float( "HH_PhaseEnd", 0 ) - CurTime()
    local text = formatTime( remaining ) .. "  UNTIL SUNRISE"

    HH.ShadowText( text, "HH_Small", w * 0.5, h * 0.025, PALETTE.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP )
end

--[[ Things in the world: the cabin once it's revealed, voices you heard ]]

local UNITS_TO_METERS = 0.01905
local EDGE_MARGIN = 0.06 -- off-screen markers sit this far in from the screen edge

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

-- Keep a centred label of width textW fully on screen.
local function clampLabelX( x, textW, w )
    local half = textW * 0.5 + 8

    return math.Clamp( x, half, w - half )
end

local diamond = { { x = 0, y = 0 }, { x = 0, y = 0 }, { x = 0, y = 0 }, { x = 0, y = 0 } }

local function drawDiamond( x, y, size, color )
    diamond[1].x, diamond[1].y = x, y - size
    diamond[2].x, diamond[2].y = x + size, y
    diamond[3].x, diamond[3].y = x, y + size
    diamond[4].x, diamond[4].y = x - size, y

    surface.SetDrawColor( color.r, color.g, color.b, color.a )
    draw.NoTexture()
    surface.DrawPoly( diamond )
end

local function drawCabinMarker( ply, w, h )
    local stage = HH.GetStage()
    if stage ~= HH.STAGE_TO_CABIN and stage ~= HH.STAGE_PREPARE then return end

    local center = GetGlobal2Vector( "HH_CabinCenter", vector_origin )
    local dist = ply:GetPos():Distance( center )
    -- Once you're set up there, it's only shown while you're away from it.
    if stage == HH.STAGE_PREPARE and dist < GetGlobal2Float( "HH_CabinRadius", 600 ) then return end

    local x, y, onScreen = screenPoint( center + Vector( 0, 0, 72 ), w, h )
    local alpha = stage == HH.STAGE_TO_CABIN and 230 or 120
    -- A gentle pulse on the edge of the screen so it reads as "this way".
    if not onScreen then
        alpha = alpha * ( 0.75 + 0.25 * math.sin( CurTime() * 3 ) )
    end
    local col = UI.Alpha( "marker", PALETTE.good, alpha )

    local name = UI.FitText( GetGlobal2String( "HH_CabinName", "Cabin" ), "HH_Tiny", w * 0.2 )
    local label = string.format( "%s  %dm", name, math.Round( dist * UNITS_TO_METERS ) )
    local labelX = clampLabelX( x, UI.TextWidth( "HH_Tiny", label ), w )
    local labelY = y + h * 0.014
    if labelY > h - h * 0.04 then
        labelY = y - h * 0.04 -- at the bottom edge, put the name above the marker
    end

    drawDiamond( x, y, h * 0.008, col )
    HH.ShadowText( label, "HH_Tiny", labelX, labelY, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP )
end

local function drawCalls( w, h )
    local calls, showTime = HH.Cl.ActiveCalls()

    for i, call in ipairs( calls ) do
        local fade = 1 - ( CurTime() - call.at ) / showTime
        local x, y = screenPoint( call.pos, w, h )
        local text = UI.FitText( call.name, "HH_Small", w * 0.2 ) .. "  calling out"
        local col = UI.Alpha( "call" .. i, PALETTE.text, 200 * fade )

        HH.ShadowText( text, "HH_Small", clampLabelX( x, UI.TextWidth( "HH_Small", text ), w ), y, col, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    end
end

-- The edges of the world close in as dread rises.
local VIGNETTE_MAX_ALPHA = 210

local function drawVignette( w, h )
    local dread = HH.GetDread() * ( 1 - HH.DawnFraction() )
    if dread <= 0.05 then return end

    UI.EdgeGlow( w, h, 0, 0, 0, VIGNETTE_MAX_ALPHA * dread, Lerp( dread, 0.08, 0.22 ) )
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
    [HH.OUTCOME_SURVIVED] = "SUNRISE",
    [HH.OUTCOME_KILLED] = "NOBODY SAW THE SUN",
    [HH.OUTCOME_ABORTED] = "THE NIGHT WAS CALLED OFF",
}

local function survivorLine()
    local names, extra = {}, 0

    for _, ply in player.Iterator() do
        if ply:GetNW2Bool( "HH_Survived", false ) then
            if #names < RESULTS_NAMES_MAX then
                table.insert( names, UI.FitText( ply:Nick(), "HH_Small", 220 ) )
            else
                extra = extra + 1
            end
        end
    end

    if #names == 0 then return nil end

    local line = "Survivors:  " .. table.concat( names, ",  " )
    if extra > 0 then
        line = line .. "  and " .. extra .. " more"
    end

    return line
end

local function drawResults( ply, w, h )
    local outcome = GetGlobal2Int( "HH_Outcome", HH.OUTCOME_NONE )
    local title = OUTCOME_TEXT[outcome]
    if not title then return end

    local started = GetGlobal2Float( "HH_PhaseEnd", 0 ) - HH.RESULTS_LENGTH
    local alpha = math.Clamp( ( CurTime() - started ) / 1.5, 0, 1 )

    surface.SetDrawColor( 8, 6, 7, 210 * alpha )
    surface.DrawRect( 0, 0, w, h )

    local titleColor = outcome == HH.OUTCOME_SURVIVED and PALETTE.good or PALETTE.blood
    local titleFont = UI.TextWidth( "HH_Title", title ) > w * 0.9 and "HH_Big" or "HH_Title"
    HH.ShadowText( title, titleFont, w * 0.5, h * 0.38, UI.Alpha( "resultTitle", titleColor, 255 * alpha ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )

    -- What happened to you, then to everyone.
    local personal
    if outcome == HH.OUTCOME_SURVIVED then
        if ply:GetNW2Bool( "HH_Survived", false ) then
            personal = "You made it through the night."
        elseif HH.IsOut( ply ) then
            personal = "You didn't make it. Some of them did."
        end
    elseif outcome == HH.OUTCOME_KILLED then
        personal = UI.FitText( GetGlobal2String( "HH_KillerName", "The killer" ), "HH_Med", w * 0.5 ) .. " wins."
    end

    if personal then
        HH.ShadowText( personal, "HH_Med", w * 0.5, h * 0.48, UI.Alpha( "resultSub", PALETTE.text, 255 * alpha ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    end

    if outcome == HH.OUTCOME_SURVIVED then
        local line = survivorLine()
        if line then
            HH.ShadowText( line, "HH_Small", w * 0.5, h * 0.55, UI.Alpha( "resultNames", PALETTE.dim, 255 * alpha ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
        end
    end
end

--[[ The HUD ]]

hook.Add( "HUDPaint", "HorrorHelper_HUD", function()
    local phase = HH.GetPhase()
    local w, h = ScrW(), ScrH()
    local ply = LocalPlayer()
    if not IsValid( ply ) then return end

    if phase == HH.PHASE_RESULTS then
        drawResults( ply, w, h )
        return
    end

    if phase ~= HH.PHASE_NIGHT then return end

    local now = CurTime()

    -- Red creeping in from the edges when the chase begins.
    local sinceEncounter = now - ( HH.Cl.EncounterAt or 0 )
    if sinceEncounter < ENCOUNTER_FLASH then
        local strength = 1 - sinceEncounter / ENCOUNTER_FLASH
        UI.EdgeGlow( w, h, 140, 0, 0, 200 * strength, 0.12 )
    end

    if HH.IsOut( ply ) then
        HH.ShadowText( "YOU DIDN'T MAKE IT", "HH_Big", w * 0.5, h * 0.1, PALETTE.blood, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
        local remaining = GetGlobal2Float( "HH_PhaseEnd", 0 ) - now
        HH.ShadowText( "Watching the others.  Sunrise in " .. formatTime( remaining ), "HH_Small", w * 0.5, h * 0.15, PALETTE.dim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
        HH.ShadowText( "Fly around with your movement keys.", "HH_Tiny", w * 0.5, h * 0.18, PALETTE.faint, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
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

-- A new round starts with a clean slate of messages.
local lastPhase
hook.Add( "Think", "HorrorHelper_HUDPhase", function()
    local phase = HH.GetPhase()
    if phase == lastPhase then return end

    lastPhase = phase
    if phase == HH.PHASE_INTRO or phase == HH.PHASE_IDLE then
        messages = {}
    end
end )
