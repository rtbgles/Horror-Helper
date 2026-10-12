--[[
    The director. VJ Base NPCs on their own find the nearest player and run straight at them,
    so the killer here simply does not exist until the director wants it to:

      DORMANT    no killer on the map. Survivors scavenge. The director may stage a glimpse or
                 fake footsteps, roll for a chance encounter, or decide the siege has come.
      ENCOUNTER  the killer appears out of sight near a survivor far from the cabin (on the far
                 side, so running home is the way out) and hunts them. The chase ends when the
                 survivor gets near the cabin, the killer loses everyone, or it runs too long.
      SIEGE      an attack wave on the cabin: it walks in from the dark, bashes barricades,
                 and comes in through whatever is left open. It leaves when the wave runs out
                 or the survivors hurt it enough.
      VANISH     it is leaving: it stops fighting and is removed the moment nobody is looking
                 (or after a blink of black if someone stares it down).

    When the first siege comes is rolled per night: after enough setup progress plus a random
    delay, sometimes only once the cabin is fully ready, and always by a deadline.
]]

local HH = HorrorHelper

HH.Director = HH.Director or {}
local Director = HH.Director

local MODE_DORMANT = 0
local MODE_ENCOUNTER = 1
local MODE_SIEGE = 2
local MODE_VANISH = 3

local THINK_INTERVAL = 1
local VANISH_INTERVAL = 0.25
local VANISH_TIMEOUT = 6 -- stared at this long while leaving, it blinks out anyway
local VANISH_RUN_DIST = 1500

local AMBUSH_DELAY_MIN = 20 -- once the rolled progress is reached, it waits this long...
local AMBUSH_DELAY_MAX = 100 -- ...up to this long before it comes
local SURPRISE_SIEGE_PER_MIN = 0.04 -- small chance per minute of an early siege once allowed

local ENCOUNTER_SPAWN_MIN = 550
local ENCOUNTER_SPAWN_MAX = 1100
local ENCOUNTER_TRIES = 50
local ENCOUNTER_COOLDOWN_MIN = 90
local ENCOUNTER_COOLDOWN_MAX = 200
local LONE_RADIUS = 700 -- nobody else within this: you are alone out there
local LONE_FACTOR = 1.6
local GROUP_FACTOR = 0.5
local LOST_DIST = 2600 -- the chase is lost when nobody is this close...
local LOST_TIME = 8 -- ...for this long
local UNSEEN_GIVE_UP = 30 -- or nobody has laid eyes on it for this long

local SIEGE_SPAWN_MIN = 1300 -- beyond the cabin's edge
local SIEGE_SPAWN_MAX = 2800
local SIEGE_TRIES = 80
local RETARGET_INTERVAL = 3
local BASH_RANGE = 70
local BASH_INTERVAL = 1.6
local POWER_BASH_SCALE = 0.75 -- the lit cabin slows it down a little
local STUCK_TIME = 12
local STUCK_MOVE = 96
local OUTSIDE_OFFSET = 72

local SIGHTING_MIN = 500
local SIGHTING_MAX = 1400
local SIGHTING_COOLDOWN_MIN = 90
local SIGHTING_COOLDOWN_MAX = 200
local SIGHTING_MAX_DOT = 0.85 -- not dead centre of the screen: off to the side
local SIGHTING_MIN_DOT = -0.1
local PHANTOM_CHANCE_PER_MIN = 0.25
local PHANTOM_COOLDOWN_MIN = 60
local PHANTOM_COOLDOWN_MAX = 150

local D = Director.state or {}
Director.state = D

local function now()
    return CurTime()
end

local function cabinCenter()
    return HH.State.cabin and HH.State.cabin.center or vector_origin
end

local function cabinRadius()
    return HH.State.cabin and HH.State.cabin.radius or 600
end

local function distToCabin( pos )
    return pos:Distance( cabinCenter() )
end

local function nightFraction()
    local length = HH.State.nightLength or 1

    return ( now() - ( HH.State.nightStart or now() ) ) / length
end

--[[ Controlling the NPC. VJ Base gets its own calls; anything else gets the engine's. ]]

local function huntTarget( killer, target )
    if not IsValid( killer ) or not IsValid( target ) then return end

    if isfunction( killer.ForceSetEnemy ) then
        pcall( killer.ForceSetEnemy, killer, target, false )
    elseif killer:IsNPC() then
        killer:SetEnemy( target )
        killer:UpdateEnemyMemory( target, target:GetPos() )
    end
end

local function moveTo( killer, pos )
    if not killer:IsNPC() then return end

    killer:SetLastPosition( pos )
    if isfunction( killer.SCHEDULE_GOTO_POSITION ) then
        pcall( killer.SCHEDULE_GOTO_POSITION, killer, "TASK_RUN_PATH" )
    else
        killer:SetSchedule( SCHED_FORCED_GO_RUN )
    end
end

-- Stop fighting and walk off into the dark.
local function disengage( killer )
    if killer.IsVJBaseSNPC then
        if VJ_BEHAVIOR_PASSIVE then
            killer.Behavior = VJ_BEHAVIOR_PASSIVE
        end
        killer.EnemyDetection = false
    end

    if not killer:IsNPC() then return end

    for _, ply in player.Iterator() do
        killer:AddEntityRelationship( ply, D_NU, 99 )
    end
    pcall( killer.SetEnemy, killer, NULL )
    killer:ClearEnemyMemory()

    local away = killer:GetPos() - cabinCenter()
    away.z = 0
    if away:IsZero() then
        away = Vector( 1, 0, 0 )
    end
    moveTo( killer, killer:GetPos() + away:GetNormalized() * VANISH_RUN_DIST )
end

local function spawnKiller( pos, yaw )
    local ent = ents.Create( HH.State.killerClass )
    if not IsValid( ent ) then return nil end

    ent.CanChatMessage = false -- no "X no longer likes you" in chat
    ent:SetPos( pos )
    ent:SetAngles( Angle( 0, yaw, 0 ) )
    ent:SetNW2Bool( "HH_RoundEnt", true )
    ent:Spawn()
    ent:Activate()
    ent.HHKiller = true

    D.killer = ent
    D.waveDamage = 0
    D.lastSeen = now()
    D.lastNearby = now()
    D.lastMovePos = pos
    D.lastMoveTime = now()
    D.nextRetarget = 0
    D.nextBash = 0
    SetGlobal2Entity( "HH_Killer", ent )

    return ent
end

local function removeKiller()
    if IsValid( D.killer ) then
        D.killer:Remove()
    end

    D.killer = nil
    SetGlobal2Entity( "HH_Killer", NULL )
end

local function beginVanish( reason )
    if D.mode == MODE_VANISH or D.mode == MODE_DORMANT then return end
    HH.Debug( "vanish:", reason )

    if D.mode == MODE_SIEGE then
        D.respiteEnd = now() + math.Rand( HH.CV.respite_min:GetFloat(), math.max( HH.CV.respite_min:GetFloat(), HH.CV.respite_max:GetFloat() ) )
    end

    D.mode = MODE_VANISH
    D.vanishStart = now()
    D.nextKillerAt = now() + math.Rand( ENCOUNTER_COOLDOWN_MIN, ENCOUNTER_COOLDOWN_MAX )

    if IsValid( D.killer ) then
        disengage( D.killer )
    end
end

local function finishVanish()
    removeKiller()
    D.mode = MODE_DORMANT
end

--[[ Glimpses and phantom footsteps (only while there is no killer on the map) ]]

local function trySighting( ply )
    if not HH.CV.sightings:GetBool() then return end
    if GetGlobal2String( "HH_KillerModel", "" ) == "" then return end
    if now() < ( D.sightCooldown[ply] or 0 ) then return end
    if math.random() >= HH.CV.sighting_chance:GetFloat() / 60 * THINK_INTERVAL then return end

    local eye = ply:EyePos()
    local aim = ply:GetAimVector()

    local spot = HH.FindPoint( ply:GetPos(), SIGHTING_MIN, SIGHTING_MAX, 30, function( point )
        if distToCabin( point ) < cabinRadius() then return false end

        local head = point + Vector( 0, 0, 60 )
        local dir = ( head - eye ):GetNormalized()
        local dot = aim:Dot( dir )
        if dot > SIGHTING_MAX_DOT or dot < SIGHTING_MIN_DOT then return false end

        local tr = util.TraceLine( { start = eye, endpos = head, mask = MASK_BLOCKLOS, filter = ply } )

        return not tr.Hit
    end )
    if not spot then return end

    D.sightCooldown[ply] = now() + math.Rand( SIGHTING_COOLDOWN_MIN, SIGHTING_COOLDOWN_MAX )
    HH.Debug( "sighting for", ply:Nick() )

    net.Start( "HH_Sight" )
    net.WriteVector( spot )
    net.WriteFloat( ( ply:GetPos() - spot ):Angle().y )
    net.Send( ply )
end

local function tryPhantom( ply )
    if not HH.CV.phantoms:GetBool() then return end
    if now() < ( D.phantomCooldown[ply] or 0 ) then return end
    if distToCabin( ply:GetPos() ) < cabinRadius() then return end
    if math.random() >= PHANTOM_CHANCE_PER_MIN / 60 * THINK_INTERVAL then return end

    D.phantomCooldown[ply] = now() + math.Rand( PHANTOM_COOLDOWN_MIN, PHANTOM_COOLDOWN_MAX )
    HH.Debug( "phantom steps for", ply:Nick() )
    HH.SendCue( HH.CUE_PHANTOM, ply:GetPos(), ply )
end

--[[ Chance encounters while scavenging ]]

local function isAlone( ply, alive )
    for _, other in ipairs( alive ) do
        if other ~= ply and other:GetPos():Distance( ply:GetPos() ) < LONE_RADIUS then return false end
    end

    return true
end

local function startEncounter( target )
    local tpos = target:GetPos()
    local toCabin = cabinCenter() - tpos
    toCabin.z = 0
    toCabin:Normalize()

    local fallback
    local spot = HH.FindPoint( tpos, ENCOUNTER_SPAWN_MIN, ENCOUNTER_SPAWN_MAX, ENCOUNTER_TRIES, function( point )
        if distToCabin( point ) < cabinRadius() + HH.CV.safe_margin:GetFloat() then return false end
        if not HH.HullClear( point ) or HH.IsSpotSeen( point ) then return false end

        fallback = fallback or point
        local dir = point - tpos
        dir.z = 0
        dir:Normalize()

        -- From the far side, so the way out is towards the cabin.
        return dir:Dot( toCabin ) < 0.1
    end ) or fallback

    if not spot then return false end

    local killer = spawnKiller( spot, ( tpos - spot ):Angle().y )
    if not killer then return false end

    D.mode = MODE_ENCOUNTER
    D.target = target
    D.pursuitStart = now()
    D.stingerSent = false
    D.encounters = D.encounters + 1
    huntTarget( killer, target )

    HH.Debug( "encounter on", target:Nick(), "at", tostring( spot ) )
    return true
end

local function tryEncounter( alive )
    if D.encounters >= HH.CV.encounter_max:GetInt() then return end
    if now() < D.nextKillerAt then return end

    local chance = HH.CV.encounter_chance:GetFloat() / 60 * THINK_INTERVAL
    local safeEdge = cabinRadius() + HH.CV.safe_margin:GetFloat() * 2

    for _, ply in ipairs( alive ) do
        if distToCabin( ply:GetPos() ) > safeEdge then
            local factor = isAlone( ply, alive ) and LONE_FACTOR or GROUP_FACTOR

            if math.random() < chance * factor and startEncounter( ply ) then return end
        end
    end
end

local function thinkEncounter( alive )
    local killer = D.killer
    if not IsValid( killer ) then
        finishVanish()
        return
    end

    local target = D.target
    if not IsValid( target ) or not target:Alive() or HH.IsOut( target ) then
        local nearest, dist = HH.NearestPlayer( killer:GetPos(), alive )
        if not nearest or dist > LOST_DIST then
            beginVanish( "target gone" )
            return
        end

        D.target = nearest
        target = nearest
    end

    local margin = cabinRadius() + HH.CV.safe_margin:GetFloat()
    if distToCabin( target:GetPos() ) <= margin then
        beginVanish( "reached the cabin" )
        return
    end
    if distToCabin( killer:GetPos() ) <= margin then
        beginVanish( "too close to the cabin" )
        return
    end

    if HH.IsEntitySeen( killer ) then
        D.lastSeen = now()

        if not D.stingerSent and HH.CanPlayerSee( target, killer:WorldSpaceCenter() ) then
            D.stingerSent = true
            HH.SendCue( HH.CUE_ENCOUNTER, killer:GetPos(), target )
        end
    end

    local _, nearestDist = HH.NearestPlayer( killer:GetPos(), alive )
    if nearestDist and nearestDist < LOST_DIST then
        D.lastNearby = now()
    end

    if now() - D.lastNearby > LOST_TIME or now() - D.lastSeen > UNSEEN_GIVE_UP then
        beginVanish( "lost them" )
        return
    end
    if now() - D.pursuitStart > HH.CV.pursuit_max:GetFloat() then
        beginVanish( "pursuit ran too long" )
        return
    end

    if killer:IsNPC() and not IsValid( killer:GetEnemy() ) and now() >= D.nextRetarget then
        D.nextRetarget = now() + RETARGET_INTERVAL
        huntTarget( killer, target )
        moveTo( killer, target:GetPos() )
    end
end

--[[ Sieges ]]

local function barricadeOutside( barricade )
    local fwd = barricade:GetForward()
    local base = barricade:GetPos() + Vector( 0, 0, 4 )
    local a = base + fwd * OUTSIDE_OFFSET
    local b = base - fwd * OUTSIDE_OFFSET

    if distToCabin( a ) > distToCabin( b ) then return a end

    return b
end

local function roundBarricades()
    local list = {}

    for _, ent in ipairs( HH.State.roundEnts or {} ) do
        if IsValid( ent ) and ent.HHBarricade then
            table.insert( list, ent )
        end
    end

    return list
end

local function pickSiegeTarget()
    local boarded, open = {}, {}

    for _, ent in ipairs( roundBarricades() ) do
        if ent:GetBoards() > 0 then
            table.insert( boarded, ent )
        else
            table.insert( open, ent )
        end
    end

    if #open > 0 and math.random() < 0.5 then return open[math.random( #open )] end
    if #boarded > 0 then return boarded[math.random( #boarded )] end
    if #open > 0 then return open[math.random( #open )] end

    return nil
end

local function shouldStartSiege()
    local frac = nightFraction()
    if frac < HH.CV.siege_earliest:GetFloat() then return false end
    if frac >= D.siegeDeadline then
        HH.Debug( "siege: deadline" )
        return true
    end

    local progress = HH.GetSetupProgress()
    if progress >= D.siegeProgressTarget then
        D.ambushAt = D.ambushAt or now() + math.Rand( AMBUSH_DELAY_MIN, AMBUSH_DELAY_MAX )
        if now() >= D.ambushAt then
            HH.Debug( "siege: progress", progress )
            return true
        end
    end

    if progress >= HH.CV.siege_progress:GetFloat() and math.random() < SURPRISE_SIEGE_PER_MIN / 60 * THINK_INTERVAL then
        HH.Debug( "siege: surprise" )
        return true
    end

    return false
end

local function startWave()
    local center = cabinCenter()
    local radius = cabinRadius()

    local spot = HH.FindPoint( center, radius + SIEGE_SPAWN_MIN, radius + SIEGE_SPAWN_MAX, SIEGE_TRIES, function( point )
        return HH.HullClear( point ) and not HH.IsSpotSeen( point )
    end ) or HH.FindPoint( center, radius + 400, radius + SIEGE_SPAWN_MAX * 2, SIEGE_TRIES, function( point )
        return HH.HullClear( point ) and not HH.IsSpotSeen( point )
    end )

    if not spot then
        HH.Debug( "siege: nowhere to spawn, retrying" )
        D.respiteEnd = now() + 5
        return
    end

    local killer = spawnKiller( spot, ( center - spot ):Angle().y )
    if not killer then return end

    D.siegeStarted = true
    D.mode = MODE_SIEGE
    D.waveEnd = now() + math.Rand( HH.CV.wave_min:GetFloat(), math.max( HH.CV.wave_min:GetFloat(), HH.CV.wave_max:GetFloat() ) )
    D.siegeTarget = pickSiegeTarget()

    local goal = IsValid( D.siegeTarget ) and barricadeOutside( D.siegeTarget ) or center
    moveTo( killer, goal )

    HH.Debug( "siege wave from", tostring( spot ) )
    HH.SendCue( HH.CUE_SIEGE, spot )
end

local function anyoneInside( alive )
    local radius = cabinRadius()

    for _, ply in ipairs( alive ) do
        if distToCabin( ply:GetPos() ) <= radius then return true end
    end

    return false
end

local function tryBash( killer, alive )
    if now() < D.nextBash then return false end
    if not anyoneInside( alive ) then return false end

    local kpos = killer:GetPos()

    for _, barricade in ipairs( roundBarricades() ) do
        if barricade:GetBoards() > 0 then
            local lp = barricade:WorldToLocal( kpos )
            local inReach = math.abs( lp.x ) <= barricade.BoxThick * 0.5 + BASH_RANGE
                and math.abs( lp.y ) <= barricade.BoxWidth * 0.5 + 24
                and lp.z > -60 and lp.z < barricade.BoxHeight + 40

            if inReach then
                local damage = HH.CV.bash_damage:GetFloat()
                if GetGlobal2Bool( "HH_Power", false ) then
                    damage = damage * POWER_BASH_SCALE
                end

                D.nextBash = now() + BASH_INTERVAL
                barricade:ApplyBoardDamage( damage )
                util.ScreenShake( barricade:GetPos(), 4, 20, 0.4, 500 )

                return true
            end
        end
    end

    return false
end

local function thinkSiege( alive )
    local killer = D.killer
    if not IsValid( killer ) then
        D.mode = MODE_DORMANT
        D.respiteEnd = now() + HH.CV.respite_max:GetFloat()
        SetGlobal2Entity( "HH_Killer", NULL )
        return
    end

    if now() >= D.waveEnd then
        beginVanish( "wave over" )
        return
    end

    local bashing = tryBash( killer, alive )

    if killer:IsNPC() and now() >= D.nextRetarget then
        D.nextRetarget = now() + RETARGET_INTERVAL

        if not IsValid( killer:GetEnemy() ) then
            local nearest = HH.NearestPlayer( killer:GetPos(), alive )
            if nearest then
                huntTarget( killer, nearest )
            end

            if not IsValid( D.siegeTarget ) then
                D.siegeTarget = pickSiegeTarget()
            end
            if not IsValid( killer:GetEnemy() ) then
                moveTo( killer, IsValid( D.siegeTarget ) and barricadeOutside( D.siegeTarget ) or cabinCenter() )
            end
        end
    end

    -- Stuck somewhere it can't path from (a fence, a cliff, a closed door): when nobody is
    -- watching, it is simply at the boards instead. Slashers do that.
    local kpos = killer:GetPos()
    if kpos:Distance( D.lastMovePos ) > STUCK_MOVE or bashing then
        D.lastMovePos = kpos
        D.lastMoveTime = now()
    elseif now() - D.lastMoveTime > STUCK_TIME then
        local _, nearestDist = HH.NearestPlayer( kpos, alive )
        local target = pickSiegeTarget()
        local goal = IsValid( target ) and barricadeOutside( target ) or nil

        if ( not nearestDist or nearestDist > 200 ) and goal and not HH.IsEntitySeen( killer ) and not HH.IsSpotSeen( goal ) and HH.HullClear( goal ) then
            HH.Debug( "siege: stuck, moving it to a barricade" )
            killer:SetPos( goal )
            D.siegeTarget = target
        end

        D.lastMovePos = killer:GetPos()
        D.lastMoveTime = now()
    end
end

--[[ The loop ]]

local function think()
    if HH.GetPhase() ~= HH.PHASE_NIGHT or not D.active then return end

    local alive = HH.AlivePlayers()
    if #alive == 0 then return end

    if D.mode == MODE_ENCOUNTER then
        thinkEncounter( alive )
        return
    end
    if D.mode == MODE_SIEGE then
        thinkSiege( alive )
        return
    end
    if D.mode ~= MODE_DORMANT then return end

    local elapsed = now() - HH.State.nightStart
    local grace = HH.CV.grace:GetFloat()

    if elapsed >= grace * 0.5 then
        for _, ply in ipairs( alive ) do
            trySighting( ply )
            tryPhantom( ply )
        end
    end

    if elapsed < grace then return end

    if D.siegeStarted then
        if now() >= D.respiteEnd then
            startWave()
            return
        end
    elseif shouldStartSiege() then
        startWave()
        return
    end

    tryEncounter( alive )
end

local function thinkVanish()
    if D.mode ~= MODE_VANISH then return end

    local killer = D.killer
    if not IsValid( killer ) then
        finishVanish()
        return
    end

    if not HH.IsEntitySeen( killer ) then
        finishVanish()
        return
    end

    if now() - D.vanishStart > VANISH_TIMEOUT then
        local watchers = {}
        for _, ply in ipairs( HH.AlivePlayers() ) do
            if HH.CanPlayerSee( ply, killer:WorldSpaceCenter() ) then
                table.insert( watchers, ply )
            end
        end

        if #watchers > 0 then
            HH.SendCue( HH.CUE_BLINK, killer:GetPos(), watchers )
        end

        finishVanish()
    end
end

function Director.Start()
    Director.Stop()

    local earliest = HH.CV.siege_earliest:GetFloat()
    local latest = math.max( earliest, HH.CV.siege_latest:GetFloat() )
    local minProgress = HH.CV.siege_progress:GetFloat()

    D.active = true
    D.mode = MODE_DORMANT
    D.killer = nil
    D.encounters = 0
    D.nextKillerAt = 0
    D.siegeStarted = false
    D.respiteEnd = 0
    D.ambushAt = nil
    D.sightCooldown = {}
    D.phantomCooldown = {}

    -- Tonight's temperament: how ready the cabin must be before it comes, and the latest it will wait.
    D.siegeProgressTarget = math.Rand( minProgress, 1 )
    D.siegeDeadline = math.Rand( ( earliest + latest ) * 0.5, latest )

    HH.Debug( string.format( "night rolled: siege at %.0f%% progress, deadline %.0f%% of the night", D.siegeProgressTarget * 100, D.siegeDeadline * 100 ) )

    timer.Create( "HorrorHelper_Director", THINK_INTERVAL, 0, think )
    timer.Create( "HorrorHelper_DirectorVanish", VANISH_INTERVAL, 0, thinkVanish )
end

function Director.Stop()
    D.active = false
    timer.Remove( "HorrorHelper_Director" )
    timer.Remove( "HorrorHelper_DirectorVanish" )
    removeKiller()
    D.mode = MODE_DORMANT
end

--[[ Damage: the killer shrugs off hits (unless allowed to die) but enough of them drive it off. ]]

hook.Add( "EntityTakeDamage", "HorrorHelper_Killer", function( target, dmg )
    if not D.active then return end

    local killer = D.killer
    if not IsValid( killer ) then return end

    -- While it leaves, it can't hurt anyone.
    if D.mode == MODE_VANISH and ( dmg:GetAttacker() == killer or dmg:GetInflictor() == killer ) and target ~= killer then
        return true
    end

    if target ~= killer then return end

    D.waveDamage = D.waveDamage + dmg:GetDamage()

    if not HH.CV.killer_can_die:GetBool() then
        dmg:SetDamage( 0 )
    end

    if D.waveDamage >= HH.CV.retreat_damage:GetFloat() and ( D.mode == MODE_SIEGE or D.mode == MODE_ENCOUNTER ) then
        HH.SendCue( HH.CUE_RETREAT, killer:GetPos() )
        beginVanish( "driven off" )
    end
end )

hook.Add( "OnNPCKilled", "HorrorHelper_Killer", function( npc )
    if npc ~= D.killer then return end

    HH.SendCue( HH.CUE_RETREAT, npc:GetPos() )
    D.killer = nil
    SetGlobal2Entity( "HH_Killer", NULL )

    if D.mode == MODE_SIEGE or D.siegeStarted then
        D.respiteEnd = now() + HH.CV.respite_max:GetFloat()
    end
    D.nextKillerAt = now() + ENCOUNTER_COOLDOWN_MAX
    D.mode = MODE_DORMANT
end )
