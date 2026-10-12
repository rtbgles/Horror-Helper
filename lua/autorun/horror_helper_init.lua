-- Horror Helper: "Until Sunrise", a home-defense slasher round played on top of Sandbox.
-- Loader: shared files first, then client files, then server files.

HorrorHelper = HorrorHelper or {}

local BASE = "horror_helper/"

local SHARED_FILES = {
    "sh_config.lua",
    "sh_round.lua",
}

local CLIENT_FILES = {
    "cl_atmosphere.lua",
    "cl_hud.lua",
    "cl_lobby.lua",
    "cl_intro.lua",
    "cl_menu.lua",
}

local SERVER_FILES = {
    "sv_util.lua",
    "sv_cabins.lua",
    "sv_round.lua",
    "sv_director.lua",
}

for _, name in ipairs( SHARED_FILES ) do
    if SERVER then AddCSLuaFile( BASE .. name ) end
    include( BASE .. name )
end

for _, name in ipairs( CLIENT_FILES ) do
    if SERVER then
        AddCSLuaFile( BASE .. name )
    else
        include( BASE .. name )
    end
end

if SERVER then
    for _, name in ipairs( SERVER_FILES ) do
        include( BASE .. name )
    end
end
