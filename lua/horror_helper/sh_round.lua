-- Shared round state readers, the intro lock and the Sandbox restrictions.

local HH = HorrorHelper

local USE_REACH = 110
local BARRICADE_EDGE_SLACK = 8

function HH.GetPhase()
    return GetGlobal2Int( "HH_Phase", HH.PHASE_IDLE )
end

-- True while a round owns the server (from the opening film until the results go away).
function HH.InRound()
    local phase = HH.GetPhase()

    return phase == HH.PHASE_INTRO or phase == HH.PHASE_NIGHT or phase == HH.PHASE_RESULTS
end

function HH.IsOut( ply )
    return ply:GetNW2Bool( "HH_Out", false )
end

function HH.Restricts( ply )
    if not HH.InRound() then return false end
    if not HH.CV.restrict:GetBool() then return false end
    if HH.CV.admin_bypass:GetBool() and IsValid( ply ) and ply:IsSuperAdmin() then return false end

    return true
end

-- The barricade a player is aiming at within reach, found by crossing the aim ray with each
-- barricade's plane. Works whether or not the barricade is solid yet.
function HH.FindAimedBarricade( ply )
    local eye = ply:EyePos()
    local aim = ply:GetAimVector()
    local best, bestDist

    for ent in pairs( HH.Barricades or {} ) do
        if IsValid( ent ) then
            local normal = ent:GetForward()
            local denom = aim:Dot( normal )

            if math.abs( denom ) > 0.15 then
                local dist = ( ent:GetPos() - eye ):Dot( normal ) / denom

                if dist > 0 and dist < USE_REACH and ( not bestDist or dist < bestDist ) then
                    local hit = eye + aim * dist
                    local lp = ent:WorldToLocal( hit )
                    local halfWidth = ent.BoxWidth * 0.5 + BARRICADE_EDGE_SLACK

                    if math.abs( lp.y ) <= halfWidth and lp.z >= -BARRICADE_EDGE_SLACK and lp.z <= ent.BoxHeight + BARRICADE_EDGE_SLACK then
                        best = ent
                        bestDist = dist
                    end
                end
            end
        end
    end

    return best
end

-- The opening film owns everyone's body: no walking, no shooting.
hook.Add( "StartCommand", "HorrorHelper_IntroLock", function( _, cmd )
    if HH.GetPhase() ~= HH.PHASE_INTRO then return end

    cmd:ClearMovement()
    cmd:ClearButtons()
end )

hook.Add( "PlayerNoClip", "HorrorHelper_Restrict", function( ply, desiredState )
    if desiredState and HH.Restricts( ply ) then return false end
end )

hook.Add( "CanTool", "HorrorHelper_Restrict", function( ply )
    if HH.Restricts( ply ) then return false end
end )

hook.Add( "CanProperty", "HorrorHelper_Restrict", function( ply )
    if HH.Restricts( ply ) then return false end
end )

hook.Add( "PhysgunPickup", "HorrorHelper_Restrict", function( ply, ent )
    if HH.Restricts( ply ) then return false end
    -- Round pieces never move, even for admins who bypass the rest.
    if HH.InRound() and ent:GetNW2Bool( "HH_RoundEnt", false ) then return false end
end )

if CLIENT then
    hook.Add( "SpawnMenuOpen", "HorrorHelper_Restrict", function()
        if HH.Restricts( LocalPlayer() ) then return false end
    end )

    hook.Add( "ContextMenuOpen", "HorrorHelper_Restrict", function()
        if HH.Restricts( LocalPlayer() ) then return false end
    end )
end
