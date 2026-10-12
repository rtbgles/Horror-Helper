--[[
    Door barricade: part of a cabin layout. Place it in a doorway (the box shows its size);
    survivors nail planks across it. The killer has to bash through the boards to get in.
    hh_barricade_window is the same thing, window-sized.
]]

AddCSLuaFile()

HorrorHelper = HorrorHelper or {}
local HH = HorrorHelper

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Door Barricade"
ENT.Category = "Horror Helper"
ENT.Author = "Horror Helper"
ENT.Instructions = "Part of a cabin layout. Stand it in a doorway; survivors board it up with planks."
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.HHBarricade = true

-- Box in local space: x is thickness (facing out), y is width, z is height up from the origin.
ENT.BoxWidth = 60
ENT.BoxHeight = 100
ENT.BoxThick = 8
ENT.MaxBoards = 4
ENT.LiftOnSpawn = 0 -- windows spawn centred on where you aim instead of on the floor

local BOARD_COOLDOWN = 0.8
local BOARD_OVERHANG = 12
local GHOST_COLOR_SETUP = Color( 255, 170, 60, 255 )
local GHOST_COLOR_NIGHT = Color( 255, 255, 255, 40 )

function ENT:SetupDataTables()
    self:NetworkVar( "Int", 0, "Boards" )
end

function ENT:GetBoxBounds()
    local halfThick = self.BoxThick * 0.5
    local halfWidth = self.BoxWidth * 0.5

    return Vector( -halfThick, -halfWidth, 0 ), Vector( halfThick, halfWidth, self.BoxHeight )
end

HH.Barricades = HH.Barricades or {}

function ENT:Initialize()
    HH.Barricades[self] = true
    local mins, maxs = self:GetBoxBounds()

    -- The model is only drawn (one board, repeated); collision is the box.
    self:SetModel( HH.Models.board )
    self:PhysicsInitBox( mins, maxs )
    -- PhysicsInitBox sets SOLID_BBOX, which ignores rotation; use the rotated physics box.
    self:SetSolid( SOLID_VPHYSICS )

    local phys = self:GetPhysicsObject()
    if IsValid( phys ) then
        phys:EnableMotion( false )
    end

    if CLIENT then
        self:SetRenderBounds( mins, maxs, Vector( BOARD_OVERHANG, BOARD_OVERHANG, 8 ) )
        return
    end

    self.hhHealth = 0
    self.hhNextBoard = 0

    -- Placed by hand for setup: solid so the physgun can grab it. In a round: open until boarded.
    self:SetNotSolid( self:GetNW2Bool( "HH_RoundEnt", false ) )
end

function ENT:OnRemove()
    HH.Barricades[self] = nil
end

if SERVER then
    function ENT:SpawnFunction( ply, tr, className )
        if not tr.Hit then return end

        local ent = ents.Create( className )
        local pos = tr.HitPos + tr.HitNormal * 4
        local lift = scripted_ents.GetMember( className, "LiftOnSpawn" ) or 0

        if lift > 0 then
            pos = pos - Vector( 0, 0, ( scripted_ents.GetMember( className, "BoxHeight" ) or 0 ) * 0.5 )
        else
            local down = util.TraceLine( {
                start = pos + Vector( 0, 0, 8 ),
                endpos = pos - Vector( 0, 0, 256 ),
                mask = MASK_SOLID_BRUSHONLY,
            } )
            pos = down.HitPos
        end

        ent:SetPos( pos )
        ent:SetAngles( Angle( 0, ply:EyeAngles().y, 0 ) )
        ent:Spawn()
        ent:Activate()

        return ent
    end

    function ENT:BoardHealth()
        return HH.CV.board_health:GetFloat()
    end

    function ENT:SetHealthAndBoards( health )
        local perBoard = self:BoardHealth()
        local before = self:GetBoards()

        self.hhHealth = math.Clamp( health, 0, perBoard * self.MaxBoards )
        local boards = math.ceil( self.hhHealth / perBoard )
        self:SetBoards( boards )
        self:SetNotSolid( boards == 0 )

        if boards ~= before then
            HH.RefreshTotals()
        end

        return before, boards
    end

    -- Is anything standing inside the box? Boarding would trap it in the wood.
    function ENT:IsObstructed()
        local mins, maxs = self:WorldSpaceAABB()

        for _, ent in ipairs( ents.FindInBox( mins, maxs ) ) do
            if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then
                local lp = self:WorldToLocal( ent:GetPos() )
                local boxMins, boxMaxs = self:GetBoxBounds()

                if math.abs( lp.x ) < boxMaxs.x + 16 and lp.y > boxMins.y - 16 and lp.y < boxMaxs.y + 16 then return true end
            end
        end

        return false
    end

    function ENT:TryBoard( ply )
        if CurTime() < self.hhNextBoard then return end
        self.hhNextBoard = CurTime() + BOARD_COOLDOWN

        if self.hhHealth >= self:BoardHealth() * self.MaxBoards then
            ply:PrintMessage( HUD_PRINTCENTER, "It's boarded up as well as it'll get." )
            return
        end

        local planks = ply:GetNW2Int( "HH_Planks", 0 )
        if planks <= 0 then
            ply:PrintMessage( HUD_PRINTCENTER, "You need planks. Go find some." )
            return
        end

        if self:IsObstructed() then
            ply:PrintMessage( HUD_PRINTCENTER, "Something is in the way." )
            return
        end

        ply:SetNW2Int( "HH_Planks", planks - 1 )
        -- A new plank tops a damaged board back up before starting the next one.
        local perBoard = self:BoardHealth()
        local partial = self.hhHealth % perBoard
        local added = partial > 0 and ( perBoard - partial ) or perBoard
        self:SetHealthAndBoards( self.hhHealth + added )
        self:EmitSound( HH.PickSound( HH.Sounds.hammer ), 75, math.random( 95, 105 ) )
    end

    function ENT:ApplyBoardDamage( amount )
        if self:GetBoards() <= 0 then return end

        local before, after = self:SetHealthAndBoards( self.hhHealth - amount )

        if after < before then
            self:EmitSound( HH.PickSound( HH.Sounds.boardBreak ), 80, math.random( 90, 105 ) )
        else
            self:EmitSound( HH.PickSound( HH.Sounds.bash ), 80, math.random( 85, 100 ) )
        end
    end

    function ENT:OnTakeDamage( dmg )
        local attacker = dmg:GetAttacker()
        -- Only the killer can break boards; survivors swinging at them do nothing.
        if not IsValid( attacker ) or not attacker.HHKiller then return 0 end

        self:ApplyBoardDamage( dmg:GetDamage() )

        return dmg:GetDamage()
    end

    hook.Add( "KeyPress", "HorrorHelper_Barricade", function( ply, key )
        if key ~= IN_USE then return end
        if HH.GetPhase() ~= HH.PHASE_NIGHT or not ply:Alive() or HH.IsOut( ply ) then return end

        local barricade = HH.FindAimedBarricade( ply )
        if IsValid( barricade ) then
            barricade:TryBoard( ply )
        end
    end )
end

if CLIENT then
    -- Fit the board model across the opening whatever way round the model was built:
    -- its longest side spans the width, its thinnest side faces out.
    local function buildBoardMatrix( ent )
        local mins, maxs = ent:GetModelBounds()
        local size = maxs - mins
        local center = ( mins + maxs ) * 0.5
        local axes = { { i = 1, v = size.x }, { i = 2, v = size.y }, { i = 3, v = size.z } }
        table.sort( axes, function( a, b ) return a.v > b.v end )

        local long, mid, thin = axes[1].i, axes[2].i, axes[3].i
        local lengthScale = ( ent.BoxWidth + BOARD_OVERHANG ) / math.max( axes[1].v, 1 )
        local c = { center.x, center.y, center.z }

        -- A permutation of axes can mirror the model inside out; flip the thin axis if so.
        local order = { thin, long, mid }
        local inversions = 0
        for a = 1, 3 do
            for b = a + 1, 3 do
                if order[a] > order[b] then
                    inversions = inversions + 1
                end
            end
        end
        local flip = inversions % 2 == 1 and -1 or 1

        local rows = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 1 } }
        rows[1][thin] = flip
        rows[2][long] = lengthScale
        rows[3][mid] = 1

        local m = Matrix( rows )
        m:SetTranslation( Vector( -c[thin] * flip, -c[long] * lengthScale, -c[mid] ) )

        return m
    end

    function ENT:DrawBoards( count )
        self.hhBoardMatrix = self.hhBoardMatrix or buildBoardMatrix( self )
        self:EnableMatrix( "RenderMultiply", self.hhBoardMatrix )

        local fwd = self:GetForward()

        for i = 1, count do
            local z = self.BoxHeight * ( i - 0.5 ) / self.MaxBoards
            -- Each board is nailed on a little crooked, the same way every time.
            local tilt = ( ( i * 37 + self:EntIndex() * 13 ) % 15 ) - 7
            local ang = self:GetAngles()
            ang:RotateAroundAxis( fwd, tilt )

            self:SetRenderOrigin( self:LocalToWorld( Vector( 0, 0, z ) ) )
            self:SetRenderAngles( ang )
            self:SetupBones()
            self:DrawModel()
        end

        self:SetRenderOrigin( nil )
        self:SetRenderAngles( nil )
        self:DisableMatrix( "RenderMultiply" )
        self:SetupBones()
    end

    function ENT:Draw()
        local boards = self:GetBoards()
        if boards > 0 then
            self:DrawBoards( boards )
        end
    end

    function ENT:DrawTranslucent()
        local phase = HH.GetPhase()
        local mins, maxs = self:GetBoxBounds()

        if phase == HH.PHASE_IDLE or phase == HH.PHASE_LOBBY then
            render.DrawWireframeBox( self:GetPos(), self:GetAngles(), mins, maxs, GHOST_COLOR_SETUP, true )
        elseif phase == HH.PHASE_NIGHT and self:GetBoards() < self.MaxBoards then
            render.DrawWireframeBox( self:GetPos(), self:GetAngles(), mins, maxs, GHOST_COLOR_NIGHT, true )
        end
    end
end
