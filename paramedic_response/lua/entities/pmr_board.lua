-- Spine board. Press E to pick up the end nearest you (E again to put it down); a second medic
-- can grab the other end and the two of you carry it between you. Patients are strapped on from
-- their chart ("Log-roll onto board") and loaded into the ambulance with the kit's Left Mouse.

AddCSLuaFile()

ParamedicResponse = ParamedicResponse or {}
local PMR = ParamedicResponse

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Spine Board"
ENT.Category = "Paramedic Response"
ENT.Spawnable = true

local BOARD_COLOR = Color( 235, 120, 30 )
local BOARD_MASS = 25
local HOLD_HEIGHT = 34 -- carried at about hip height
local SOLO_REACH = 20 -- gap between a lone carrier and the near end
local MAX_CARRIERS = 2
local DROP_DISTANCE = 220 -- a carrier who ends up further away than this lets go
local TOGGLE_COOLDOWN = 0.3
local UP = Vector( 0, 0, 1 )

function ENT:SetupDataTables()
    self:NetworkVar( "Int", 0, "Patient" )
end

-- The model's long side, in local space (plates are not all modelled the same way round).
function ENT:GetLongAxis()
    local size = self:OBBMaxs() - self:OBBMins()

    return size.x >= size.y and Vector( 1, 0, 0 ) or Vector( 0, 1, 0 )
end

function ENT:GetLongDir()
    local dir = self:GetLongAxis()
    dir:Rotate( self:GetAngles() )

    return dir
end

function ENT:GetHalfLength()
    local size = self:OBBMaxs() - self:OBBMins()

    return math.max( size.x, size.y ) / 2
end

if SERVER then
    function ENT:Initialize()
        self:SetModel( PMR.SafeModel( PMR.Models.board ) )
        self:PhysicsInit( SOLID_VPHYSICS )
        self:SetMoveType( MOVETYPE_VPHYSICS )
        self:SetSolid( SOLID_VPHYSICS )
        self:SetUseType( SIMPLE_USE )
        self:SetMaterial( "models/debug/debugwhite" )
        self:SetColor( BOARD_COLOR )

        local phys = self:GetPhysicsObject()
        if IsValid( phys ) then
            phys:SetMass( BOARD_MASS )
            phys:Wake()
        end

        self.Carriers = {} -- player -> which end they hold (1 = +long end, -1 = the other)
        self.ShadowParams = {}
    end

    function ENT:CarrierCount()
        return table.Count( self.Carriers )
    end

    function ENT:AddCarrier( ply )
        if self.PMR_Stowed or self.Carriers[ply] then return end

        if self:CarrierCount() >= MAX_CARRIERS then
            PMR.Notify( ply, "Two people are already carrying this board." )

            return
        end

        if IsValid( ply.PMR_Board ) and ply.PMR_Board ~= self then
            ply.PMR_Board:RemoveCarrier( ply )
        end

        local toPlayer = ply:GetPos() - self:GetPos()
        local side = toPlayer:Dot( self:GetLongDir() ) >= 0 and 1 or -1

        -- Someone already has that end: take the other one.
        for _, otherSide in pairs( self.Carriers ) do
            if otherSide == side then
                side = -side
            end
        end

        self.Carriers[ply] = side
        ply.PMR_Board = self
        ply:SetNW2Entity( "PMR_Board", self )

        if self:CarrierCount() == 1 then
            -- Don't shove the people carrying it.
            self:SetCollisionGroup( COLLISION_GROUP_WEAPON )
            self:StartMotionController()
        end

        self:EmitSound( PMR.Sounds.strap, 60, 110 )
    end

    function ENT:RemoveCarrier( ply )
        if not self.Carriers[ply] then return end

        self.Carriers[ply] = nil

        if IsValid( ply ) and ply.PMR_Board == self then
            ply.PMR_Board = nil
            ply:SetNW2Entity( "PMR_Board", NULL )
        end

        if self:CarrierCount() == 0 then
            self:StopMotionController()
            self:SetCollisionGroup( COLLISION_GROUP_NONE )

            local phys = self:GetPhysicsObject()
            if IsValid( phys ) then
                phys:Wake()
            end
        end
    end

    function ENT:ReleaseAll()
        for ply in pairs( table.Copy( self.Carriers ) ) do
            self:RemoveCarrier( ply )
        end
    end

    function ENT:IsCarriedBy( ply )
        return self.Carriers[ply] ~= nil
    end

    function ENT:Use( activator )
        if not IsValid( activator ) or not activator:IsPlayer() or not activator:Alive() then return end
        if ( activator.PMR_BoardToggle or 0 ) > CurTime() then return end

        activator.PMR_BoardToggle = CurTime() + TOGGLE_COOLDOWN

        if self.Carriers[activator] then
            self:RemoveCarrier( activator )
        else
            self:AddCarrier( activator )
        end
    end

    -- Where the board should be: between two carriers, or held out in front of one.
    function ENT:ComputeTarget()
        local holders = {}

        for ply, side in pairs( self.Carriers ) do
            if IsValid( ply ) then
                table.insert( holders, { ply = ply, side = side } )
            end
        end

        if #holders == 0 then return end

        local center, long

        if #holders == 2 then
            local first, second = holders[1], holders[2]
            local plusEnd = first.side > 0 and first.ply or second.ply
            local minusEnd = first.side > 0 and second.ply or first.ply

            long = plusEnd:GetPos() - minusEnd:GetPos()
            long.z = 0

            if long:LengthSqr() > 1 then
                long:Normalize()
                center = ( plusEnd:GetPos() + minusEnd:GetPos() ) * 0.5 + UP * HOLD_HEIGHT
            end
        end

        if not center then
            local holder = holders[1]
            local forward = Angle( 0, holder.ply:EyeAngles().y, 0 ):Forward()

            center = holder.ply:GetPos() + forward * ( self:GetHalfLength() + SOLO_REACH ) + UP * HOLD_HEIGHT
            -- The end they hold stays nearest to them.
            long = forward * -holder.side
        end

        -- If the model is long along local y, its local x is y cross z.
        local forwardAxis = self:GetLongAxis().x == 1 and long or long:Cross( UP )

        return center, forwardAxis:AngleEx( UP )
    end

    function ENT:PhysicsSimulate( phys, deltaTime )
        local pos, ang = self:ComputeTarget()
        if not pos then return end

        phys:Wake()

        local params = self.ShadowParams
        params.secondstoarrive = 0.12
        params.pos = pos
        params.angle = ang
        params.maxangular = 5000
        params.maxangulardamp = 10000
        params.maxspeed = 100000
        params.maxspeeddamp = 10000
        params.dampfactor = 0.8
        params.teleportdistance = 0
        params.delta = deltaTime
        params.deltatime = deltaTime

        phys:ComputeShadowControl( params )
    end

    function ENT:Think()
        if not next( self.Carriers ) then return end

        for ply in pairs( table.Copy( self.Carriers ) ) do
            local gone = not IsValid( ply ) or not ply:Alive() or ply:InVehicle()
            if gone or ply:GetPos():Distance( self:GetPos() ) > DROP_DISTANCE then
                self:RemoveCarrier( ply )
            end
        end

        self:NextThink( CurTime() + 0.2 )

        return true
    end

    function ENT:OnRemove()
        self:ReleaseAll()

        local p = PMR.Patients and PMR.Patients[self:GetPatient()]
        if p and p.board == self then
            PMR.ReleaseFromBoard( p )
            p.state = PMR.STATE_SCENE
            PMR.SyncSoon()
        end
    end

    -- E puts the board down wherever you're looking (Use only fires when you aim at it).
    hook.Add( "KeyPress", "PMR_DropBoard", function( ply, key )
        if key ~= IN_USE or not IsValid( ply.PMR_Board ) then return end
        if ( ply.PMR_BoardToggle or 0 ) > CurTime() then return end

        ply.PMR_BoardToggle = CurTime() + TOGGLE_COOLDOWN
        ply.PMR_Board:RemoveCarrier( ply )
    end )
end

if CLIENT then
    function ENT:Draw()
        self:DrawModel()
    end
end
