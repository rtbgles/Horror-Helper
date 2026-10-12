-- Hospital drop-off. Carry a patient on a spine board into the circle to hand them over.
-- Admins place it from the spawn menu; positions are saved per map automatically.

AddCSLuaFile()

ParamedicResponse = ParamedicResponse or {}
local PMR = ParamedicResponse

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Hospital Drop-off"
ENT.Category = "Paramedic Response"
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

local SIGN_HEIGHT = 110

function ENT:SpawnFunction( ply, tr, className )
    if not tr.Hit then return end

    local ent = ents.Create( className )
    ent:SetPos( tr.HitPos + tr.HitNormal * 2 )
    ent:SetAngles( Angle( 0, ply:EyeAngles().y + 180, 0 ) )
    ent:Spawn()
    ent:Activate()

    return ent
end

if SERVER then
    function ENT:Initialize()
        self:SetModel( PMR.SafeModel( PMR.Models.hospital ) )
        self:PhysicsInit( SOLID_VPHYSICS )
        self:SetMoveType( MOVETYPE_VPHYSICS )
        self:SetSolid( SOLID_VPHYSICS )
        self:SetCollisionGroup( COLLISION_GROUP_WEAPON )
        self:DrawShadow( false )

        local phys = self:GetPhysicsObject()
        if IsValid( phys ) then
            phys:EnableMotion( false )
        end
    end

    -- Always known to every client, so the HUD can point at it from across the map.
    function ENT:UpdateTransmitState()
        return TRANSMIT_ALWAYS
    end
end

if CLIENT then
    local RED = Color( 220, 40, 40 )
    local RED_FAINT = Color( 220, 40, 40, 70 )
    local WHITE = Color( 245, 245, 245, 235 )
    local DARK = Color( 25, 28, 34 )

    local function radius()
        return PMR.CV.hospital_radius:GetFloat()
    end

    function ENT:Initialize()
        local r = radius()
        self:SetRenderBounds( Vector( -r, -r, -8 ), Vector( r, r, SIGN_HEIGHT + 60 ) )
    end

    local function drawCross( x, y, size, color )
        local bar = size / 3
        draw.RoundedBox( 0, x - bar / 2, y - size / 2, bar, size, color )
        draw.RoundedBox( 0, x - size / 2, y - bar / 2, size, bar, color )
    end

    function ENT:Draw()
        -- Invisible unless you're holding something that can move it.
        local wep = LocalPlayer():GetActiveWeapon()
        if IsValid( wep ) and ( wep:GetClass() == "weapon_physgun" or wep:GetClass() == "gmod_tool" ) then
            self:DrawModel()
        end
    end

    function ENT:DrawTranslucent()
        self:Draw()

        local pos = self:GetPos()
        local r = radius()

        -- The drop-off circle on the ground.
        cam.Start3D2D( pos + Vector( 0, 0, 1 ), Angle( 0, 0, 0 ), 1 )
            surface.DrawCircle( 0, 0, r, RED.r, RED.g, RED.b, 200 )
            surface.DrawCircle( 0, 0, r - 4, RED.r, RED.g, RED.b, 120 )
            drawCross( 0, 0, 70, RED_FAINT )
        cam.End3D2D()

        -- A sign that always faces you.
        local signPos = pos + Vector( 0, 0, SIGN_HEIGHT )
        local ang = Angle( 0, EyeAngles().y - 90, 90 )

        cam.Start3D2D( signPos, ang, 0.25 )
            draw.RoundedBox( 12, -260, -70, 520, 140, WHITE )
            drawCross( -195, 0, 100, RED )
            draw.SimpleText( "HOSPITAL", "PMR_World", -120, -8, DARK, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM )
            draw.SimpleText( "Ambulance drop-off", "PMR_WorldSmall", -120, 0, RED, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
        cam.End3D2D()
    end
end
