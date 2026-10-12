-- Base for things survivors find out in the dark and carry back to the cabin.

AddCSLuaFile()

HorrorHelper = HorrorHelper or {}
local HH = HorrorHelper

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Horror Helper Item"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.ItemKind = "fuse"
ENT.ItemModelKey = "fuse"
ENT.ItemLabel = "item"
ENT.GlowColor = Color( 255, 220, 150 )

local GLOW_MAX_DIST = 1400 -- a faint glint so items can be found in the dark, not from across the map
local GLOW_SIZE = 18

function ENT:Initialize()
    if SERVER then
        self:SetModel( HH.SafeModel( HH.Models[self.ItemModelKey] ) )
        self:PhysicsInit( SOLID_VPHYSICS )
        self:SetMoveType( MOVETYPE_VPHYSICS )
        self:SetSolid( SOLID_VPHYSICS )
        self:SetCollisionGroup( COLLISION_GROUP_WEAPON )
        self:SetUseType( SIMPLE_USE )

        local phys = self:GetPhysicsObject()
        if IsValid( phys ) then
            phys:EnableMotion( false )
        end
    end
end

if SERVER then
    function ENT:Use( activator )
        if not IsValid( activator ) or not activator:IsPlayer() or not activator:Alive() then return end
        if HH.GetPhase() ~= HH.PHASE_NIGHT or HH.IsOut( activator ) then return end
        if not HH.TryCarry( activator, self.ItemKind ) then return end

        activator:EmitSound( HH.Sounds.pickup, 60 )
        self:Remove()
    end
end

if CLIENT then
    local glow = Material( "sprites/light_glow02_add" )
    local glowColor = Color( 255, 255, 255 )

    function ENT:Draw()
        self:DrawModel()
    end

    function ENT:DrawTranslucent()
        local pos = self:WorldSpaceCenter()
        local dist = EyePos():Distance( pos )
        if dist > GLOW_MAX_DIST then return end

        local fade = 1 - dist / GLOW_MAX_DIST
        local pulse = 0.6 + 0.4 * math.sin( CurTime() * 2.5 + self:EntIndex() )
        local col = self.GlowColor
        glowColor.r, glowColor.g, glowColor.b = col.r, col.g, col.b
        glowColor.a = 160 * fade * pulse

        render.SetMaterial( glow )
        render.DrawSprite( pos, GLOW_SIZE, GLOW_SIZE, glowColor )
    end
end
