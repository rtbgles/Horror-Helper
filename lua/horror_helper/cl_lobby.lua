-- The waiting room: shown to everyone while the round is in the lobby phase.
-- Pick a hideout, ready up; the night starts once everyone is ready (or an admin starts it).
-- "Hide" closes it; `!lobby` in chat or `hh_lobby_menu` brings it back.

local HH = HorrorHelper
local UI = HH.UI

local LOBBY_ACTION_READY = 1
local LOBBY_ACTION_VOTE = 2
local LOBBY_ACTION_REQUEST = 3

local P = HH.PALETTE
local COLORS = {
    backdrop = Color( 10, 8, 9, 242 ),
    button = Color( 24, 20, 21, 235 ),
    buttonHover = Color( 44, 34, 35, 235 ),
    row = Color( 255, 255, 255, 6 ),
}
local HOVER_SPEED = 8 -- how fast buttons light up under the cursor (per second)
local COUNTDOWN_TICKS_FROM = 5 -- tick each of the last few seconds
local TICK_SOUND = "buttons/lightswitch2.wav"

local lobby = HH.LobbyState or { panel = nil, dismissed = false, cabins = {} }
HH.LobbyState = lobby

local function send( action, writer )
    net.Start( "HH_Lobby" )
    net.WriteUInt( action, 3 )
    if writer then writer() end
    net.SendToServer()
end

local function isReady( ply )
    return ply:IsBot() or ply:GetNW2Bool( "HH_Ready", false )
end

--[[ Buttons: accent when active, a soft lift on hover ]]

local function makeButton( parent, text, onClick, isActive )
    local btn = vgui.Create( "DButton", parent )
    btn:SetText( "" )
    btn.hover = 0
    btn.DoClick = onClick
    btn.OnCursorEntered = function( self ) self.hovering = true end
    btn.OnCursorExited = function( self ) self.hovering = false end
    btn.Paint = function( self, w, h )
        self.hover = math.Approach( self.hover, self.hovering and 1 or 0, FrameTime() * HOVER_SPEED )

        local active = isActive and isActive() or false
        local bg = active and P.blood or ( self.hover > 0.5 and COLORS.buttonHover or COLORS.button )
        draw.RoundedBox( 4, 0, 0, w, h, bg )

        surface.SetDrawColor( P.blood.r, P.blood.g, P.blood.b, active and 255 or ( 60 + 120 * self.hover ) )
        surface.DrawOutlinedRect( 0, 0, w, h, 1 )

        local label = isfunction( text ) and text() or text
        draw.SimpleText( UI.FitText( label, "HH_Small", w - 16 ), "HH_Small", w * 0.5, h * 0.5, P.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    end

    return btn
end

local function voteCount( index )
    local count = 0
    for _, ply in player.Iterator() do
        if ply:GetNW2Int( "HH_Vote", 0 ) == index then
            count = count + 1
        end
    end

    return count
end

--[[ Hideout list ]]

local function rebuildCabins()
    local panel = lobby.panel
    if not IsValid( panel ) or not IsValid( panel.cabinList ) then return end

    panel.cabinList:Clear()
    local canvas = panel.cabinList:GetCanvas()
    local rowH = math.Round( ScrH() * 0.05 )

    for index, name in ipairs( lobby.cabins ) do
        local row = makeButton( canvas, function()
            local votes = voteCount( index )
            return name .. ( votes > 0 and ( "    ·  " .. votes .. " vote" .. ( votes == 1 and "" or "s" ) ) or "" )
        end, function()
            send( LOBBY_ACTION_VOTE, function() net.WriteUInt( index, 8 ) end )
        end, function()
            return LocalPlayer():GetNW2Int( "HH_Vote", 0 ) == index
        end )

        row:Dock( TOP )
        row:DockMargin( 0, 0, 0, math.Round( ScrH() * 0.008 ) )
        row:SetTall( rowH )
    end

    if #lobby.cabins == 0 then
        local label = vgui.Create( "DLabel", canvas )
        label:SetFont( "HH_Small" )
        label:SetTextColor( P.dim )
        label:SetText( "Loading hideouts..." )
        label:SizeToContents()
        label:Dock( TOP )
    end
end

net.Receive( "HH_Cabins", function()
    lobby.cabins = {}

    local count = net.ReadUInt( 8 )
    for i = 1, count do
        lobby.cabins[i] = net.ReadString()
    end

    rebuildCabins()
end )

--[[ Survivor list: painted, one or two columns, "+N more" when even that won't fit ]]

local playerList = {}

local function paintSurvivors( _, w, h )
    draw.SimpleText( "SURVIVORS", "HH_Med", 0, 0, P.text )

    local top = draw.GetFontHeight( "HH_Med" ) * 1.6
    local lineH = math.Round( ScrH() * 0.036 )
    local fits = math.max( 1, math.floor( ( h - top ) / lineH ) )

    local players = playerList
    for i = #players, 1, -1 do players[i] = nil end
    for _, ply in player.Iterator() do
        players[#players + 1] = ply
    end

    local columns = #players > fits and 2 or 1
    local capacity = fits * columns
    local overflow = #players > capacity
    if overflow then
        capacity = capacity - 1 -- the last slot says how many more
    end

    local colW = w / columns
    local square = math.Round( lineH * 0.32 )

    for i, ply in ipairs( players ) do
        if i > capacity then break end

        local col = math.floor( ( i - 1 ) / fits )
        local rowIndex = ( i - 1 ) % fits
        local x = col * colW
        local y = top + rowIndex * lineH
        local ready = isReady( ply )

        if rowIndex % 2 == 0 then
            surface.SetDrawColor( COLORS.row )
            surface.DrawRect( x, y, colW - 12, lineH )
        end

        surface.SetDrawColor( ready and P.blood or P.faint )
        surface.DrawRect( x + 8, y + ( lineH - square ) * 0.5, square, square )

        local status = ply:IsBot() and "BOT" or ( ready and "READY" or "" )
        local statusW = UI.TextWidth( "HH_Tiny", "READY" ) + 16
        local nameW = colW - 12 - square - 24 - statusW

        draw.SimpleText( UI.FitText( ply:Nick(), "HH_Small", nameW ), "HH_Small", x + square + 18, y + lineH * 0.5, ready and P.text or P.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
        draw.SimpleText( status, "HH_Tiny", x + colW - 20, y + lineH * 0.5, P.blood, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER )
    end

    if overflow then
        local i = capacity + 1
        local x = math.floor( ( i - 1 ) / fits ) * colW
        local y = top + ( ( i - 1 ) % fits ) * lineH
        draw.SimpleText( "+ " .. ( #players - capacity ) .. " more", "HH_Small", x + square + 18, y + lineH * 0.5, P.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
    end
end

local function statusText()
    local total, ready = 0, 0
    for _, ply in player.Iterator() do
        total = total + 1
        if isReady( ply ) then
            ready = ready + 1
        end
    end

    local countdownEnd = GetGlobal2Float( "HH_PhaseEnd", 0 )
    if countdownEnd > 0 then
        return "The night begins in " .. math.max( 0, math.ceil( countdownEnd - CurTime() ) )
    end

    return string.format( "Waiting for everyone to ready up  (%d / %d)", ready, total )
end

--[[ The screen ]]

local function openLobby()
    local w, h = ScrW(), ScrH()

    local panel = vgui.Create( "EditablePanel" )
    lobby.panel = panel
    panel:SetSize( w, h )
    panel:MakePopup()
    -- Keep the keyboard free for chat and push-to-talk.
    panel:SetKeyboardInputEnabled( false )
    panel:DockPadding( w * 0.08, h * 0.07, w * 0.08, h * 0.05 )
    panel.OnRemove = function()
        if lobby.panel == panel then
            lobby.panel = nil
        end
    end
    panel.Paint = function( _, pw, ph )
        surface.SetDrawColor( COLORS.backdrop )
        surface.DrawRect( 0, 0, pw, ph )
        UI.EdgeGlow( pw, ph, P.blood.r, P.blood.g, P.blood.b, 22, 0.25 )
    end

    -- Header: the title, what tonight is, an accent rule.
    local header = vgui.Create( "Panel", panel )
    header:Dock( TOP )
    header:SetTall( h * 0.15 )
    header.Paint = function( _, pw, ph )
        draw.SimpleText( "UNTIL SUNRISE", "HH_Title", 0, ph * 0.42, P.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
        draw.SimpleText( "HOME DEFENSE  ·  WAITING ROOM", "HH_Small", 4, ph * 0.86, P.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM )

        local nightText = string.format( "THE NIGHT  %s MIN        THE KILLER  ???", HH.CV.night_minutes:GetString() )
        draw.SimpleText( nightText, "HH_Small", pw, ph * 0.86, P.dim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM )

        surface.SetDrawColor( P.blood )
        surface.DrawRect( 0, ph - 2, pw, 2 )
    end

    -- Footer: status line, then the buttons.
    local footer = vgui.Create( "Panel", panel )
    footer:Dock( BOTTOM )
    footer:SetTall( h * 0.2 )
    footer.Paint = function( _, pw, ph )
        draw.SimpleText( statusText(), "HH_Med", pw * 0.5, ph * 0.22, P.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
        draw.SimpleText( "Type !lobby in chat to bring this screen back.", "HH_Tiny", pw * 0.5, ph, P.faint, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM )
    end

    local buttonRow = vgui.Create( "Panel", footer )
    buttonRow:Dock( TOP )
    buttonRow:DockMargin( 0, h * 0.08, 0, 0 )
    buttonRow:SetTall( h * 0.06 )

    local readyBtn = makeButton( buttonRow, function()
        return LocalPlayer():GetNW2Bool( "HH_Ready", false ) and "NOT READY" or "READY"
    end, function()
        local nowReady = not LocalPlayer():GetNW2Bool( "HH_Ready", false )
        send( LOBBY_ACTION_READY, function() net.WriteBool( nowReady ) end )
    end, function()
        return LocalPlayer():GetNW2Bool( "HH_Ready", false )
    end )

    local hideBtn = makeButton( buttonRow, "HIDE", function()
        lobby.dismissed = true
        panel:Remove()
    end )

    local adminButtons = {}
    if LocalPlayer():IsAdmin() then
        adminButtons[1] = makeButton( buttonRow, "START NOW", function() RunConsoleCommand( "hh_start" ) end )
        adminButtons[2] = makeButton( buttonRow, "CANCEL", function() RunConsoleCommand( "hh_stop" ) end )
    end

    -- Ready and Hide centred; admin controls tucked to the right, smaller.
    buttonRow.PerformLayout = function( _, rw, rh )
        local bw = math.Round( w * 0.13 )
        local gap = math.Round( w * 0.006 )
        readyBtn:SetSize( bw, rh )
        readyBtn:SetPos( rw * 0.5 - bw - gap * 0.5, 0 )
        hideBtn:SetSize( bw, rh )
        hideBtn:SetPos( rw * 0.5 + gap * 0.5, 0 )

        local small = math.Round( bw * 0.75 )
        for i, btn in ipairs( adminButtons ) do
            btn:SetSize( small, math.Round( rh * 0.75 ) )
            btn:SetPos( rw - ( #adminButtons - i + 1 ) * ( small + gap ) + gap, rh * 0.125 )
        end
    end

    -- Body: survivors on the left, hideouts on the right.
    local body = vgui.Create( "Panel", panel )
    body:Dock( FILL )
    body:DockMargin( 0, h * 0.03, 0, 0 )

    local survivors = vgui.Create( "Panel", body )
    survivors:Dock( LEFT )
    survivors.Paint = paintSurvivors

    local hideouts = vgui.Create( "Panel", body )
    hideouts:Dock( FILL )
    hideouts:DockMargin( w * 0.04, 0, 0, 0 )
    hideouts:DockPadding( 0, draw.GetFontHeight( "HH_Med" ) * 1.6 + draw.GetFontHeight( "HH_Tiny" ), 0, 0 )
    hideouts.Paint = function()
        draw.SimpleText( "HIDEOUT", "HH_Med", 0, 0, P.text )
        draw.SimpleText( "Vote for where you'll hole up tonight.", "HH_Tiny", 0, draw.GetFontHeight( "HH_Med" ) * 1.05, P.dim )
    end

    body.PerformLayout = function( _, bw )
        survivors:SetWide( bw * 0.46 )
    end

    local cabinList = vgui.Create( "DScrollPanel", hideouts )
    cabinList:Dock( FILL )
    panel.cabinList = cabinList

    rebuildCabins()
    send( LOBBY_ACTION_REQUEST )
end

local lastTick

hook.Add( "Think", "HorrorHelper_Lobby", function()
    local inLobby = HH.GetPhase() == HH.PHASE_LOBBY

    if not inLobby then
        lobby.dismissed = false
        lastTick = nil
        if IsValid( lobby.panel ) then
            lobby.panel:Remove()
        end
        return
    end

    if not IsValid( lobby.panel ) and not lobby.dismissed then
        openLobby()
    end

    -- A quiet tick for the last seconds of the countdown, even with the screen hidden.
    local countdownEnd = GetGlobal2Float( "HH_PhaseEnd", 0 )
    if countdownEnd > 0 then
        local left = math.ceil( countdownEnd - CurTime() )
        if left > 0 and left <= COUNTDOWN_TICKS_FROM and left ~= lastTick then
            lastTick = left
            HH.PlayFlat( TICK_SOUND, 0.5 )
        end
    else
        lastTick = nil
    end
end )

-- A new resolution: build it again at the new size.
hook.Add( "OnScreenSizeChanged", "HorrorHelper_Lobby", function()
    if IsValid( lobby.panel ) then
        lobby.panel:Remove()
    end
end )

concommand.Add( "hh_lobby_menu", function()
    lobby.dismissed = false
end )

hook.Add( "OnPlayerChat", "HorrorHelper_Lobby", function( ply, text )
    if string.lower( string.Trim( text ) ) ~= "!lobby" then return end

    if ply == LocalPlayer() then
        lobby.dismissed = false
    end

    -- Nobody needs to see the command in chat.
    return true
end )
