-- Client: synced state, the dispatch card, markers for the scene / patients / hospital /
-- ambulance, the treatment progress bar and kit hints. Only shown while you're on duty.

local PMR = ParamedicResponse

PMR.Client = PMR.Client or {
    patients = {}, -- id -> synced patient
    order = {}, -- patient ids in a stable order
    call = nil,
    nextCallAt = 0,
    action = nil,
}

local C = PMR.Client

local SCENE_MARKER_HIDE = 800 -- the crash marker disappears once you're this close (and on scene)
local TAG_RANGE = 1600
local AMBULANCE_TAG_RANGE = 4000
local CACHE_INTERVAL = 1
local EDGE_MARGIN = 60
local CARD_WIDTH = 380
local AIM_RANGE = 160
local AIM_RADIUS = 14

--[[ Fonts & colours ]]

local function createFonts()
    local scale = math.Clamp( ScrH() / 1080, 0.7, 2 )

    surface.CreateFont( "PMR_Title", { font = "Roboto", size = math.Round( 26 * scale ), weight = 800, extended = true } )
    surface.CreateFont( "PMR_Body", { font = "Roboto", size = math.Round( 19 * scale ), weight = 500, extended = true } )
    surface.CreateFont( "PMR_Bold", { font = "Roboto", size = math.Round( 19 * scale ), weight = 800, extended = true } )
    surface.CreateFont( "PMR_Small", { font = "Roboto", size = math.Round( 15 * scale ), weight = 500, extended = true } )
    surface.CreateFont( "PMR_Vital", { font = "Roboto Mono", size = math.Round( 40 * scale ), weight = 700, extended = true } )
    surface.CreateFont( "PMR_World", { font = "Roboto", size = 72, weight = 900, extended = true } )
    surface.CreateFont( "PMR_WorldSmall", { font = "Roboto", size = 40, weight = 700, extended = true } )
end

createFonts()
hook.Add( "OnScreenSizeChanged", "PMR_Fonts", createFonts )

PMR.UI = PMR.UI or {}
local UI = PMR.UI

UI.BG = Color( 18, 22, 30, 225 )
UI.PANEL = Color( 30, 36, 48, 240 )
UI.LINE = Color( 255, 255, 255, 20 )
UI.TEXT = Color( 235, 238, 245 )
UI.DIM = Color( 150, 158, 175 )
UI.ACCENT = Color( 225, 55, 55 )
UI.BLUE = Color( 70, 150, 240 )
UI.SHADOW = Color( 0, 0, 0, 200 )

function UI.FormatTime( seconds )
    return string.FormattedTime( math.max( 0, seconds ), "%02i:%02i" )
end

function UI.Meters( units )
    return math.Round( units * PMR.METERS_PER_UNIT ) .. " m"
end

-- Splits `text` into lines no wider than `width` in `font`.
function UI.Wrap( text, font, width )
    surface.SetFont( font )

    local lines, line = {}, ""
    for word in string.gmatch( text, "%S+" ) do
        local test = line == "" and word or ( line .. " " .. word )
        if surface.GetTextSize( test ) > width and line ~= "" then
            table.insert( lines, line )
            line = word
        else
            line = test
        end
    end

    if line ~= "" then
        table.insert( lines, line )
    end

    return lines
end

local availableSounds = {}

function PMR.PlaySound( path, pitch, volume )
    if availableSounds[path] == nil then
        availableSounds[path] = file.Exists( "sound/" .. path, "GAME" )
    end

    if not availableSounds[path] then return end

    LocalPlayer():EmitSound( path, 75, pitch or 100, volume or 1, CHAN_STATIC )
end

function PMR.OnDuty()
    local ply = LocalPlayer()

    return IsValid( ply ) and ply:GetNW2Bool( "PMR_Duty" )
end

--[[ Networking ]]

net.Receive( "PMR_Patients", function()
    local patients, order = {}, {}

    for _ = 1, net.ReadUInt( 4 ) do
        local p = {
            id = net.ReadUInt( 16 ),
            ragdoll = net.ReadEntity(),
            name = net.ReadString(),
            age = net.ReadUInt( 7 ),
            female = net.ReadBool(),
            state = net.ReadUInt( 3 ),
            assessed = net.ReadBool(),
            stability = net.ReadUInt( 7 ),
            arrest = net.ReadBool(),
            onO2 = net.ReadBool(),
            cpr = net.ReadBool(),
            arrestLeft = net.ReadUInt( 11 ),
            vitals = {
                hr = net.ReadUInt( 8 ),
                sys = net.ReadUInt( 8 ),
                dia = net.ReadUInt( 8 ),
                spo2 = net.ReadUInt( 7 ),
                rr = net.ReadUInt( 6 ),
                gcs = net.ReadUInt( 4 ),
            },
            injuries = {},
        }

        for _ = 1, net.ReadUInt( 4 ) do
            table.insert( p.injuries, { type = net.ReadUInt( 4 ), treated = net.ReadBool() } )
        end

        p.ambulance = net.ReadEntity()

        local old = C.patients[p.id]
        if old and old.state ~= PMR.STATE_DEAD and p.state == PMR.STATE_DEAD then
            PMR.PlaySound( PMR.Sounds.death, 90 )
        end

        patients[p.id] = p
        table.insert( order, p.id )
    end

    C.patients = patients
    C.order = order
end )

net.Receive( "PMR_Call", function()
    if net.ReadBool() then
        local call = {
            id = net.ReadUInt( 16 ),
            pos = net.ReadVector(),
            title = net.ReadString(),
            desc = net.ReadString(),
            start = net.ReadDouble(),
            arrivedAt = net.ReadDouble(),
        }

        if call.arrivedAt == 0 then
            call.arrivedAt = nil
        end

        if not C.call or C.call.id ~= call.id then
            PMR.PlaySound( PMR.Sounds.dispatch, 100, 0.6 )
            timer.Simple( 0.35, function()
                PMR.PlaySound( PMR.Sounds.dispatchTone, 120, 0.5 )
            end )
        end

        C.call = call
    else
        if C.call then
            PMR.PlaySound( PMR.Sounds.dispatchEnd, 100, 0.6 )
        end

        C.call = nil
        C.nextCallAt = net.ReadDouble()
    end
end )

net.Receive( "PMR_Action", function()
    local actionId = net.ReadUInt( 4 )

    if actionId == 0 then
        C.action = nil

        return
    end

    C.action = {
        action = actionId,
        patient = net.ReadUInt( 16 ),
        start = net.ReadDouble(),
        finish = net.ReadDouble(),
    }
end )

net.Receive( "PMR_Open", function()
    local kind = net.ReadUInt( 3 )

    if kind == PMR.OPEN_CHART then
        PMR.OpenChart( net.ReadUInt( 16 ) )
    elseif kind == PMR.OPEN_AMBULANCE then
        PMR.OpenAmbulance( net.ReadEntity() )
    end
end )

--[[ Cached entity lists ]]

local hospitals, ambulances = {}, {}

timer.Create( "PMR_ClientCache", CACHE_INTERVAL, 0, function()
    if not PMR.OnDuty() then return end

    hospitals = ents.FindByClass( "pmr_hospital" )
    ambulances = {}

    for _, ent in ents.Iterator() do
        if ent:GetNW2Bool( "PMR_Ambulance" ) then
            table.insert( ambulances, ent )
        end
    end
end )

function PMR.AimedClientPatient()
    local ply = LocalPlayer()
    local start, dir = ply:EyePos(), ply:GetAimVector()
    local best, bestAlong

    for _, p in pairs( C.patients ) do
        local rag = p.ragdoll

        if IsValid( rag ) and not rag:IsDormant() and not IsValid( p.ambulance ) and rag:GetPos():Distance( start ) < AIM_RANGE + 80 then
            local along = PMR.RayNearRagdoll( start, dir, rag, AIM_RANGE, AIM_RADIUS )
            if along and ( not bestAlong or along < bestAlong ) then
                best, bestAlong = p, along
            end
        end
    end

    return best
end

--[[ Drawing helpers ]]

local function shadowText( text, font, x, y, color, alignX, alignY )
    draw.SimpleText( text, font, x + 1, y + 1, UI.SHADOW, alignX, alignY )
    draw.SimpleText( text, font, x, y, color, alignX, alignY )
end

-- A marker over `pos`, or pinned to the screen edge pointing at it when it's off screen.
local function worldMarker( pos, label, color )
    local scr = pos:ToScreen()
    local w, h = ScrW(), ScrH()
    local x, y = scr.x, scr.y
    local onScreen = scr.visible and x > EDGE_MARGIN and x < w - EDGE_MARGIN and y > EDGE_MARGIN and y < h - EDGE_MARGIN

    if not onScreen then
        local dir = pos - EyePos()
        local ang = EyeAngles()
        local dx, dy = dir:Dot( ang:Right() ), -dir:Dot( ang:Up() )
        local len = math.sqrt( dx * dx + dy * dy )

        if len < 0.001 then
            dx, dy, len = 0, 1, 1
        end

        dx, dy = dx / len, dy / len

        local reach = math.min( ( w / 2 - EDGE_MARGIN ) / math.max( math.abs( dx ), 0.001 ), ( h / 2 - EDGE_MARGIN ) / math.max( math.abs( dy ), 0.001 ) )
        x, y = w / 2 + dx * reach, h / 2 + dy * reach
    end

    local size = 9
    draw.NoTexture()
    surface.SetDrawColor( UI.SHADOW )
    surface.DrawPoly( {
        { x = x + 1, y = y - size + 1 }, { x = x + size + 1, y = y + 1 },
        { x = x + 1, y = y + size + 1 }, { x = x - size + 1, y = y + 1 },
    } )
    surface.SetDrawColor( color )
    surface.DrawPoly( {
        { x = x, y = y - size }, { x = x + size, y = y },
        { x = x, y = y + size }, { x = x - size, y = y },
    } )

    shadowText( label, "PMR_Bold", x, y - size - 4, color, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM )
    shadowText( UI.Meters( EyePos():Distance( pos ) ), "PMR_Small", x, y + size + 4, UI.TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP )
end

local function anyoneToTransport()
    for _, p in pairs( C.patients ) do
        if p.state == PMR.STATE_BOARD or p.state == PMR.STATE_AMBULANCE then return true end
    end

    return false
end

--[[ The dispatch card ]]

local wrapCache = { text = nil, lines = {} }

local function drawCallCard()
    local scale = ScrH() / 1080
    local width = math.Round( CARD_WIDTH * math.Clamp( scale, 0.8, 2 ) )
    local pad = math.Round( 12 * math.Clamp( scale, 0.8, 2 ) )
    local x, y = ScrW() - width - 20, 20
    local call = C.call

    if not call then
        local text = "ON DUTY · waiting for dispatch"
        if C.nextCallAt > 0 then
            text = text .. " (~" .. UI.FormatTime( C.nextCallAt - CurTime() ) .. ")"
        end

        surface.SetFont( "PMR_Bold" )
        local tw, th = surface.GetTextSize( text )
        draw.RoundedBox( 6, ScrW() - tw - pad * 2 - 20, y, tw + pad * 2, th + pad, UI.BG )
        draw.SimpleText( text, "PMR_Bold", ScrW() - 20 - pad, y + pad / 2, UI.TEXT, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP )

        return
    end

    if wrapCache.text ~= call.desc or wrapCache.width ~= width then
        wrapCache.text = call.desc
        wrapCache.width = width
        wrapCache.lines = UI.Wrap( call.desc, "PMR_Body", width - pad * 2 )
    end

    surface.SetFont( "PMR_Body" )
    local _, lineH = surface.GetTextSize( "Ag" )
    surface.SetFont( "PMR_Title" )
    local _, titleH = surface.GetTextSize( "Ag" )

    local rows = #C.order
    local height = pad + lineH + titleH + #wrapCache.lines * lineH + pad + lineH + pad / 2 + rows * ( lineH + 4 ) + pad

    draw.RoundedBox( 8, x, y, width, height, UI.BG )
    draw.RoundedBoxEx( 8, x, y, width, lineH + pad, UI.ACCENT, true, true, false, false )

    local elapsed = CurTime() - call.start
    draw.SimpleText( "CALL #" .. call.id, "PMR_Bold", x + pad, y + pad / 2, UI.TEXT )
    draw.SimpleText( UI.FormatTime( elapsed ), "PMR_Bold", x + width - pad, y + pad / 2, UI.TEXT, TEXT_ALIGN_RIGHT )

    local cy = y + lineH + pad + 4
    draw.SimpleText( call.title, "PMR_Title", x + pad, cy, UI.TEXT )
    cy = cy + titleH

    for _, line in ipairs( wrapCache.lines ) do
        draw.SimpleText( line, "PMR_Body", x + pad, cy, UI.DIM )
        cy = cy + lineH
    end

    cy = cy + pad / 2

    local status
    if not call.arrivedAt then
        status = "Respond: " .. UI.Meters( EyePos():Distance( call.pos ) ) .. " away"
    elseif anyoneToTransport() and #hospitals > 0 then
        status = "On scene " .. UI.FormatTime( call.arrivedAt - call.start ) .. " · get them to the hospital"
    else
        status = "On scene " .. UI.FormatTime( call.arrivedAt - call.start ) .. " · treat and package"
    end

    draw.SimpleText( status, "PMR_Bold", x + pad, cy, UI.TEXT )
    cy = cy + lineH + pad / 2

    surface.SetDrawColor( UI.LINE )
    surface.DrawRect( x + pad, cy - 3, width - pad * 2, 1 )

    for _, id in ipairs( C.order ) do
        local p = C.patients[id]
        local label, color = PMR.Triage( p )

        if p.arrest and math.floor( CurTime() * 3 ) % 2 == 0 then
            color = UI.TEXT
        end

        draw.RoundedBox( 4, x + pad, cy + lineH / 2 - 5, 10, 10, color )
        draw.SimpleText( p.name, "PMR_Body", x + pad + 18, cy, UI.TEXT )
        draw.SimpleText( label .. " · " .. PMR.STATE_NAMES[p.state], "PMR_Small", x + width - pad, cy + 2, color, TEXT_ALIGN_RIGHT )
        cy = cy + lineH + 4
    end
end

--[[ World markers ]]

local function drawMarkers()
    local call = C.call
    local eye = EyePos()

    if call and ( not call.arrivedAt or eye:Distance( call.pos ) > SCENE_MARKER_HIDE ) then
        worldMarker( call.pos + Vector( 0, 0, 60 ), call.title, UI.ACCENT )
    end

    for _, p in pairs( C.patients ) do
        local rag = p.ragdoll

        if IsValid( rag ) and not rag:IsDormant() and not IsValid( p.ambulance ) then
            local pos = rag:GetPos() + Vector( 0, 0, 30 )
            local dist = eye:Distance( pos )

            if dist < TAG_RANGE then
                local scr = pos:ToScreen()
                if scr.visible then
                    local label, color = PMR.Triage( p )
                    if p.arrest then
                        label = label .. " " .. UI.FormatTime( p.arrestLeft )
                        if p.cpr then label = label .. " · CPR" end
                    end

                    shadowText( p.name, "PMR_Bold", scr.x, scr.y, UI.TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM )
                    shadowText( label, "PMR_Small", scr.x, scr.y, color, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP )
                end
            end
        end
    end

    if anyoneToTransport() then
        for _, hospital in ipairs( hospitals ) do
            if IsValid( hospital ) then
                worldMarker( hospital:GetPos() + Vector( 0, 0, 80 ), "HOSPITAL", UI.BLUE )
            end
        end
    end

    for _, amb in ipairs( ambulances ) do
        if IsValid( amb ) and not amb:IsDormant() then
            local pos = amb:WorldSpaceCenter() + Vector( 0, 0, 70 )
            if eye:Distance( pos ) < AMBULANCE_TAG_RANGE then
                local scr = pos:ToScreen()
                if scr.visible then
                    local load = amb:GetNW2Int( "PMR_Load" )
                    local text = load > 0 and ( "AMBULANCE · " .. load .. " aboard" ) or "AMBULANCE"
                    shadowText( text, "PMR_Small", scr.x, scr.y, UI.BLUE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
                end
            end
        end
    end
end

--[[ Progress bar and hints ]]

local function drawProgress()
    local work = C.action
    if not work then return end

    local act = PMR.Actions[work.action]
    local p = C.patients[work.patient]
    local frac = math.Clamp( ( CurTime() - work.start ) / math.max( work.finish - work.start, 0.01 ), 0, 1 )

    local w, h = math.Round( ScrW() * 0.26 ), math.Round( 14 * ScrH() / 1080 ) + 6
    local x, y = ScrW() / 2 - w / 2, ScrH() * 0.68

    local text = act.verb .. ( p and ( " · " .. p.name ) or "" )
    shadowText( text, "PMR_Bold", ScrW() / 2, y - 4, UI.TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM )
    draw.RoundedBox( 4, x, y, w, h, UI.BG )
    draw.RoundedBox( 4, x + 2, y + 2, ( w - 4 ) * frac, h - 4, UI.BLUE )
end

local function drawHints()
    local ply = LocalPlayer()
    local wep = ply:GetActiveWeapon()
    if not IsValid( wep ) or wep:GetClass() ~= "weapon_pmr_kit" then return end

    local board = ply:GetNW2Entity( "PMR_Board" )
    local p = PMR.AimedClientPatient()
    local text

    if IsValid( board ) and board:GetPatient() ~= 0 then
        text = "Carrying a patient · E: put down · Left Mouse at the ambulance: load"
    elseif p then
        text = "Left Mouse: " .. p.name .. "'s chart"
    elseif IsValid( board ) then
        text = "Carrying a spine board · E: put it down next to a patient, then Log-roll from their chart"
    else
        text = "Left Mouse: patient chart · Right Mouse: ambulance · R: mark vehicle as ambulance"
    end

    shadowText( text, "PMR_Body", ScrW() / 2, ScrH() - 140, UI.TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM )
end

hook.Add( "HUDPaint", "PMR_HUD", function()
    if not PMR.OnDuty() then return end

    drawMarkers()
    drawCallCard()
    drawProgress()
    drawHints()
end )
