-- Cabin lamp: part of a cabin layout. Dark until the fuse boxes are full.

AddCSLuaFile()

HorrorHelper = HorrorHelper or {}
local HH = HorrorHelper

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Cabin Lamp"
ENT.Category = "Horror Helper"
ENT.Author = "Horror Helper"
ENT.Instructions = "Part of a cabin layout. Lights up once the cabin has power."
ENT.Spawnable = true
ENT.AdminOnly = true

local LIGHT_SIZE = 420
local LIGHT_BRIGHTNESS = 2
local LIGHT_ID_OFFSET = 4096 -- keep clear of other addons using entity indexes as light ids

function ENT:Initialize()
    if CLIENT then return end

    self:SetModel( HH.SafeModel( HH.Models.lamp ) )
    self:PhysicsInit( SOLID_VPHYSICS )
    self:SetMoveType( MOVETYPE_VPHYSICS )
    self:SetSolid( SOLID_VPHYSICS )

    local phys = self:GetPhysicsObject()
    if IsValid( phys ) then
        phys:EnableMotion( false )
    end
end

if SERVER then
    function ENT:SpawnFunction( ply, tr, className )
        if not tr.Hit then return end

        local ent = ents.Create( className )
        ent:SetPos( tr.HitPos + tr.HitNormal * 8 )
        ent:SetAngles( Angle( 0, ply:EyeAngles().y + 180, 0 ) )
        ent:Spawn()
        ent:Activate()

        return ent
    end
end

if CLIENT then
    function ENT:Draw()
        self:DrawModel()
    end

    function ENT:Think()
        if HH.GetPhase() ~= HH.PHASE_NIGHT or not GetGlobal2Bool( "HH_Power", false ) then return end
        if CurTime() < GetGlobal2Float( "HH_PowerCutUntil", 0 ) then return end
        if HH.IsLampFlickering and HH.IsLampFlickering( self ) then return end

        local light = DynamicLight( self:EntIndex() + LIGHT_ID_OFFSET )
        if not light then return end

        local flutter = 1 + 0.06 * math.sin( CurTime() * 9 + self:EntIndex() )
        light.pos = self:WorldSpaceCenter() + Vector( 0, 0, self:OBBMaxs().z * 0.5 )
        light.r = 255
        light.g = 190
        light.b = 120
        light.brightness = LIGHT_BRIGHTNESS * flutter
        light.size = LIGHT_SIZE
        light.decay = 1000
        light.dietime = CurTime() + 0.2
    end
end
