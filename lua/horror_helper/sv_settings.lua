--[[
    Settings that stick, per map.

    Every hh_ setting you change (menu, hh_set, or typed into the server console) is saved for
    the map you're on, in data/horror_helper/settings/<map>.json, a second after the change.
    When that map loads again, its settings come back.

    A map you haven't set anything on uses the defaults profile, if you saved one
    (hh_settings_save_defaults, data/horror_helper/settings/_defaults.json), otherwise whatever
    the convars already are.

      hh_settings_save_defaults   use this map's settings as the defaults for maps without their own
      hh_settings_forget_map      drop this map's saved settings and go back to the defaults
      hh_settings_status          print where the current settings came from

    Loaded settings win over server.cfg, so a value set there is overridden on maps that
    have their own profile.
]]

local HH = HorrorHelper

local DIR = "horror_helper/settings"
local DEFAULTS_FILE = DIR .. "/_defaults.json"
local SAVE_DELAY = 1 -- seconds after the last change before writing (sliders send several)
local SWEEP_INTERVAL = 15 -- backstop: also look for unsaved changes this often
local FORMAT_VERSION = 1

-- Kept on HH so a Lua refresh mid-map doesn't forget what was loaded.
-- baseline: the settings right after loading, so merely visiting a map doesn't create a
-- profile for it. lastSaved: what's on disk now.
local state = HH.SettingsState or { loaded = false, baseline = {}, lastSaved = {} }
HH.SettingsState = state

local function mapFile()
    return DIR .. "/" .. game.GetMap() .. ".json"
end

local function snapshot()
    local values = {}
    for _, info in ipairs( HH.CvarList ) do
        values[info.name] = GetConVar( info.name ):GetString()
    end

    return values
end

local function sameValues( a, b )
    for _, info in ipairs( HH.CvarList ) do
        if a[info.name] ~= b[info.name] then return false end
    end

    return true
end

local function readProfile( path )
    local raw = file.Read( path, "DATA" )
    if not raw then return nil end

    local ok, data = pcall( util.JSONToTable, raw, false, true )
    if not ok or not istable( data ) or not istable( data.settings ) then
        print( "[Horror Helper] Couldn't read " .. path .. ", ignoring it." )
        return nil
    end

    return data.settings
end

local function writeProfile( path, values )
    file.CreateDir( DIR )
    file.Write( path, util.TableToJSON( {
        version = FORMAT_VERSION,
        map = game.GetMap(),
        saved = os.time(),
        settings = values,
    }, true ) )
end

local function apply( values )
    local count = 0

    for name, value in pairs( values ) do
        -- Only known settings, and only plain values: the file is data, not commands.
        if HH.CvarByName[name] and ( isstring( value ) or isnumber( value ) ) then
            GetConVar( name ):SetString( tostring( value ) )
            count = count + 1
        end
    end

    return count
end

local function setSource( source )
    SetGlobal2String( "HH_SettingsSource", source )
end

function HH.LoadMapSettings()
    local mapValues = readProfile( mapFile() )
    local source = "none"

    if mapValues then
        apply( mapValues )
        source = "map"
    else
        local defaults = readProfile( DEFAULTS_FILE )
        if defaults then
            apply( defaults )
            source = "defaults"
        end
    end

    -- Changes made while applying (and their callbacks) aren't "your" changes.
    state.baseline = snapshot()
    state.lastSaved = state.baseline
    state.loaded = true
    setSource( source )

    print( "[Horror Helper] Settings for " .. game.GetMap() .. ": " .. ( {
        map = "loaded this map's saved settings.",
        defaults = "no saved settings for this map, using your defaults.",
        none = "nothing saved yet; changes you make will be saved for this map.",
    } )[source] )
end

function HH.SaveMapSettings()
    if not state.loaded then return end

    local values = snapshot()
    local hasProfile = file.Exists( mapFile(), "DATA" )

    -- Nothing changed since the map loaded: don't make a profile just for visiting.
    if not hasProfile and sameValues( values, state.baseline ) then return end

    writeProfile( mapFile(), values )
    state.lastSaved = values
    setSource( "map" )
    HH.Debug( "saved settings for", game.GetMap() )
end

local function scheduleSave()
    timer.Create( "HorrorHelper_SaveSettings", SAVE_DELAY, 1, HH.SaveMapSettings )
end
HH.ScheduleSettingsSave = scheduleSave

-- Catch every change, wherever it comes from (menu, hh_set, console, rcon). hh_set also
-- saves directly, and the sweep below catches anything a callback misses.
for _, info in ipairs( HH.CvarList ) do
    cvars.AddChangeCallback( info.name, function()
        if state.loaded then
            scheduleSave()
        end
    end, "HorrorHelper_Settings" )
end

timer.Create( "HorrorHelper_SettingsSweep", SWEEP_INTERVAL, 0, function()
    if state.loaded and not sameValues( snapshot(), state.lastSaved ) then
        HH.SaveMapSettings()
    end
end )

hook.Add( "InitPostEntity", "HorrorHelper_LoadSettings", HH.LoadMapSettings )

-- Save on the way out too, in case the map changes inside the save delay.
hook.Add( "ShutDown", "HorrorHelper_SaveSettings", function()
    if timer.Exists( "HorrorHelper_SaveSettings" ) then
        timer.Remove( "HorrorHelper_SaveSettings" )
        HH.SaveMapSettings()
    end
end )

--[[ Commands ]]

local function adminOnly( ply )
    if HH.IsAdmin( ply ) then return true end

    HH.Notify( ply, "Admins only." )
    return false
end

concommand.Add( "hh_settings_save_defaults", function( ply )
    if not adminOnly( ply ) then return end

    writeProfile( DEFAULTS_FILE, snapshot() )
    HH.Notify( ply, "Saved the current settings as the defaults for maps without their own." )
end )

concommand.Add( "hh_settings_forget_map", function( ply )
    if not adminOnly( ply ) then return end

    timer.Remove( "HorrorHelper_SaveSettings" )
    if file.Exists( mapFile(), "DATA" ) then
        file.Delete( mapFile() )
    end

    local defaults = readProfile( DEFAULTS_FILE )
    if defaults then
        apply( defaults )
    end
    -- With no profile and nothing changed since this baseline, the saves the apply above
    -- triggers write nothing.
    state.baseline = snapshot()
    state.lastSaved = state.baseline
    setSource( defaults and "defaults" or "none" )

    HH.Notify( ply, defaults and "Forgot this map's settings; back to your defaults." or "Forgot this map's settings. (No defaults saved, so current values stay until you change them.)" )
end )

concommand.Add( "hh_settings_status", function( ply )
    local source = GetGlobal2String( "HH_SettingsSource", "none" )
    local where = ( {
        map = "this map's saved settings (" .. mapFile() .. ")",
        defaults = "your defaults (" .. DEFAULTS_FILE .. ")",
        none = "nothing saved yet",
    } )[source] or source

    HH.Notify( ply, "Settings on " .. game.GetMap() .. " come from " .. where .. "." )
end )
