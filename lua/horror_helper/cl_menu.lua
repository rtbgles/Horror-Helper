-- Admin menu: spawn menu > Utilities > Horror Helper.
-- Settings are sent through `hh_set` (server convars can't be set from a client otherwise
-- on a dedicated server), so every control here is admin-only on the server side too.

local HH = HorrorHelper

local SEND_DELAY = 0.35 -- sliders send once you stop dragging
local NPC_LIST_HEIGHT = 260
local LABEL_COLOR = Color( 30, 30, 30 )

local function sendSet( name, value )
    timer.Create( "HorrorHelper_Set_" .. name, SEND_DELAY, 1, function()
        RunConsoleCommand( "hh_set", name, tostring( value ) )
    end )
end

local function adminGate( cpanel )
    if IsValid( LocalPlayer() ) and LocalPlayer():IsAdmin() then return true end

    cpanel:Help( "Only admins can change Horror Helper settings." )
    return false
end

local function addSetting( cpanel, info )
    local cvar = GetConVar( info.name )
    if not cvar then return end

    if info.kind == "bool" then
        local box = vgui.Create( "DCheckBoxLabel", cpanel )
        box:SetText( info.help )
        box:SetTextColor( LABEL_COLOR )
        box:SetChecked( cvar:GetBool() )
        box.OnChange = function( _, checked )
            sendSet( info.name, checked and 1 or 0 )
        end
        cpanel:AddItem( box )
        return
    end

    if info.kind == "int" or info.kind == "float" then
        local slider = vgui.Create( "DNumSlider", cpanel )
        slider:SetText( info.short )
        slider:SetMinMax( info.min or 0, info.max or 100 )
        slider:SetDecimals( info.kind == "int" and 0 or 2 )
        slider:SetValue( cvar:GetFloat() )
        slider:SetDark( true )
        slider.OnValueChanged = function( _, value )
            sendSet( info.name, info.kind == "int" and math.Round( value ) or value )
        end
        cpanel:AddItem( slider )
        cpanel:ControlHelp( info.help )
        return
    end

    cpanel:Help( info.short .. ": " .. info.help )
    local entry = vgui.Create( "DTextEntry", cpanel )
    entry:SetValue( cvar:GetString() )
    entry:SetPlaceholderText( "press Enter to apply" )
    entry.OnEnter = function( self )
        sendSet( info.name, self:GetValue() )
    end
    cpanel:AddItem( entry )
end

local function addCategory( cpanel, category, skip )
    for _, info in ipairs( HH.CvarList ) do
        if info.category == category and not ( skip and skip[info.short] ) then
            addSetting( cpanel, info )
        end
    end
end

--[[ Killer picker: every NPC the server knows, filterable; double-click to use it ]]

local function addKillerPicker( cpanel )
    cpanel:Help( "THE KILLER. Paste an NPC class, or double-click one in the list below. Then press Enter." )

    local classEntry = vgui.Create( "DTextEntry", cpanel )
    classEntry:SetValue( HH.CV.killer_class:GetString() )
    classEntry.OnEnter = function( self )
        sendSet( "hh_killer_class", string.Trim( self:GetValue() ) )
    end
    cpanel:AddItem( classEntry )

    local filter = vgui.Create( "DTextEntry", cpanel )
    filter:SetPlaceholderText( "Filter NPCs (name, category or class)..." )
    cpanel:AddItem( filter )

    local listView = vgui.Create( "DListView", cpanel )
    listView:SetTall( NPC_LIST_HEIGHT )
    listView:SetMultiSelect( false )
    listView:AddColumn( "Name" )
    listView:AddColumn( "Category" )
    listView:AddColumn( "Class" )
    cpanel:AddItem( listView )

    local function fill()
        listView:Clear()
        local needle = string.lower( string.Trim( filter:GetValue() or "" ) )

        for class, entry in pairs( list.Get( "NPC" ) ) do
            local name = isstring( entry.Name ) and entry.Name or class
            local category = isstring( entry.Category ) and entry.Category or ""
            local haystack = string.lower( name .. " " .. category .. " " .. class )

            if needle == "" or string.find( haystack, needle, 1, true ) then
                listView:AddLine( name, category, class )
            end
        end

        listView:SortByColumn( 2 )
    end

    filter.OnChange = fill
    listView.DoDoubleClick = function( _, _, line )
        local class = line:GetColumnText( 3 )
        classEntry:SetValue( class )
        sendSet( "hh_killer_class", class )
    end

    fill()

    cpanel:Button( "Test: spawn the killer where I'm looking", "hh_killer_test" )
    cpanel:ControlHelp( "Spawns it as a normal NPC so you can check the class works. Undo removes it." )
end

--[[ Pages ]]

local function buildRoundPage( cpanel )
    if not adminGate( cpanel ) then return end

    cpanel:Help( "UNTIL SUNRISE: hole up in a cabin, scavenge fuses and planks, survive the killer until dawn." )
    cpanel:Button( "Open the waiting room", "hh_lobby" )
    cpanel:Button( "Start now", "hh_start" )
    cpanel:Button( "Stop the round", "hh_stop" )

    addKillerPicker( cpanel )
    addCategory( cpanel, "Killer", { killer_class = true } )

    cpanel:Help( "THE NIGHT" )
    addCategory( cpanel, "Night" )

    cpanel:Help( "SCAVENGING" )
    addCategory( cpanel, "Scavenging" )
end

local function buildDirectorPage( cpanel )
    if not adminGate( cpanel ) then return end

    cpanel:Help( "The director decides when and where the killer shows up. It appears by hh_first_contact seconds, then again at shrinking gaps: watching a survivor from the dark (and sometimes coming for them), chasing a scavenger home, or prowling around the cabin testing the boards. The full attack on the cabin waits for enough setup progress (rolled each night) or a deadline. Dread climbs all night and makes the psychological scares more frequent and nastier." )
    addCategory( cpanel, "Director" )

    cpanel:Help( "ATMOSPHERE" )
    addCategory( cpanel, "Atmosphere" )

    cpanel:Help( "DEBUG" )
    addCategory( cpanel, "Debug" )
end

local function buildCabinPage( cpanel )
    if not adminGate( cpanel ) then return end

    cpanel:Help( "Setting up a cabin (saved per map):\n1. Spawn the pieces below and put them in place. Barricades show their size as an orange box: stand doors on the floor in a doorway, cover windows with the window one.\n2. Stand in the middle of the cabin, type a name, press Save.\nRadius 0 works it out from the pieces. Survivors start at the spot you saved from." )

    cpanel:Button( "Spawn Fuse Box", "gm_spawnsent", "hh_fusebox" )
    cpanel:Button( "Spawn Door Barricade", "gm_spawnsent", "hh_barricade" )
    cpanel:Button( "Spawn Window Barricade", "gm_spawnsent", "hh_barricade_window" )
    cpanel:Button( "Spawn Cabin Lamp", "gm_spawnsent", "hh_lamp" )

    local nameEntry = vgui.Create( "DTextEntry", cpanel )
    nameEntry:SetPlaceholderText( "Cabin name, e.g. Lakeside" )
    cpanel:AddItem( nameEntry )

    local radius = vgui.Create( "DNumSlider", cpanel )
    radius:SetText( "Radius (0 = auto)" )
    radius:SetMinMax( 0, 3000 )
    radius:SetDecimals( 0 )
    radius:SetValue( 0 )
    radius:SetDark( true )
    cpanel:AddItem( radius )

    local function withName( fn )
        local name = string.Trim( nameEntry:GetValue() or "" )
        if name == "" then
            chat.AddText( "[Horror Helper] Type a cabin name first." )
            return
        end

        fn( name )
    end

    local save = cpanel:Button( "Save cabin here" )
    save.DoClick = function()
        withName( function( name )
            local r = math.Round( radius:GetValue() )
            if r > 0 then
                RunConsoleCommand( "hh_cabin_save", name, tostring( r ) )
            else
                RunConsoleCommand( "hh_cabin_save", name )
            end
        end )
    end

    local edit = cpanel:Button( "Load it back to edit" )
    edit.DoClick = function()
        withName( function( name ) RunConsoleCommand( "hh_cabin_edit", name ) end )
    end

    local delete = cpanel:Button( "Delete it" )
    delete.DoClick = function()
        withName( function( name ) RunConsoleCommand( "hh_cabin_delete", name ) end )
    end

    cpanel:Button( "List saved cabins", "hh_cabin_list" )
    cpanel:Button( "Remove all placed pieces", "hh_cabin_clear" )
    cpanel:ControlHelp( "Items (fuses, planks) are scattered automatically each round. A navmesh (nav_generate) makes that and the killer's placement much better." )
end

hook.Add( "PopulateToolMenu", "HorrorHelper_Menu", function()
    spawnmenu.AddToolMenuOption( "Utilities", "Horror Helper", "hh_round", "Round & Killer", "", "", buildRoundPage )
    spawnmenu.AddToolMenuOption( "Utilities", "Horror Helper", "hh_director", "Director & Atmosphere", "", "", buildDirectorPage )
    spawnmenu.AddToolMenuOption( "Utilities", "Horror Helper", "hh_cabins", "Cabin Setup", "", "", buildCabinPage )
end )
