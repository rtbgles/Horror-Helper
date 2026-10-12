-- Paramedic kit. Left Mouse: open the chart of the patient you're looking at (or, while
-- carrying a spine board, load it into the ambulance). Right Mouse: the ambulance's patient
-- list. Reload: mark / unmark the vehicle you're looking at as the ambulance.

AddCSLuaFile()

ParamedicResponse = ParamedicResponse or {}
local PMR = ParamedicResponse

SWEP.PrintName = "Paramedic Kit"
SWEP.Category = "Paramedic Response"
SWEP.Author = ""
SWEP.Instructions = "Left: patient chart / load board. Right: ambulance. Reload: mark ambulance."
SWEP.Spawnable = true
SWEP.Slot = 5
SWEP.SlotPos = 3
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = true

SWEP.ViewModel = "models/weapons/c_medkit.mdl"
SWEP.WorldModel = "models/weapons/w_medkit.mdl"
SWEP.UseHands = true
SWEP.HoldType = "slam"

SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "none"

SWEP.Secondary.ClipSize = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic = false
SWEP.Secondary.Ammo = "none"

local USE_DELAY = 0.4
local RELOAD_DELAY = 1

function SWEP:Initialize()
    self:SetHoldType( self.HoldType )
end

-- The real work happens on the server, which tells the client what to open.
function SWEP:PrimaryAttack()
    self:SetNextPrimaryFire( CurTime() + USE_DELAY )
    if not SERVER then return end

    local owner = self:GetOwner()
    if IsValid( owner ) and PMR.IsMedic( owner ) then
        PMR.KitPrimary( owner )
    elseif IsValid( owner ) then
        PMR.Notify( owner, "Go on duty first (!duty)." )
    end
end

function SWEP:SecondaryAttack()
    self:SetNextSecondaryFire( CurTime() + USE_DELAY )
    if not SERVER then return end

    local owner = self:GetOwner()
    if IsValid( owner ) and PMR.IsMedic( owner ) then
        PMR.KitSecondary( owner )
    end
end

function SWEP:Reload()
    if not SERVER then return end
    if ( self.NextReload or 0 ) > CurTime() then return end

    self.NextReload = CurTime() + RELOAD_DELAY

    local owner = self:GetOwner()
    if IsValid( owner ) and PMR.IsMedic( owner ) then
        PMR.KitReload( owner )
    end
end
