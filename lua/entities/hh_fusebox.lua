-- Fuse box: part of a cabin layout. Fill every fuse box in the cabin and the lamps come on.

AddCSLuaFile()

HorrorHelper = HorrorHelper or {}
local HH = HorrorHelper

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Fuse Box"
ENT.Category = "Horror Helper"
ENT.Author = "Horror Helper"
ENT.Instructions = "Part of a cabin layout. Survivors fill it with fuses they find."
ENT.Spawnable = true
ENT.AdminOnly = true

local LABEL_DIST = 220

function ENT:SetupDataTables()
    self:NetworkVar( "Int", 0, "Fuses" )
    self:NetworkVar( "Int", 1, "Needed" )
end

function ENT:Initialize()
    if CLIENT then return end

    self:SetModel( HH.SafeModel( HH.Models.fusebox ) )
    self:PhysicsInit( SOLID_VPHYSICS )
    self:SetMoveType( MOVETYPE_VPHYSICS )
    self:SetSolid( SOLID_VPHYSICS )
    self:SetUseType( SIMPLE_USE )

    local phys = self:GetPhysicsObject()
    if IsValid( phys ) then
        phys:EnableMotion( false )
    end

    self:SetNeeded( HH.CV.fuses_per_box:GetInt() )
end

if SERVER then
    function ENT:SpawnFunction( ply, tr, className )
        if not tr.Hit then return end

        local ent = ents.Create( className )
        ent:SetPos( tr.HitPos + tr.HitNormal * 12 )
        ent:SetAngles( Angle( 0, ply:EyeAngles().y + 180, 0 ) )
        ent:Spawn()
        ent:Activate()

        return ent
    end

    function ENT:Use( activator )
        if not IsValid( activator ) or not activator:IsPlayer() or not activator:Alive() then return end
        if HH.GetPhase() ~= HH.PHASE_NIGHT or HH.IsOut( activator ) then return end

        local missing = self:GetNeeded() - self:GetFuses()
        if missing <= 0 then
            activator:PrintMessage( HUD_PRINTCENTER, "This fuse box is full." )
            return
        end

        local carried = activator:GetNW2Int( "HH_Fuses", 0 )
        if carried <= 0 then
            activator:PrintMessage( HUD_PRINTCENTER, "It needs fuses. They're somewhere out there." )
            return
        end

        local count = math.min( carried, missing )
        activator:SetNW2Int( "HH_Fuses", carried - count )
        self:SetFuses( self:GetFuses() + count )
        self:EmitSound( HH.Sounds.fuseIn, 70 )

        if self:GetFuses() >= self:GetNeeded() then
            self:EmitSound( HH.Sounds.powerOn, 75 )
        end

        HH.RefreshTotals()
    end
end

if CLIENT then
    local labelColor = Color( 230, 225, 215 )

    function ENT:Draw()
        self:DrawModel()

        if EyePos():Distance( self:GetPos() ) > LABEL_DIST then return end

        local pos = self:GetPos() + self:GetUp() * ( self:OBBMaxs().z + 6 )
        local text = HH.GetPhase() == HH.PHASE_NIGHT and string.format( "FUSES  %d / %d", self:GetFuses(), self:GetNeeded() ) or "FUSE BOX"

        cam.Start3D2D( pos, Angle( 0, EyeAngles().y - 90, 90 ), 0.12 )
            draw.SimpleText( text, "HH_World", 0, 0, labelColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
        cam.End3D2D()
    end
end
