-- Client windows: the patient chart (monitor, findings, treatments), the ambulance's patient
-- list and the end-of-call report.

local PMR = ParamedicResponse
local C = PMR.Client
local UI = PMR.UI

local CHART_CLOSE_RANGE = 450
local REFRESH = 0.2
local ECG_RATE = 100 -- samples per second
local ECG_WINDOW = 4 -- seconds shown across the strip
local SUMMARY_LIFETIME = 30

local GREEN = Color( 80, 230, 120 )
local CYAN = Color( 80, 200, 240 )
local RED = Color( 240, 90, 90 )
local YELLOW = Color( 240, 210, 80 )
local MONITOR_BG = Color( 6, 10, 12 )
local GRID = Color( 40, 80, 60, 60 )
local BUTTON = Color( 44, 52, 68 )
local BUTTON_HOVER = Color( 58, 68, 90 )
local BUTTON_DIM = Color( 34, 38, 48 )
local CHIP_TEXT = Color( 15, 15, 20 )

local function scaled( n )
    return math.Round( n * math.Clamp( ScrH() / 1080, 0.75, 2 ) )
end

local function sendRequest( kind, write )
    net.Start( "PMR_Request" )
    net.WriteUInt( kind, 3 )
    if write then write() end
    net.SendToServer()
end

--[[ Shared window chrome ]]

local function makeFrame( w, h )
    local frame = vgui.Create( "DFrame" )
    frame:SetSize( w, h )
    frame:Center()
    frame:SetTitle( "" )
    frame:ShowCloseButton( false )
    frame:SetDraggable( true )
    frame:MakePopup()

    function frame:Paint( pw, ph )
        draw.RoundedBox( 10, 0, 0, pw, ph, UI.BG )
    end

    local close = vgui.Create( "DButton", frame )
    close:SetText( "" )
    close:SetSize( scaled( 32 ), scaled( 32 ) )
    close:SetPos( w - scaled( 40 ), scaled( 8 ) )

    function close:Paint( pw, ph )
        local color = self:IsHovered() and UI.ACCENT or UI.DIM
        draw.SimpleText( "✕", "PMR_Bold", pw / 2, ph / 2, color, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    end

    function close:DoClick()
        frame:Close()
    end

    return frame
end

local function flatButton( parent, text )
    local button = vgui.Create( "DButton", parent )
    button:SetText( "" )
    button.Label = text
    button.Accent = nil
    button.Dim = false

    function button:Paint( pw, ph )
        local bg = self.Dim and BUTTON_DIM or ( self:IsHovered() and BUTTON_HOVER or BUTTON )
        draw.RoundedBox( 6, 0, 0, pw, ph, bg )

        if self.Accent and not self.Dim then
            draw.RoundedBox( 6, 0, 0, 4, ph, self.Accent )
        end

        draw.SimpleText( self.Label, "PMR_Bold", pw / 2, ph / 2, self.Dim and UI.DIM or UI.TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    end

    return button
end

--[[ The heart monitor ]]

local function ecgWave( phase )
    local function bump( center, width, height )
        local d = ( phase - center ) / width

        return height * math.exp( -d * d )
    end

    return bump( 0.18, 0.035, 0.12 ) - bump( 0.30, 0.010, 0.12 ) + bump( 0.33, 0.012, 1 )
        - bump( 0.36, 0.012, 0.25 ) + bump( 0.58, 0.06, 0.25 )
end

local function fibrillation( t )
    return 0.35 * math.sin( t * 28 ) + 0.25 * math.sin( t * 17.3 + 1.3 ) + 0.15 * math.sin( t * 41.7 )
end

local function createMonitor( parent, getPatient )
    local strip = vgui.Create( "DPanel", parent )
    local size = ECG_RATE * ECG_WINDOW
    local samples = {}

    for i = 1, size do
        samples[i] = 0
    end

    strip.head = 0
    strip.sampleTime = CurTime()
    strip.phase = 0

    function strip:Advance( p )
        local now = CurTime()
        local step = 1 / ECG_RATE

        -- Don't try to catch up on minutes of samples after a hitch.
        if now - self.sampleTime > ECG_WINDOW then
            self.sampleTime = now - ECG_WINDOW
        end

        while self.sampleTime < now do
            self.sampleTime = self.sampleTime + step

            local value = 0
            if p and p.assessed and p.state ~= PMR.STATE_DEAD then
                if p.arrest then
                    value = fibrillation( self.sampleTime )
                elseif p.vitals.hr > 0 then
                    local before = self.phase
                    self.phase = self.phase + step * p.vitals.hr / 60

                    if math.floor( self.phase ) ~= math.floor( before ) then
                        PMR.PlaySound( PMR.Sounds.monitorBeep, 70 + p.vitals.spo2 * 0.4, 0.25 )
                    end

                    value = ecgWave( self.phase % 1 )
                end
            end

            self.head = self.head % size + 1
            samples[self.head] = value
        end
    end

    function strip:Paint( pw, ph )
        local p = getPatient()
        self:Advance( p )

        draw.RoundedBox( 6, 0, 0, pw, ph, MONITOR_BG )

        surface.SetDrawColor( GRID )
        for gx = 0, pw, pw / 16 do
            surface.DrawRect( gx, 0, 1, ph )
        end
        for gy = 0, ph, ph / 6 do
            surface.DrawRect( 0, gy, pw, 1 )
        end

        local color = ( p and p.arrest ) and RED or GREEN
        local mid, amp = ph * 0.6, ph * 0.42
        local lastX, lastY

        surface.SetDrawColor( color )
        for i = 0, size - 1, 2 do
            local index = ( self.head + i ) % size + 1
            local x = i / ( size - 1 ) * pw
            local y = mid - samples[index] * amp

            if lastX then
                surface.DrawLine( lastX, lastY, x, y )
            end

            lastX, lastY = x, y
        end

        draw.SimpleText( "II", "PMR_Small", 8, 6, color )

        if p and not p.assessed then
            draw.SimpleText( "Assess the patient to connect the monitor", "PMR_Body", pw / 2, ph / 2, UI.DIM, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
        end
    end

    return strip
end

local function vitalTile( parent, label, unit, color, getText )
    local tile = vgui.Create( "DPanel", parent )

    function tile:Paint( pw, ph )
        draw.RoundedBox( 6, 0, 0, pw, ph, MONITOR_BG )
        draw.SimpleText( label, "PMR_Small", 10, 6, color )
        draw.SimpleText( unit, "PMR_Small", pw - 10, 6, UI.DIM, TEXT_ALIGN_RIGHT )
        draw.SimpleText( getText(), "PMR_Vital", pw / 2, ph * 0.6, color, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    end

    return tile
end

--[[ The patient chart ]]

local chart

function PMR.OpenChart( id )
    if IsValid( chart ) then
        chart:Close()
    end

    local w, h = scaled( 900 ), scaled( 600 )
    local pad = scaled( 14 )
    local frame = makeFrame( w, h )
    chart = frame
    frame.patientId = id
    frame.message = ""

    local function patient()
        return C.patients[id]
    end

    -- Header
    local header = vgui.Create( "DPanel", frame )
    header:Dock( TOP )
    header:SetTall( scaled( 64 ) )
    header:DockMargin( pad, pad, scaled( 48 ), 0 )

    function header:Paint( pw, ph )
        local p = patient()
        if not p then return end

        local label, color = PMR.Triage( p )
        draw.SimpleText( p.name, "PMR_Title", 0, 0, UI.TEXT )
        draw.SimpleText( p.age .. " y/o " .. ( p.female and "female" or "male" ) .. " · " .. PMR.STATE_NAMES[p.state], "PMR_Body", 0, ph * 0.55, UI.DIM )

        surface.SetFont( "PMR_Bold" )
        local tw, th = surface.GetTextSize( label )
        draw.RoundedBox( 6, pw - tw - 24, ph / 2 - th / 2 - 6, tw + 24, th + 12, color )
        draw.SimpleText( label, "PMR_Bold", pw - tw / 2 - 12, ph / 2, CHIP_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    end

    -- Footer: progress / messages
    local footer = vgui.Create( "DPanel", frame )
    footer:Dock( BOTTOM )
    footer:SetTall( scaled( 44 ) )
    footer:DockMargin( pad, 0, pad, pad )

    local stop = flatButton( footer, "Stop" )
    stop:Dock( RIGHT )
    stop:SetWide( scaled( 90 ) )
    stop.Accent = UI.ACCENT

    function stop:DoClick()
        sendRequest( PMR.REQ_CANCEL )
    end

    function footer:Paint( pw, ph )
        local work = C.action
        local p = patient()

        if work and work.patient == id then
            local frac = math.Clamp( ( CurTime() - work.start ) / math.max( work.finish - work.start, 0.01 ), 0, 1 )
            local barW = pw - stop:GetWide() - scaled( 10 )
            draw.RoundedBox( 6, 0, 0, barW, ph, UI.PANEL )
            draw.RoundedBox( 6, 0, 0, barW * frac, ph, UI.BLUE )
            draw.SimpleText( PMR.Actions[work.action].verb .. "...", "PMR_Bold", 12, ph / 2, UI.TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )

            return
        end

        local text = frame.message
        if text == "" and p and p.arrest then
            text = "Cardiac arrest: " .. UI.FormatTime( p.arrestLeft ) .. " left" .. ( p.cpr and " (CPR is buying time)" or ". Do CPR, then shock." )
        end

        draw.SimpleText( text, "PMR_Body", 4, ph / 2, p and p.arrest and RED or UI.DIM, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
    end

    function footer:PerformLayout()
        stop:SetVisible( C.action ~= nil and C.action.patient == id )
    end

    -- Left: monitor
    local left = vgui.Create( "DPanel", frame )
    left:Dock( LEFT )
    left:SetWide( math.Round( w * 0.47 ) )
    left:DockMargin( pad, pad, pad / 2, pad )
    left.Paint = nil

    local strip = createMonitor( left, patient )
    strip:Dock( TOP )
    strip:SetTall( scaled( 170 ) )

    local function vitalText( func )
        return function()
            local p = patient()
            if not p or not p.assessed then return "--" end

            return func( p, p.vitals )
        end
    end

    local grid = vgui.Create( "DPanel", left )
    grid:Dock( FILL )
    grid:DockMargin( 0, pad / 2, 0, 0 )
    grid.Paint = nil

    local tiles = {
        vitalTile( grid, "HR", "bpm", GREEN, vitalText( function( p, v ) return p.arrest and "VF" or tostring( v.hr ) end ) ),
        vitalTile( grid, "SpO2", "%", CYAN, vitalText( function( _, v ) return tostring( v.spo2 ) end ) ),
        vitalTile( grid, "NIBP", "mmHg", RED, vitalText( function( p, v ) return p.arrest and "--/--" or ( v.sys .. "/" .. v.dia ) end ) ),
        vitalTile( grid, "RR", "/min", YELLOW, vitalText( function( _, v ) return tostring( v.rr ) end ) ),
    }

    function grid:PerformLayout( pw, ph )
        local gap = scaled( 8 )
        local tw, th = ( pw - gap ) / 2, ( ph - gap ) / 2

        for i, tile in ipairs( tiles ) do
            local col, row = ( i - 1 ) % 2, math.floor( ( i - 1 ) / 2 )
            tile:SetPos( col * ( tw + gap ), row * ( th + gap ) )
            tile:SetSize( tw, th )
        end
    end

    -- Right: findings and treatments
    local right = vgui.Create( "DPanel", frame )
    right:Dock( FILL )
    right:DockMargin( pad / 2, pad, pad, pad )
    right.Paint = nil

    local findings = vgui.Create( "DPanel", right )
    findings:Dock( TOP )
    findings:SetTall( scaled( 220 ) )

    function findings:Paint( pw, ph )
        draw.RoundedBox( 6, 0, 0, pw, ph, UI.PANEL )
        draw.SimpleText( "FINDINGS", "PMR_Small", 12, 8, UI.DIM )

        local p = patient()
        if not p then return end

        local y = scaled( 30 )

        if not p.assessed then
            draw.SimpleText( "Not assessed yet. Press Assess.", "PMR_Body", 12, y, UI.TEXT )

            return
        end

        local v = p.vitals
        draw.SimpleText( "GCS " .. v.gcs .. ( p.onO2 and " · on oxygen" or "" ), "PMR_Body", 12, y, UI.TEXT )
        y = y + scaled( 28 )

        for _, injury in ipairs( p.injuries ) do
            local info = PMR.Injuries[injury.type]
            local chip, chipColor = "UNTREATED", PMR.COLOR_CRITICAL

            if injury.treated then
                chip, chipColor = "TREATED", PMR.COLOR_STABLE
            elseif not info.fix then
                chip, chipColor = "HOSPITAL", PMR.COLOR_SERIOUS
            end

            draw.SimpleText( info.name, "PMR_Bold", 12, y, UI.TEXT )

            surface.SetFont( "PMR_Small" )
            local cw, chh = surface.GetTextSize( chip )
            draw.RoundedBox( 4, pw - cw - 24, y + 1, cw + 12, chh + 4, chipColor )
            draw.SimpleText( chip, "PMR_Small", pw - cw / 2 - 18, y + 3, CHIP_TEXT, TEXT_ALIGN_CENTER )

            draw.SimpleText( info.detail, "PMR_Small", 12, y + scaled( 21 ), UI.DIM )
            y = y + scaled( 46 )
        end
    end

    local actions = vgui.Create( "DPanel", right )
    actions:Dock( FILL )
    actions:DockMargin( 0, pad / 2, 0, 0 )
    actions.Paint = nil

    local buttons = {}

    for _, actionId in ipairs( PMR.ACTION_ORDER ) do
        local button = flatButton( actions, PMR.Actions[actionId].name )
        button.actionId = actionId

        function button:DoClick()
            local p = patient()
            if not p then return end

            local blocker = PMR.ActionBlocker( p, actionId )
            if blocker then
                frame.message = blocker .. "."
                surface.PlaySound( "buttons/button10.wav" )

                return
            end

            frame.message = ""
            sendRequest( PMR.REQ_ACTION, function()
                net.WriteUInt( id, 16 )
                net.WriteUInt( actionId, 4 )
            end )
        end

        table.insert( buttons, button )
    end

    function actions:PerformLayout( pw, ph )
        local gap = scaled( 8 )
        local rows = math.ceil( #buttons / 2 )
        local bw, bh = ( pw - gap ) / 2, ( ph - gap * ( rows - 1 ) ) / rows

        for i, button in ipairs( buttons ) do
            local col, row = ( i - 1 ) % 2, math.floor( ( i - 1 ) / 2 )
            button:SetPos( col * ( bw + gap ), row * ( bh + gap ) )
            button:SetSize( bw, bh )
        end
    end

    -- Keep buttons current and close when the patient is gone or out of reach.
    local nextRefresh = 0

    function frame:Think()
        if CurTime() < nextRefresh then return end

        nextRefresh = CurTime() + REFRESH

        local p = patient()
        if not p or not PMR.OnDuty() then
            self:Close()

            return
        end

        local anchor = IsValid( p.ambulance ) and p.ambulance or p.ragdoll
        if p.state ~= PMR.STATE_DELIVERED and IsValid( anchor ) and LocalPlayer():GetPos():Distance( anchor:GetPos() ) > CHART_CLOSE_RANGE then
            self:Close()

            return
        end

        local fixesOpenInjury = {}
        for _, injury in ipairs( p.injuries ) do
            local fix = PMR.Injuries[injury.type].fix
            if fix and not injury.treated then
                fixesOpenInjury[fix] = true
            end
        end

        for _, button in ipairs( buttons ) do
            local blocked = PMR.ActionBlocker( p, button.actionId ) ~= nil
            local urgent = fixesOpenInjury[button.actionId] or ( p.arrest and ( button.actionId == PMR.ACT_CPR or button.actionId == PMR.ACT_DEFIB ) )
                or ( not p.assessed and button.actionId == PMR.ACT_ASSESS )

            button.Dim = blocked
            button.Accent = urgent and UI.ACCENT or nil
        end

        footer:InvalidateLayout()
    end
end

--[[ The ambulance ]]

local ambulanceFrame

function PMR.OpenAmbulance( amb )
    if not IsValid( amb ) then return end

    if IsValid( ambulanceFrame ) then
        ambulanceFrame:Close()
    end

    local w = scaled( 520 )
    local pad = scaled( 14 )
    local rowH = scaled( 52 )
    local frame = makeFrame( w, scaled( 120 ) + rowH * 4 )
    ambulanceFrame = frame

    local title = vgui.Create( "DLabel", frame )
    title:Dock( TOP )
    title:DockMargin( pad, pad, 0, pad / 2 )
    title:SetFont( "PMR_Title" )
    title:SetTextColor( UI.TEXT )
    title:SetText( "Ambulance" )
    title:SizeToContentsY()

    local list = vgui.Create( "DScrollPanel", frame )
    list:Dock( FILL )
    list:DockMargin( pad, 0, pad, pad )

    local shown = {}

    local function rebuild()
        list:Clear()
        shown = {}

        local any = false

        for _, id in ipairs( C.order ) do
            local p = C.patients[id]

            if p.ambulance == amb then
                any = true
                shown[id] = true

                local row = vgui.Create( "DPanel", list )
                row:Dock( TOP )
                row:SetTall( rowH )
                row:DockMargin( 0, 0, 0, scaled( 6 ) )

                function row:Paint( pw, ph )
                    local current = C.patients[id]
                    if not current then return end

                    local label, color = PMR.Triage( current )
                    draw.RoundedBox( 6, 0, 0, pw, ph, UI.PANEL )
                    draw.RoundedBox( 4, 12, ph / 2 - 5, 10, 10, color )
                    draw.SimpleText( current.name, "PMR_Bold", 30, ph / 2, UI.TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM )
                    draw.SimpleText( label, "PMR_Small", 30, ph / 2, color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
                end

                local unload = flatButton( row, "Unload" )
                unload:Dock( RIGHT )
                unload:DockMargin( 0, 8, 8, 8 )
                unload:SetWide( scaled( 100 ) )
                unload.Accent = UI.BLUE

                function unload:DoClick()
                    sendRequest( PMR.REQ_UNLOAD, function()
                        net.WriteEntity( amb )
                        net.WriteUInt( id, 16 )
                    end )
                    frame:Close()
                end

                local open = flatButton( row, "Chart" )
                open:Dock( RIGHT )
                open:DockMargin( 0, 8, 8, 8 )
                open:SetWide( scaled( 90 ) )

                function open:DoClick()
                    frame:Close()
                    PMR.OpenChart( id )
                end
            end
        end

        if not any then
            local empty = vgui.Create( "DLabel", list )
            empty:Dock( TOP )
            empty:SetFont( "PMR_Body" )
            empty:SetTextColor( UI.DIM )
            empty:SetText( "Nobody aboard. Carry a spine board up and press Left Mouse to load it." )
            empty:SetWrap( true )
            empty:SetAutoStretchVertical( true )
        end
    end

    rebuild()

    local nextRefresh = 0

    function frame:Think()
        if CurTime() < nextRefresh then return end

        nextRefresh = CurTime() + REFRESH

        if not IsValid( amb ) or LocalPlayer():GetPos():Distance( amb:GetPos() ) > CHART_CLOSE_RANGE + 200 then
            self:Close()

            return
        end

        -- Rebuild when someone is loaded or unloaded.
        local changed = false
        for _, id in ipairs( C.order ) do
            local p = C.patients[id]
            local aboard = p.ambulance == amb
            if aboard ~= ( shown[id] == true ) then
                changed = true
            end
        end

        for id in pairs( shown ) do
            if not C.patients[id] then
                changed = true
            end
        end

        if changed then
            rebuild()
        end
    end
end

--[[ End-of-call report ]]

local OUTCOME_TEXT = {
    [PMR.OUTCOME_SAVED] = { "Delivered", PMR.COLOR_STABLE },
    [PMR.OUTCOME_DIED] = { "Died", PMR.COLOR_CRITICAL },
    [PMR.OUTCOME_ABANDONED] = { "Left on scene", PMR.COLOR_UNKNOWN },
}

local summaryFrame

local function showSummary( s )
    if IsValid( summaryFrame ) then
        summaryFrame:Close()
    end

    local w = scaled( 620 )
    local pad = scaled( 16 )
    local frame = makeFrame( w, scaled( 560 ) )
    summaryFrame = frame
    frame.closeAt = CurTime() + SUMMARY_LIFETIME

    function frame:Think()
        if CurTime() > self.closeAt then
            self:Close()
        end
    end

    local header = vgui.Create( "DPanel", frame )
    header:Dock( TOP )
    header:SetTall( scaled( 90 ) )
    header:DockMargin( pad, pad, scaled( 48 ), 0 )

    function header:Paint( pw, ph )
        local verb = s.reason == "cancelled" and "cancelled" or "complete"
        draw.SimpleText( "Call #" .. s.id .. " " .. verb, "PMR_Title", 0, 0, UI.TEXT )
        draw.SimpleText( s.title, "PMR_Body", 0, scaled( 34 ), UI.DIM )

        local response = s.response >= 0 and UI.FormatTime( s.response ) or "never arrived"
        draw.SimpleText( "Response " .. response .. " · total " .. UI.FormatTime( s.duration ), "PMR_Body", 0, scaled( 58 ), UI.DIM )

        draw.SimpleText( s.grade, "PMR_Vital", pw, ph / 2, UI.TEXT, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER )
    end

    local footer = vgui.Create( "DPanel", frame )
    footer:Dock( BOTTOM )
    footer:SetTall( scaled( 70 ) )
    footer:DockMargin( pad, 0, pad, pad )

    function footer:Paint( pw, ph )
        draw.RoundedBox( 6, 0, 0, pw, ph, UI.PANEL )
        local bonus = s.bonus > 0 and ( " (incl. +" .. s.bonus .. " fast response)" ) or ""
        draw.SimpleText( "Call score " .. s.total .. bonus, "PMR_Bold", 12, ph / 2, UI.TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM )
        draw.SimpleText( "Shift: " .. s.shiftCalls .. " calls · " .. s.shiftSaved .. " delivered · " .. s.shiftLost .. " lost · " .. s.shiftScore .. " points", "PMR_Small", 12, ph / 2 + 2, UI.DIM, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
    end

    local list = vgui.Create( "DScrollPanel", frame )
    list:Dock( FILL )
    list:DockMargin( pad, pad / 2, pad, pad / 2 )

    for _, row in ipairs( s.rows ) do
        local outcome = OUTCOME_TEXT[row.outcome] or OUTCOME_TEXT[PMR.OUTCOME_ABANDONED]
        local lineH = scaled( 20 )

        local panel = vgui.Create( "DPanel", list )
        panel:Dock( TOP )
        panel:DockMargin( 0, 0, 0, scaled( 6 ) )
        panel:SetTall( scaled( 34 ) + #row.notes * lineH + scaled( 8 ) )

        function panel:Paint( pw, ph )
            draw.RoundedBox( 6, 0, 0, pw, ph, UI.PANEL )
            draw.SimpleText( row.name, "PMR_Bold", 12, scaled( 8 ), UI.TEXT )
            draw.SimpleText( outcome[1] .. " · " .. row.score .. " pts", "PMR_Bold", pw - 12, scaled( 8 ), outcome[2], TEXT_ALIGN_RIGHT )

            for i, note in ipairs( row.notes ) do
                draw.SimpleText( "· " .. note, "PMR_Small", 20, scaled( 34 ) + ( i - 1 ) * lineH, UI.DIM )
            end
        end
    end
end

net.Receive( "PMR_Summary", function()
    local s = {
        id = net.ReadUInt( 16 ),
        title = net.ReadString(),
        reason = net.ReadString(),
        response = net.ReadDouble(),
        duration = net.ReadDouble(),
        rows = {},
    }

    for _ = 1, net.ReadUInt( 4 ) do
        local row = {
            name = net.ReadString(),
            outcome = net.ReadUInt( 2 ),
            score = net.ReadInt( 16 ),
            stability = net.ReadUInt( 7 ),
            notes = {},
        }

        for _ = 1, net.ReadUInt( 4 ) do
            table.insert( row.notes, net.ReadString() )
        end

        table.insert( s.rows, row )
    end

    s.bonus = net.ReadInt( 16 )
    s.total = net.ReadInt( 16 )
    s.grade = net.ReadString()
    s.shiftCalls = net.ReadUInt( 16 )
    s.shiftSaved = net.ReadUInt( 16 )
    s.shiftLost = net.ReadUInt( 16 )
    s.shiftScore = net.ReadInt( 32 )

    if IsValid( chart ) then
        chart:Close()
    end

    showSummary( s )
end )
