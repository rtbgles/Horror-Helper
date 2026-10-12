--[[
    The director. VJ Base NPCs on their own find the nearest player and run straight at them,
    so the killer here does not exist on the map until the director wants it to.

    It shows itself on a schedule: a first appearance by hh_first_contact seconds, then again
    and again, the gaps shrinking as dread rises (hh_contact_gap_max -> hh_contact_gap_min).
    Each appearance is one of:

      STALK    It stands out in the dark, watching one survivor who is away from the cabin.
               Notice it, stare too long or get too close and it either turns and walks off
               or, more often as the night wears on, comes for you. Shoot it and it comes.
      CHASE    It hunts a survivor. The chase ends near the cabin (hh_safe_margin), when it
               loses everyone, or after hh_pursuit_max.
      PROWL    Everyone is in the cabin: it circles outside, tries a door or window once or
               twice, and leaves. Step outside near it and it may give chase.
      SIEGE    An attack wave on the cabin: it bashes through the boards and comes in. Waves
               end after a while or when the survivors hurt it enough; then a respite.
      VANISH   It is leaving: it stops fighting and is removed the moment nobody is looking
               (or after a blink of black if someone stares it down).

    When the first siege comes is rolled per night: after enough setup progress plus a random
    delay, sometimes only once the cabin is fully ready, and always by a deadline. While the
    killer is not on the map, sv_dread.lua stages the psychological scares.
]]

local HH = HorrorHelper

HH.Director = HH.Director or {}
local Director = HH.Director

local MODE_DORMANT = 0
local MODE_CHASE = 1
local MODE_SIEGE = 2
local MODE_VANISH = 3
local MODE_STALK = 4
local MODE_PROWL = 5

local THINK_INTERVAL = 1
local FAST_INTERVAL = 0.25
local VANISH_TIMEOUT = 6 -- stared at this long while leaving, it blinks out anyway
local VANISH_RUN_DIST = 1500
local CONTACT_RETRY = 8 -- couldn't find a place for it: try again this soon

local AMBUSH_DELAY_MIN = 20 -- once the rolled progress is reached, the siege waits this long...
local AMBUSH_DELAY_MAX = 100 -- ...up to this long
local SURPRISE_SIEGE_PER_MIN = 0.04

local CHASE_SPAWN_MIN = 550
local CHASE_SPAWN_MAX = 1100
local CHASE_TRIES = 50
local CHASE_CHANCE_CALM = 0.2 -- a paced appearance away from the cabin is a chase this often at no dread...
local CHASE_CHANCE_PEAK = 0.7 -- ...and this often at full dread (the rest are stalks)
local LONE_RADIUS = 700
local LONE_FACTOR = 1.6
local GROUP_FACTOR = 0.5
local LOST_DIST = 2600
local LOST_TIME = 8
local UNSEEN_GIVE_UP = 30

local STALK_RANGE_CALM = { 900, 1500 } -- how far off it watches from at no dread...
local STALK_RANGE_PEAK = { 500, 950 } -- ...and at full dread
local STALK_NOTICE_TIME = 0.6 -- seen this long: they've noticed it
local STALK_STARE_LIMIT = 3.5 -- stared at this long: it decides
local STALK_BREAK_DIST = 450 -- come this close: it decides
local STALK_MAX = 40
local STALK_UNNOTICED_MAX = 25 -- nobody looked its way: give up and come back sooner
local STALK_SNAP_CALM = 0.3 -- chance it comes for you when it decides, at no dread...
local STALK_SNAP_PEAK = 0.85 -- ...and at full dread

local PROWL_SPAWN_MIN = 250 -- beyond the cabin's edge
local PROWL_SPAWN_MAX = 800
local PROWL_ARRIVE_DIST = 130
local PROWL_ARRIVE_TIMEOUT = 30
local PROWL_LINGER_CALM = 6
local PROWL_LINGER_PEAK = 12
local PROWL_MAX = 70
local PROWL_PROVOKE_DIST = 500
local PROWL_BASH_SCALE = 0.5 -- testing the boards, not breaking in

local SIEGE_SPAWN_MIN = 1300
local SIEGE_SPAWN_MAX = 2800
local SIEGE_TRIES = 80
local RETARGET_INTERVAL = 3
local BASH_RANGE = 70
local BASH_INTERVAL = 1.6
local POWER_BASH_SCALE = 0.75 -- the lit cabin slows it down a little
local STUCK_TIME = 12
local STUCK_MOVE = 96
local OUTSIDE_OFFSET = 72

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

local function dread()
    return HH.GetDread()
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

local function moveTo( killer, pos, walk )
    if not killer:IsNPC() then return end

    killer:SetLastPosition( pos )
    if isfunction( killer.SCHEDULE_GOTO_POSITION ) then
        pcall( killer.SCHEDULE_GOTO_POSITION, killer, walk and "TASK_WALK_PATH" or "TASK_RUN_PATH" )
    else
        killer:SetSchedule( walk and SCHED_FORCED_GO or SCHED_FORCED_GO_RUN )
    end
end

local function faceTowards( killer, ent )
    if isfunction( killer.SetTurnTarget ) then
        pcall( killer.SetTurnTarget, killer, ent, 1 )
    elseif killer:IsNPC() then
        killer:SetIdealYawAndUpdate( ( ent:GetPos() - killer:GetPos() ):Angle().y )
    end
end

-- Watch, don't fight.
local function makePassive( killer )
    if killer.IsVJBaseSNPC then
        if VJ_BEHAVIOR_PASSIVE then
            killer.Behavior = VJ_BEHAVIOR_PASSIVE
        end
        killer.EnemyDetection = false
        killer.DisableWandering = true
    end

    if not killer:IsNPC() then return end

    for _, ply in player.Iterator() do
        killer:AddEntityRelationship( ply, D_NU, 99 )
    end
    pcall( killer.SetEnemy, killer, NULL )
    killer:ClearEnemyMemory()
end

local function makeAggressive( killer )
    if killer.IsVJBaseSNPC then
        if VJ_BEHAVIOR_AGGRESSIVE then
            killer.Behavior = VJ_BEHAVIOR_AGGRESSIVE
        end
        killer.EnemyDetection = true
        killer.DisableWandering = false
    end

    if not killer:IsNPC() then return end

    for _, ply in player.Iterator() do
        killer:AddEntityRelationship( ply, D_HT, 99 )
    end
end

-- Stop fighting and walk off into the dark.
local function disengage( killer )
    makePassive( killer )
    if not killer:IsNPC() then return end

    local away = killer:GetPos() - cabinCenter()
    away.z = 0
    if away:IsZero() then
        away = Vector( 1, 0, 0 )
    end
    moveTo( killer, killer:GetPos() + away:GetNormalized() * VANISH_RUN_DIST, true )
end

local function spawnKiller( pos, yaw, passive )
    local ent = ents.Create( HH.State.killerClass )
    if not IsValid( ent ) then return nil end

    ent.CanChatMessage = false -- no "X no longer likes you" in chat
    ent:SetPos( pos )
    ent:SetAngles( Angle( 0, yaw, 0 ) )
    ent:SetNW2Bool( "HH_RoundEnt", true )
    ent:Spawn()
    ent:Activate()
    ent.HHKiller = true

    if passive then
        makePassive( ent )
    end

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

local function scheduleNextContact( soon )
    if soon then
        D.nextContactAt = now() + CONTACT_RETRY * 2
        return
    end

    local gap = Lerp( dread(), HH.CV.contact_gap_max:GetFloat(), HH.CV.contact_gap_min:GetFloat() )
    D.nextContactAt = now() + gap * math.Rand( 0.75, 1.25 )
end

local function beginVanish( reason )
    if D.mode == MODE_VANISH or D.mode == MODE_DORMANT then return end
    HH.Debug( "vanish:", reason )

    if D.mode == MODE_SIEGE then
        local respiteMin = HH.CV.respite_min:GetFloat()
        D.respiteEnd = now() + math.Rand( respiteMin, math.max( respiteMin, HH.CV.respite_max:GetFloat() ) )
    end

    D.mode = MODE_VANISH
    D.vanishStart = now()

    if IsValid( D.killer ) then
        disengage( D.killer )
    end
end

local function finishVanish()
    removeKiller()
    D.mode = MODE_DORMANT
    scheduleNextContact( D.missed )
    D.missed = false
end

--[[ Chases ]]

-- atCabin: it started right outside the cabin (a prowl someone walked into), so it ends
-- when they get back inside rather than at the usual distance from it.
local function startChaseFrom( killer, target, atCabin )
    makeAggressive( killer )

    D.mode = MODE_CHASE
    D.chaseAtCabin = atCabin or false
    D.target = target
    D.pursuitStart = now()
    D.lastSeen = now()
    D.lastNearby = now()
    D.stingerSent = HH.CanPlayerSee( target, killer:WorldSpaceCenter() )
    D.encounters = D.encounters + 1
    huntTarget( killer, target )

    if D.stingerSent then
        HH.SendCue( HH.CUE_ENCOUNTER, killer:GetPos(), target )
    end

    HH.Debug( "chase on", target:Nick() )
end

-- Out of sight, on the far side from the cabin, so the way out is towards it.
local function startChase( target )
    if D.encounters >= HH.CV.encounter_max:GetInt() then return false end

    local tpos = target:GetPos()
    local toCabin = cabinCenter() - tpos
    toCabin.z = 0
    toCabin:Normalize()

    local fallback
    local spot = HH.FindPoint( tpos, CHASE_SPAWN_MIN, CHASE_SPAWN_MAX, CHASE_TRIES, function( point )
        if distToCabin( point ) < cabinRadius() + HH.CV.safe_margin:GetFloat() then return false end
        if not HH.HullClear( point ) or HH.IsSpotSeen( point ) then return false end

        fallback = fallback or point
        local dir = point - tpos
        dir.z = 0
        dir:Normalize()

        return dir:Dot( toCabin ) < 0.1
    end ) or fallback

    if not spot then return false end

    local killer = spawnKiller( spot, ( tpos - spot ):Angle().y, false )
    if not killer then return false end

    startChaseFrom( killer, target )

    return true
end

local function thinkChase( alive )
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

    -- Making it back to the cabin ends a chase (the sieges are what come for the cabin).
    local margin = D.chaseAtCabin and cabinRadius() * 0.9 or cabinRadius() + HH.CV.safe_margin:GetFloat()
    if distToCabin( target:GetPos() ) <= margin then
        beginVanish( "reached the cabin" )
        return
    end
    if not D.chaseAtCabin and distToCabin( killer:GetPos() ) <= margin then
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

--[[ Stalking: it stands in the dark and watches ]]

local function startStalk( target )
    local d = dread()
    local minDist = Lerp( d, STALK_RANGE_CALM[1], STALK_RANGE_PEAK[1] )
    local maxDist = Lerp( d, STALK_RANGE_CALM[2], STALK_RANGE_PEAK[2] )
    local eye = target:EyePos()

    local spot = HH.FindPoint( target:GetPos(), minDist, maxDist, 50, function( point )
        if distToCabin( point ) < cabinRadius() + 100 then return false end
        if not HH.HullClear( point ) or HH.IsSpotSeen( point ) then return false end

        -- Out of their view right now, but in plain sight the moment they turn.
        local tr = util.TraceLine( { start = eye, endpos = point + Vector( 0, 0, 60 ), mask = MASK_BLOCKLOS, filter = target } )

        return not tr.Hit
    end )
    if not spot then return false end

    local killer = spawnKiller( spot, ( target:GetPos() - spot ):Angle().y, true )
    if not killer then return false end

    D.mode = MODE_STALK
    D.target = target
    D.stalkStart = now()
    D.stalkSeenFor = 0
    D.noticed = false

    HH.Debug( "stalking", target:Nick() )
    return true
end

local function stalkDecides( killer, target )
    if math.random() < Lerp( dread(), STALK_SNAP_CALM, STALK_SNAP_PEAK ) then
        startChaseFrom( killer, target )
        return
    end

    beginVanish( "stalk: it turns away" )
end

local function thinkStalk()
    local killer = D.killer
    if not IsValid( killer ) then
        finishVanish()
        return
    end

    local target = D.target
    if not IsValid( target ) or not target:Alive() or HH.IsOut( target ) then
        beginVanish( "stalk: target gone" )
        return
    end

    faceTowards( killer, target )

    local center = killer:WorldSpaceCenter()
    if HH.CanPlayerSee( target, center ) then
        D.stalkSeenFor = D.stalkSeenFor + FAST_INTERVAL

        if not D.noticed and D.stalkSeenFor >= STALK_NOTICE_TIME then
            D.noticed = true
            HH.SendCue( HH.CUE_NOTICE, killer:GetPos(), target )
        end
    end

    local dist = target:GetPos():Distance( killer:GetPos() )
    if dist < STALK_BREAK_DIST or D.stalkSeenFor >= STALK_STARE_LIMIT then
        stalkDecides( killer, target )
        return
    end

    if distToCabin( target:GetPos() ) <= cabinRadius() then
        beginVanish( "stalk: they made it inside" )
        return
    end

    local age = now() - D.stalkStart
    if not D.noticed and age > STALK_UNNOTICED_MAX then
        D.missed = true
        beginVanish( "stalk: nobody looked" )
    elseif age > STALK_MAX then
        beginVanish( "stalk: done watching" )
    end
end

--[[ Barricades ]]

local function roundBarricades()
    local list = {}

    for _, ent in ipairs( HH.State.roundEnts or {} ) do
        if IsValid( ent ) and ent.HHBarricade then
            table.insert( list, ent )
        end
    end

    return list
end

local function barricadeOutside( barricade )
    local fwd = barricade:GetForward()
    local base = barricade:GetPos() + Vector( 0, 0, 4 )
    local a = base + fwd * OUTSIDE_OFFSET
    local b = base - fwd * OUTSIDE_OFFSET

    if distToCabin( a ) > distToCabin( b ) then return a end

    return b
end

local function inBashReach( barricade, pos )
    local lp = barricade:WorldToLocal( pos )

    return math.abs( lp.x ) <= barricade.BoxThick * 0.5 + BASH_RANGE
        and math.abs( lp.y ) <= barricade.BoxWidth * 0.5 + 24
        and lp.z > -60 and lp.z < barricade.BoxHeight + 40
end

local function bash( barricade, scale )
    local damage = HH.CV.bash_damage:GetFloat() * scale
    if GetGlobal2Bool( "HH_Power", false ) then
        damage = damage * POWER_BASH_SCALE
    end

    D.nextBash = now() + BASH_INTERVAL
    barricade:ApplyBoardDamage( damage )
    util.ScreenShake( barricade:GetPos(), 4, 20, 0.4, 500 )
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

--[[ Prowling: everyone is inside, it circles and tests the boards ]]

local function startProwl()
    local center = cabinCenter()
    local radius = cabinRadius()

    local spot = HH.FindPoint( center, radius + PROWL_SPAWN_MIN, radius + PROWL_SPAWN_MAX, 60, function( point )
        return HH.HullClear( point ) and not HH.IsSpotSeen( point )
    end )
    if not spot then return false end

    local barricades = roundBarricades()
    local target = #barricades > 0 and barricades[math.random( #barricades )] or nil
    local goal = IsValid( target ) and barricadeOutside( target ) or ( center + ( spot - center ):GetNormalized() * radius )

    local killer = spawnKiller( spot, ( center - spot ):Angle().y, true )
    if not killer then return false end

    D.mode = MODE_PROWL
    D.prowlStart = now()
    D.prowlGoal = goal
    D.prowlTarget = target
    D.prowlArrivedAt = nil
    D.prowlBashes = 0
    D.prowlMaxBashes = 1 + math.floor( dread() * 3 )
    D.prowlProvoked = {}
    moveTo( killer, goal, true )

    HH.Debug( "prowling the cabin" )
    return true
end

local function thinkProwl( alive )
    local killer = D.killer
    if not IsValid( killer ) then
        finishVanish()
        return
    end

    local kpos = killer:GetPos()

    -- Someone stepped outside near it: one roll per person whether it comes for them.
    for _, ply in ipairs( alive ) do
        if not D.prowlProvoked[ply] and distToCabin( ply:GetPos() ) > cabinRadius() and ply:GetPos():Distance( kpos ) < PROWL_PROVOKE_DIST then
            D.prowlProvoked[ply] = true

            if math.random() < Lerp( dread(), STALK_SNAP_CALM, STALK_SNAP_PEAK ) then
                startChaseFrom( killer, ply, true )
            else
                beginVanish( "prowl: seen off" )
            end
            return
        end
    end

    if now() - D.prowlStart > PROWL_MAX then
        beginVanish( "prowl: done" )
        return
    end

    if not D.prowlArrivedAt then
        if kpos:Distance( D.prowlGoal ) < PROWL_ARRIVE_DIST or now() - D.prowlStart > PROWL_ARRIVE_TIMEOUT then
            D.prowlArrivedAt = now()
        elseif now() >= D.nextRetarget then
            D.nextRetarget = now() + RETARGET_INTERVAL
            moveTo( killer, D.prowlGoal, true )
        end
        return
    end

    local target = D.prowlTarget
    if IsValid( target ) and target:GetBoards() > 0 and D.prowlBashes < D.prowlMaxBashes and now() >= D.nextBash and inBashReach( target, kpos ) then
        D.prowlBashes = D.prowlBashes + 1
        bash( target, PROWL_BASH_SCALE )
        return
    end

    if now() - D.prowlArrivedAt > Lerp( dread(), PROWL_LINGER_CALM, PROWL_LINGER_PEAK ) then
        beginVanish( "prowl: moving on" )
    end
end

--[[ Sieges ]]

local function shouldStartSiege()
    local frac = nightFraction()
    if frac < HH.CV.siege_earliest:GetFloat() then return false end
    if frac >= D.siegeDeadline then
        HH.Debug( "siege: deadline" )
        return true
    end

    -- Not before the survivors have made it to the cabin.
    if HH.GetStage() ~= HH.STAGE_PREPARE then return false end

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

    local function hidden( point )
        return HH.HullClear( point ) and not HH.IsSpotSeen( point )
    end

    local spot = HH.FindPoint( center, radius + SIEGE_SPAWN_MIN, radius + SIEGE_SPAWN_MAX, SIEGE_TRIES, hidden )
        or HH.FindPoint( center, radius + 400, radius + SIEGE_SPAWN_MAX * 2, SIEGE_TRIES, hidden )

    if not spot then
        HH.Debug( "siege: nowhere to spawn, retrying" )
        D.respiteEnd = now() + 5
        return
    end

    local killer = spawnKiller( spot, ( center - spot ):Angle().y, false )
    if not killer then return end

    D.siegeStarted = true
    D.mode = MODE_SIEGE
    D.contacts = D.contacts + 1
    local waveMin = HH.CV.wave_min:GetFloat()
    D.waveEnd = now() + math.Rand( waveMin, math.max( waveMin, HH.CV.wave_max:GetFloat() ) )
    D.siegeTarget = pickSiegeTarget()

    moveTo( killer, IsValid( D.siegeTarget ) and barricadeOutside( D.siegeTarget ) or center )

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
    if now() < D.nextBash or not anyoneInside( alive ) then return false end

    local kpos = killer:GetPos()
    for _, barricade in ipairs( roundBarricades() ) do
        if barricade:GetBoards() > 0 and inBashReach( barricade, kpos ) then
            bash( barricade, 1 )
            return true
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

    -- Stuck somewhere it can't path from: when nobody is watching, it is simply at the boards.
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

--[[ Choosing the next appearance ]]

local function isolation( ply, alive )
    local _, dist = HH.NearestPlayer( ply:GetPos(), ( function()
        local others = {}
        for _, other in ipairs( alive ) do
            if other ~= ply then
                table.insert( others, other )
            end
        end
        return others
    end )() )

    return dist or 5000
end

local function tryContact( alive )
    if now() < D.nextContactAt then return end

    local margin = cabinRadius() + HH.CV.safe_margin:GetFloat()
    local outside = {}
    for _, ply in ipairs( alive ) do
        if distToCabin( ply:GetPos() ) > margin then
            table.insert( outside, ply )
        end
    end

    local started = false

    if #outside > 0 then
        -- The most isolated survivor, give or take.
        local target, best = nil, -1
        for _, ply in ipairs( outside ) do
            local score = isolation( ply, alive ) * math.Rand( 0.6, 1.4 )
            if score > best then
                target, best = ply, score
            end
        end

        local chaseChance = Lerp( dread(), CHASE_CHANCE_CALM, CHASE_CHANCE_PEAK )
        if D.contacts == 0 then
            chaseChance = chaseChance * 0.5 -- the first time, let them see it first
        end

        started = ( math.random() < chaseChance and startChase( target ) ) or startStalk( target )
    elseif HH.GetStage() == HH.STAGE_PREPARE then
        started = startProwl()
    end

    if started then
        D.contacts = D.contacts + 1
    else
        D.nextContactAt = now() + CONTACT_RETRY
    end
end

local function tryChanceEncounter( alive )
    if D.encounters >= HH.CV.encounter_max:GetInt() then return end

    local chance = HH.CV.encounter_chance:GetFloat() / 60 * THINK_INTERVAL
    local safeEdge = cabinRadius() + HH.CV.safe_margin:GetFloat() * 2

    for _, ply in ipairs( alive ) do
        if distToCabin( ply:GetPos() ) > safeEdge then
            local factor = isolation( ply, alive ) > LONE_RADIUS and LONE_FACTOR or GROUP_FACTOR

            if math.random() < chance * factor and startChase( ply ) then
                D.contacts = D.contacts + 1
                return
            end
        end
    end
end

--[[ The loop ]]

local function think()
    if HH.GetPhase() ~= HH.PHASE_NIGHT or not D.active then return end

    local alive = HH.AlivePlayers()
    if #alive == 0 then return end

    local d = HH.Psych.UpdateDread( D.contacts, D.siegeStarted )

    if D.mode == MODE_CHASE then
        thinkChase( alive )
        return
    end
    if D.mode == MODE_SIEGE then
        thinkSiege( alive )
        return
    end
    if D.mode == MODE_PROWL then
        thinkProwl( alive )
        return
    end
    if D.mode ~= MODE_DORMANT then return end

    local elapsed = now() - HH.State.nightStart
    local grace = HH.CV.grace:GetFloat()

    if elapsed >= grace * 0.5 then
        HH.Psych.Think( alive, d, THINK_INTERVAL )
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

    tryContact( alive )
    if D.mode == MODE_DORMANT then
        tryChanceEncounter( alive )
    end
end

local function thinkFast()
    if not D.active then return end

    if D.mode == MODE_STALK then
        thinkStalk()
        return
    end
    if D.mode ~= MODE_VANISH then return end

    local killer = D.killer
    if not IsValid( killer ) or not HH.IsEntitySeen( killer ) then
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
    HH.Psych.Reset()

    local earliest = HH.CV.siege_earliest:GetFloat()
    local latest = math.max( earliest, HH.CV.siege_latest:GetFloat() )
    local minProgress = HH.CV.siege_progress:GetFloat()

    D.active = true
    D.mode = MODE_DORMANT
    D.killer = nil
    D.encounters = 0
    D.contacts = 0
    D.siegeStarted = false
    D.respiteEnd = 0
    D.ambushAt = nil
    D.missed = false

    -- Tonight's temperament: how ready the cabin must be before it comes, and the latest it will wait.
    D.siegeProgressTarget = math.Rand( minProgress, 1 )
    D.siegeDeadline = math.Rand( ( earliest + latest ) * 0.5, latest )

    -- The first time it shows itself.
    local firstContact = HH.CV.first_contact:GetFloat()
    D.nextContactAt = now() + math.max( HH.CV.grace:GetFloat(), firstContact * math.Rand( 0.6, 1 ) )

    HH.Debug( string.format( "night rolled: siege at %.0f%% progress, deadline %.0f%% of the night, first appearance in %ds",
        D.siegeProgressTarget * 100, D.siegeDeadline * 100, math.Round( D.nextContactAt - now() ) ) )

    timer.Create( "HorrorHelper_Director", THINK_INTERVAL, 0, think )
    timer.Create( "HorrorHelper_DirectorFast", FAST_INTERVAL, 0, thinkFast )
end

function Director.Stop()
    D.active = false
    timer.Remove( "HorrorHelper_Director" )
    timer.Remove( "HorrorHelper_DirectorFast" )
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

    -- Shooting at something that was only watching is a bad idea.
    local attacker = dmg:GetAttacker()
    if ( D.mode == MODE_STALK or D.mode == MODE_PROWL ) and IsValid( attacker ) and attacker:IsPlayer() then
        startChaseFrom( killer, attacker, D.mode == MODE_PROWL )
        return
    end

    if D.waveDamage >= HH.CV.retreat_damage:GetFloat() and ( D.mode == MODE_SIEGE or D.mode == MODE_CHASE ) then
        HH.SendCue( HH.CUE_RETREAT, killer:GetPos() )
        beginVanish( "driven off" )
    end
end )

hook.Add( "OnNPCKilled", "HorrorHelper_Killer", function( npc )
    if npc ~= D.killer then return end

    HH.SendCue( HH.CUE_RETREAT, npc:GetPos() )
    D.killer = nil
    SetGlobal2Entity( "HH_Killer", NULL )

    if D.siegeStarted then
        D.respiteEnd = now() + HH.CV.respite_max:GetFloat()
    end
    D.mode = MODE_DORMANT
    scheduleNextContact()
end )
