--[[
    Cabin layouts, saved per map in data/horror_helper/<map>.json.

    Setting one up:
      1. Spawn Fuse Boxes, Door/Window Barricades and Cabin Lamps from the spawn menu
         (Entities > Horror Helper) and put them where they belong.
      2. Stand in the middle of the cabin and run `hh_cabin_save <name> [radius]`.
    `hh_cabin_edit <name>` brings a saved layout back to adjust it; save again to overwrite.
]]

local HH = HorrorHelper

local DATA_DIR = "horror_helper"
local COLLECT_RADIUS = 1600 -- setup pieces this close to you are part of the cabin you save
local RADIUS_PADDING = 160
local MIN_RADIUS = 250
local MAX_NAME_LENGTH = 32

HH.Cabins = HH.Cabins or {}

local function dataPath()
    return DATA_DIR .. "/" .. game.GetMap() .. ".json"
end

local function vecToList( v )
    return { v.x, v.y, v.z }
end

local function listToVec( t )
    return Vector( tonumber( t[1] ) or 0, tonumber( t[2] ) or 0, tonumber( t[3] ) or 0 )
end

local function angToList( a )
    return { a.p, a.y, a.r }
end

local function listToAng( t )
    return Angle( tonumber( t[1] ) or 0, tonumber( t[2] ) or 0, tonumber( t[3] ) or 0 )
end

function HH.LoadCabins()
    HH.Cabins = {}

    local raw = file.Read( dataPath(), "DATA" )
    if not raw then return end

    local data = util.JSONToTable( raw )
    if not istable( data ) or not istable( data.cabins ) then
        print( "[Horror Helper] Could not read " .. dataPath() .. ", ignoring it." )
        return
    end

    for _, cabin in ipairs( data.cabins ) do
        if isstring( cabin.name ) and istable( cabin.center ) then
            local pieces = {}

            for _, piece in ipairs( cabin.pieces or {} ) do
                if isstring( piece.class ) and HH.SETUP_CLASSES[piece.class] then
                    table.insert( pieces, {
                        class = piece.class,
                        pos = listToVec( piece.pos or {} ),
                        ang = listToAng( piece.ang or {} ),
                    } )
                end
            end

            table.insert( HH.Cabins, {
                name = cabin.name,
                center = listToVec( cabin.center ),
                radius = tonumber( cabin.radius ) or 600,
                pieces = pieces,
            } )
        end
    end
end

function HH.SaveCabins()
    local out = { cabins = {} }

    for _, cabin in ipairs( HH.Cabins ) do
        local pieces = {}

        for _, piece in ipairs( cabin.pieces ) do
            table.insert( pieces, {
                class = piece.class,
                pos = vecToList( piece.pos ),
                ang = angToList( piece.ang ),
            } )
        end

        table.insert( out.cabins, {
            name = cabin.name,
            center = vecToList( cabin.center ),
            radius = cabin.radius,
            pieces = pieces,
        } )
    end

    file.CreateDir( DATA_DIR )
    file.Write( dataPath(), util.TableToJSON( out, true ) )
end

function HH.FindCabin( name )
    local lower = string.lower( name )

    for i, cabin in ipairs( HH.Cabins ) do
        if string.lower( cabin.name ) == lower then return cabin, i end
    end

    return nil
end

-- Spawns a layout's pieces. forRound pieces are locked in place and removed after the round.
function HH.SpawnCabinPieces( cabin, forRound )
    local spawned = {}

    for _, piece in ipairs( cabin.pieces ) do
        local ent = ents.Create( piece.class )

        if IsValid( ent ) then
            ent:SetPos( piece.pos )
            ent:SetAngles( piece.ang )
            if forRound then
                ent:SetNW2Bool( "HH_RoundEnt", true )
            end
            ent:Spawn()
            ent:Activate()
            table.insert( spawned, ent )
        end
    end

    return spawned
end

-- Removes setup pieces that were placed by hand (not the ones a round spawned).
function HH.ClearPlacedPieces()
    local removed = 0

    for _, ent in ents.Iterator() do
        if HH.SETUP_CLASSES[ent:GetClass()] and not ent:GetNW2Bool( "HH_RoundEnt", false ) then
            ent:Remove()
            removed = removed + 1
        end
    end

    return removed
end

local function adminOnly( ply )
    if HH.IsAdmin( ply ) then return true end

    HH.Notify( ply, "Only admins can set up cabins." )
    return false
end

concommand.Add( "hh_cabin_save", function( ply, _, args )
    if not adminOnly( ply ) then return end
    if not IsValid( ply ) then
        print( "[Horror Helper] Run this in game, standing in the middle of the cabin." )
        return
    end
    if HH.InRound() then
        HH.Notify( ply, "Not during a round." )
        return
    end

    local name = string.Trim( args[1] or "" )
    if name == "" then
        HH.Notify( ply, "Usage: hh_cabin_save <name> [radius]" )
        return
    end
    name = string.sub( name, 1, MAX_NAME_LENGTH )

    local center = ply:GetPos()
    local pieces = {}
    local farthest = 0

    for _, ent in ents.Iterator() do
        if HH.SETUP_CLASSES[ent:GetClass()] and not ent:GetNW2Bool( "HH_RoundEnt", false ) then
            local dist = ent:GetPos():Distance( center )

            if dist <= COLLECT_RADIUS then
                table.insert( pieces, { class = ent:GetClass(), pos = ent:GetPos(), ang = ent:GetAngles() } )
                farthest = math.max( farthest, dist )
            end
        end
    end

    local radius = tonumber( args[2] ) or math.max( MIN_RADIUS, farthest + RADIUS_PADDING )
    local cabin = { name = name, center = center, radius = radius, pieces = pieces }

    local _, index = HH.FindCabin( name )
    if index then
        HH.Cabins[index] = cabin
    else
        table.insert( HH.Cabins, cabin )
    end

    HH.SaveCabins()
    HH.Notify( ply, string.format( "Saved cabin '%s': %d pieces, radius %d.", name, #pieces, radius ) )

    if #pieces == 0 then
        HH.Notify( ply, "No fuse boxes, barricades or lamps were near you. Place some, then save again." )
    end
end )

concommand.Add( "hh_cabin_edit", function( ply, _, args )
    if not adminOnly( ply ) then return end
    if HH.InRound() then return end

    local cabin = HH.FindCabin( args[1] or "" )
    if not cabin then
        HH.Notify( ply, "No cabin called '" .. tostring( args[1] ) .. "'. Try hh_cabin_list." )
        return
    end

    local spawned = HH.SpawnCabinPieces( cabin, false )
    HH.Notify( ply, string.format( "Spawned %d pieces of '%s'. Move them, then hh_cabin_save %s from the cabin's middle.", #spawned, cabin.name, cabin.name ) )

    if IsValid( ply ) then
        ply:SetPos( cabin.center )
    end
end )

concommand.Add( "hh_cabin_delete", function( ply, _, args )
    if not adminOnly( ply ) then return end

    local cabin, index = HH.FindCabin( args[1] or "" )
    if not cabin then
        HH.Notify( ply, "No cabin called '" .. tostring( args[1] ) .. "'." )
        return
    end

    table.remove( HH.Cabins, index )
    HH.SaveCabins()
    HH.Notify( ply, "Deleted cabin '" .. cabin.name .. "'." )
end )

concommand.Add( "hh_cabin_list", function( ply )
    if #HH.Cabins == 0 then
        HH.Notify( ply, "No cabins saved on " .. game.GetMap() .. " yet." )
        return
    end

    for _, cabin in ipairs( HH.Cabins ) do
        HH.Notify( ply, string.format( "%s  (%d pieces, radius %d)", cabin.name, #cabin.pieces, cabin.radius ) )
    end
end )

concommand.Add( "hh_cabin_clear", function( ply )
    if not adminOnly( ply ) then return end
    if HH.InRound() then return end

    HH.Notify( ply, "Removed " .. HH.ClearPlacedPieces() .. " placed pieces." )
end )

hook.Add( "InitPostEntity", "HorrorHelper_LoadCabins", HH.LoadCabins )

-- Lua refresh: the map is already loaded, so read the file now.
if #HH.Cabins == 0 then
    HH.LoadCabins()
end
