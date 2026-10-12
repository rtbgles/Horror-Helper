-- The waiting room: shown to everyone while the round is in the lobby phase.
-- Pick a hideout, ready up; the night starts once everyone is ready (or an admin starts it).
-- "Hide" closes it; `!lobby` in chat or `hh_lobby_menu` brings it back.

local HH = HorrorHelper

local LOBBY_ACTION_READY = 1
local LOBBY_ACTION_VOTE = 2
local LOBBY_ACTION_REQUEST = 3

local P = HH.PALETTE
local BUTTON_BG = Color( 20, 19, 20, 230 )
local BUTTON_HOVER = Color( 40, 36, 36, 230 )

local lobby = HH.LobbyState or { panel = nil, dismissed = false, cabins = {} }
HH.LobbyState = lobby

local function send( action, writer )
    net.Start( "HH_Lobby" )
    net.WriteUInt( action, 3 )
    if writer then writer() end
    net.SendToServer()
end

local function paintButton( btn, w, h, active )
    local hovered = btn:IsHovered()
    local bg = active and P.blood or ( hovered and BUTTON_HOVER or BUTTON_BG )

    draw.RoundedBox( 4, 0, 0, w, h, bg )
    surface.SetDrawColor( P.blood.r, P.blood.g, P.blood.b, active and 255 or ( hovered and 160 or 60 ) )
    surface.DrawOutlinedRect( 0, 0, w, h, 1 )
end

local function makeButton( parent, text, onClick, isActive )
    local btn = vgui.Create( "DButton", parent )
    btn:SetText( "" )
    btn.DoClick = onClick
    btn.Paint = function( self, w, h )
        local active = isActive and isActive() or false
        paintButton( self, w, h, active )
        draw.SimpleText( isfunction( text ) and text() or text, "HH_Small", w * 0.5, h * 0.5, P.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
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

local function rebuildCabins()
    local panel = lobby.panel
    if not IsValid( panel ) or not IsValid( panel.cabinList ) then return end

    panel.cabinList:Clear()
    local canvas = panel.cabinList:GetCanvas()

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
        row:DockMargin( 0, 0, 0, ScrH() * 0.008 )
        row:SetTall( ScrH() * 0.05 )
    end

    if #lobby.cabins == 0 then
        local label = vgui.Create( "DLabel", canvas )
        label:SetFont( "HH_Small" )
        label:SetTextColor( P.dim )
        label:SetText( "Loading hideouts..." )
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

local function statusText()
    local total, ready = 0, 0
    for _, ply in player.Iterator() do
        total = total + 1
        if ply:GetNW2Bool( "HH_Ready", false ) then
            ready = ready + 1
        end
    end

    local countdownEnd = GetGlobal2Float( "HH_PhaseEnd", 0 )
    if countdownEnd > 0 then
        return "The night begins in " .. math.max( 0, math.ceil( countdownEnd - CurTime() ) )
    end

    return string.format( "Waiting for everyone to ready up  (%d / %d)", ready, total )
end

local function openLobby()
    local w, h = ScrW(), ScrH()

    local panel = vgui.Create( "EditablePanel" )
    lobby.panel = panel
    panel:SetSize( w, h )
    panel:MakePopup()
    -- Keep the keyboard free for chat and push-to-talk.
    panel:SetKeyboardInputEnabled( false )

    panel.Paint = function( _, pw, ph )
        surface.SetDrawColor( 5, 5, 7, 238 )
        surface.DrawRect( 0, 0, pw, ph )
        surface.SetDrawColor( P.blood.r, P.blood.g, P.blood.b, 255 )
        surface.DrawRect( pw * 0.08, ph * 0.205, pw * 0.84, 2 )

        draw.SimpleText( "UNTIL SUNRISE", "HH_Title", pw * 0.08, ph * 0.08, P.text )
        draw.SimpleText( "HOME DEFENSE  ·  WAITING ROOM", "HH_Small", pw * 0.083, ph * 0.17, P.dim )

        local nightText = string.format( "THE NIGHT  %s MIN        THE KILLER  ???", HH.CV.night_minutes:GetString() )
        draw.SimpleText( nightText, "HH_Small", pw * 0.92, ph * 0.17, P.dim, TEXT_ALIGN_RIGHT )

        draw.SimpleText( "SURVIVORS", "HH_Med", pw * 0.08, ph * 0.24, P.text )
        draw.SimpleText( "HIDEOUT", "HH_Med", pw * 0.52, ph * 0.24, P.text )
        draw.SimpleText( "Vote for where you'll hole up tonight.", "HH_Tiny", pw * 0.52, ph * 0.285, P.dim )

        local y = ph * 0.3
        local lineH = ph * 0.04
        for _, ply in player.Iterator() do
            local ready = ply:GetNW2Bool( "HH_Ready", false )
            surface.SetDrawColor( ready and P.blood or P.faint )
            surface.DrawRect( pw * 0.08, y + lineH * 0.3, lineH * 0.35, lineH * 0.35 )
            draw.SimpleText( ply:Nick(), "HH_Small", pw * 0.08 + lineH * 0.7, y + lineH * 0.47, ready and P.text or P.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
            draw.SimpleText( ready and "READY" or "", "HH_Tiny", pw * 0.45, y + lineH * 0.47, P.blood, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER )
            y = y + lineH
        end

        draw.SimpleText( statusText(), "HH_Med", pw * 0.5, ph * 0.8, P.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
        draw.SimpleText( "Type !lobby in chat to bring this screen back.", "HH_Tiny", pw * 0.5, ph * 0.965, P.faint, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
    end

    local cabinList = vgui.Create( "DScrollPanel", panel )
    cabinList:SetPos( w * 0.52, h * 0.32 )
    cabinList:SetSize( w * 0.4, h * 0.4 )
    panel.cabinList = cabinList

    local buttonW, buttonH = w * 0.14, h * 0.06
    local rowY = h * 0.86

    local readyBtn = makeButton( panel, function()
        return LocalPlayer():GetNW2Bool( "HH_Ready", false ) and "NOT READY" or "READY"
    end, function()
        local nowReady = not LocalPlayer():GetNW2Bool( "HH_Ready", false )
        send( LOBBY_ACTION_READY, function() net.WriteBool( nowReady ) end )
    end, function()
        return LocalPlayer():GetNW2Bool( "HH_Ready", false )
    end )
    readyBtn:SetSize( buttonW, buttonH )
    readyBtn:SetPos( w * 0.5 - buttonW - w * 0.005, rowY )

    local hideBtn = makeButton( panel, "HIDE", function()
        lobby.dismissed = true
        panel:Remove()
    end )
    hideBtn:SetSize( buttonW, buttonH )
    hideBtn:SetPos( w * 0.5 + w * 0.005, rowY )

    if LocalPlayer():IsAdmin() then
        local startBtn = makeButton( panel, "START NOW", function()
            RunConsoleCommand( "hh_start" )
        end )
        startBtn:SetSize( buttonW * 0.8, buttonH * 0.7 )
        startBtn:SetPos( w * 0.92 - buttonW * 1.65, h * 0.9 )

        local cancelBtn = makeButton( panel, "CANCEL", function()
            RunConsoleCommand( "hh_stop" )
        end )
        cancelBtn:SetSize( buttonW * 0.8, buttonH * 0.7 )
        cancelBtn:SetPos( w * 0.92 - buttonW * 0.8, h * 0.9 )
    end

    rebuildCabins()
    send( LOBBY_ACTION_REQUEST )
end

hook.Add( "Think", "HorrorHelper_Lobby", function()
    local inLobby = HH.GetPhase() == HH.PHASE_LOBBY

    if not inLobby then
        lobby.dismissed = false
        if IsValid( lobby.panel ) then
            lobby.panel:Remove()
        end
        return
    end

    if not IsValid( lobby.panel ) and not lobby.dismissed then
        openLobby()
    end
end )

concommand.Add( "hh_lobby_menu", function()
    lobby.dismissed = false
end )

hook.Add( "OnPlayerChat", "HorrorHelper_Lobby", function( ply, text )
    if ply ~= LocalPlayer() then return end
    if string.lower( string.Trim( text ) ) ~= "!lobby" then return end

    lobby.dismissed = false
end )
