-- Paramedic Response: co-op ambulance shifts on top of Sandbox. Dispatch sends you to crash
-- scenes with ragdoll patients; assess and treat them, log-roll them onto a spine board,
-- load them into your ambulance and get them to the hospital alive.
-- Loader: shared files first, then client files, then server files.

ParamedicResponse = ParamedicResponse or {}

local BASE = "paramedic_response/"

local SHARED_FILES = {
    "sh_config.lua",
}

local CLIENT_FILES = {
    "cl_hud.lua",
    "cl_chart.lua",
}

local SERVER_FILES = {
    "sv_util.lua",
    "sv_patients.lua",
    "sv_transport.lua",
    "sv_dispatch.lua",
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
