--[[
    The round: waiting room -> opening film -> the night -> results -> back to Sandbox.

    Admin commands:
      hh_lobby        open the waiting room for everyone
      hh_start        start now (skips waiting for everyone to be ready)
      hh_stop         call the round off and put everyone back in Sandbox
      hh_set <cvar> <value>   change a hh_ setting (what the menu uses)
      hh_killer_test  spawn the configured killer where you look, to check the class works
]]

local HH = HorrorHelper

local FORCED_START_DELAY = 3
local LOBBY_THINK_INTERVAL = 0.5
local NIGHT_THINK_INTERVAL = 1
local SPECTATE_DELAY = 3
local CABIN_REQUEST_COOLDOWN = 1
local ITEM_MIN_SPACING = 350
local ITEM_TRIES = 900
local INTRO_SPOT_MIN = 500 -- the killer is filmed this far outside the cabin's edge...
local INTRO_SPOT_MAX = 1400 -- ...and no further
local NORMAL_LIGHT_STYLE = "m"
local FUSE_CARRY_LIMIT = 10
local LIGHTS_JOIN_DELAY = 5
local MAX_BODYGROUPS_SENT = 63

util.AddNetworkString( "HH_Cabins" )
util.AddNetworkString( "HH_Lobby" )
util.AddNetworkString( "HH_Intro" )
util.AddNetworkString( "HH_Lights" )
util.AddNetworkString( "HH_Cue" )
util.AddNetworkString( "HH_Sight" )

HH.State = HH.State or { roster = {}, roundEnts = {} }
local S = HH.State

local LOBBY_ACTION_READY = 1
local LOBBY_ACTION_VOTE = 2
local LOBBY_ACTION_REQUEST = 3

--[[ Small state helpers ]]

function HH.SetPhase( phase, phaseEnd )
    SetGlobal2Int( "HH_Phase", phase )
    SetGlobal2Float( "HH_PhaseEnd", phaseEnd or 0 )
    HH.Debug( "phase ->", phase )
end

function HH.SendCue( id, pos, recipients )
    net.Start( "HH_Cue" )
    net.WriteUInt( id, 4 )
    net.WriteVector( pos or vector_origin )

    if recipients then
        net.Send( recipients )
    else
        net.Broadcast()
    end
end

local function sendLights( recipients )
    net.Start( "HH_Lights" )
    if recipients then
        net.Send( recipients )
    else
        net.Broadcast()
    end
end

local function setDarkness( dark )
    S.dark = dark
    local style = string.lower( string.sub( HH.CV.darkness_style:GetString(), 1, 1 ) )
    if not string.match( style, "^[a-z]$" ) then style = "b" end

    engine.LightStyle( 0, dark and style or NORMAL_LIGHT_STYLE )
    sendLights()
end

local function killerDisplayName( class )
    local custom = string.Trim( HH.CV.killer_name:GetString() )
    if custom ~= "" then return custom end

    local entry = list.Get( "NPC" )[class]
    if entry and isstring( entry.Name ) then return entry.Name end

    return class
end

function HH.IsValidKillerClass( class )
    if class == "" then return false end
    if list.Get( "NPC" )[class] then return true end

    return scripted_ents.GetStored( class ) ~= nil
end

--[[ Carrying ]]

function HH.TryCarry( ply, kind )
    if kind == "fuse" then
        local have = ply:GetNW2Int( "HH_Fuses", 0 )
        if have >= FUSE_CARRY_LIMIT then
            ply:PrintMessage( HUD_PRINTCENTER, "Your pockets are full of fuses." )
            return false
        end

        ply:SetNW2Int( "HH_Fuses", have + 1 )
        return true
    end

    local have = ply:GetNW2Int( "HH_Planks", 0 )
    if have >= HH.CV.plank_carry:GetInt() then
        ply:PrintMessage( HUD_PRINTCENTER, "You can't carry any more planks." )
        return false
    end

    ply:SetNW2Int( "HH_Planks", have + 1 )
    return true
end

local function spawnItem( class, pos )
    local ent = ents.Create( class )
    if not IsValid( ent ) then return nil end

    local floor = util.TraceLine( {
        start = pos + Vector( 0, 0, 16 ),
        endpos = pos - Vector( 0, 0, 128 ),
        mask = MASK_SOLID_BRUSHONLY,
    } )
    local ground = floor.Hit and floor.HitPos or pos

    ent:SetPos( ground )
    ent:SetAngles( Angle( 0, math.Rand( 0, 360 ), 0 ) )
    ent:SetNW2Bool( "HH_RoundEnt", true )
    ent:Spawn()
    ent:Activate()
    -- Sit it on the ground rather than half inside it.
    ent:SetPos( ground + Vector( 0, 0, -ent:OBBMins().z + 1 ) )
    table.insert( S.roundEnts, ent )

    return ent
end

local function dropCarried( ply )
    local pos = ply:GetPos() + Vector( 0, 0, 16 )
    local fuses = ply:GetNW2Int( "HH_Fuses", 0 )
    local planks = ply:GetNW2Int( "HH_Planks", 0 )

    for i = 1, fuses do
        spawnItem( "hh_fuse", pos + Angle( 0, i * 50, 0 ):Forward() * 14 )
    end
    for i = 1, planks do
        spawnItem( "hh_planks", pos + Angle( 0, i * 70 + 25, 0 ):Forward() * 22 )
    end

    ply:SetNW2Int( "HH_Fuses", 0 )
    ply:SetNW2Int( "HH_Planks", 0 )
end

--[[ Totals the HUD and the director read ]]

function HH.RefreshTotals()
    local fusesIn, fusesNeeded, boards, boardsMax = 0, 0, 0, 0

    for _, ent in ipairs( S.roundEnts ) do
        if IsValid( ent ) then
            if ent:GetClass() == "hh_fusebox" then
                fusesIn = fusesIn + ent:GetFuses()
                fusesNeeded = fusesNeeded + ent:GetNeeded()
            elseif ent.HHBarricade then
                boards = boards + ent:GetBoards()
                boardsMax = boardsMax + ent.MaxBoards
            end
        end
    end

    SetGlobal2Int( "HH_FusesIn", fusesIn )
    SetGlobal2Int( "HH_FusesNeeded", fusesNeeded )
    SetGlobal2Int( "HH_Boards", boards )
    SetGlobal2Int( "HH_BoardsMax", boardsMax )

    local powered = fusesNeeded > 0 and fusesIn >= fusesNeeded
    if powered and not GetGlobal2Bool( "HH_Power", false ) then
        SetGlobal2Bool( "HH_Power", true )
        HH.SendCue( HH.CUE_POWER )
    end
end

-- 0..1: how set up the cabin is. A layout with nothing to do counts as fully set up.
function HH.GetSetupProgress()
    local total = GetGlobal2Int( "HH_FusesNeeded", 0 ) + GetGlobal2Int( "HH_BoardsMax", 0 )
    if total == 0 then return 1 end

    local done = GetGlobal2Int( "HH_FusesIn", 0 ) + GetGlobal2Int( "HH_Boards", 0 )

    return done / total
end

--[[ Waiting room ]]

local function sendCabinList( recipients )
    net.Start( "HH_Cabins" )
    net.WriteUInt( #HH.Cabins, 8 )
    for _, cabin in ipairs( HH.Cabins ) do
        net.WriteString( cabin.name )
    end

    if recipients then
        net.Send( recipients )
    else
        net.Broadcast()
    end
end

function HH.OpenLobby( ply )
    if HH.GetPhase() ~= HH.PHASE_IDLE then
        HH.Notify( ply, "A round is already running. hh_stop ends it." )
        return
    end
    if #HH.Cabins == 0 then
        HH.Notify( ply, "No cabins are saved on this map. Set one up first (see the Cabin Setup menu)." )
        return
    end

    for _, other in player.Iterator() do
        other:SetNW2Bool( "HH_Ready", false )
        other:SetNW2Int( "HH_Vote", 0 )
    end

    S.forced = false
    HH.SetPhase( HH.PHASE_LOBBY, 0 )
    sendCabinList()
    HH.NotifyAll( "[Until Sunrise] The waiting room is open. Pick a hideout and ready up." )
end

local function lobbyThink()
    if HH.GetPhase() ~= HH.PHASE_LOBBY then return end

    local total, ready = 0, 0
    for _, ply in player.Iterator() do
        total = total + 1
        if ply:GetNW2Bool( "HH_Ready", false ) then
            ready = ready + 1
        end
    end

    local countdownEnd = GetGlobal2Float( "HH_PhaseEnd", 0 )
    local everyoneReady = total > 0 and ready == total

    if countdownEnd == 0 and everyoneReady then
        SetGlobal2Float( "HH_PhaseEnd", CurTime() + HH.CV.lobby_countdown:GetInt() )
    elseif countdownEnd > 0 and not everyoneReady and not S.forced then
        SetGlobal2Float( "HH_PhaseEnd", 0 )
    elseif countdownEnd > 0 and CurTime() >= countdownEnd then
        HH.BeginRound()
    end
end

local function chooseCabin()
    local votes = {}
    for _, ply in player.Iterator() do
        local vote = ply:GetNW2Int( "HH_Vote", 0 )
        if HH.Cabins[vote] then
            votes[vote] = ( votes[vote] or 0 ) + 1
        end
    end

    local best, bestVotes, tied = nil, 0, {}
    for index, count in pairs( votes ) do
        if count > bestVotes then
            best, bestVotes, tied = index, count, { index }
        elseif count == bestVotes then
            table.insert( tied, index )
        end
    end

    if #tied > 1 then return HH.Cabins[tied[math.random( #tied )]] end
    if best then return HH.Cabins[best] end

    return HH.Cabins[math.random( #HH.Cabins )]
end

net.Receive( "HH_Lobby", function( _, ply )
    local action = net.ReadUInt( 3 )

    if action == LOBBY_ACTION_REQUEST then
        if ( ply.hhNextCabinRequest or 0 ) > CurTime() then return end
        ply.hhNextCabinRequest = CurTime() + CABIN_REQUEST_COOLDOWN
        sendCabinList( ply )
        return
    end

    if HH.GetPhase() ~= HH.PHASE_LOBBY then return end

    if action == LOBBY_ACTION_READY then
        ply:SetNW2Bool( "HH_Ready", net.ReadBool() )
    elseif action == LOBBY_ACTION_VOTE then
        local index = net.ReadUInt( 8 )
        if HH.Cabins[index] then
            ply:SetNW2Int( "HH_Vote", index )
        end
    end
end )

--[[ Starting the round ]]

local function scatterItems( cabin, class, count )
    local placed = 0
    local spots = S.itemSpots
    local minDist = cabin.radius + HH.CV.scavenge_min:GetFloat()
    local maxDist = math.max( minDist + 200, HH.CV.scavenge_max:GetFloat() )

    local function accept( point )
        for _, other in ipairs( spots ) do
            if other:Distance( point ) < ITEM_MIN_SPACING then return false end
        end

        return true
    end

    for _ = 1, ITEM_TRIES do
        if placed >= count then break end

        local point = HH.FindPoint( cabin.center, minDist, maxDist, 1, accept )
        if point then
            table.insert( spots, point )
            spawnItem( class, point )
            placed = placed + 1
        end
    end

    -- A cramped map can't fit them all spread out; put the rest anywhere in range.
    for _ = 1, ITEM_TRIES do
        if placed >= count then break end

        local point = HH.FindPoint( cabin.center, cabin.radius + 100, maxDist, 1 )
        if point then
            spawnItem( class, point )
            placed = placed + 1
        end
    end

    if placed < count then
        print( string.format( "[Horror Helper] Only placed %d of %d %s. Generate a navmesh (nav_generate) for better spread.", placed, count, class ) )
    end
end

local function pickIntroSpot( cabin )
    local minDist = cabin.radius + INTRO_SPOT_MIN
    local maxDist = cabin.radius + INTRO_SPOT_MAX

    local spot = HH.FindPoint( cabin.center, minDist, maxDist, 60, function( point )
        return HH.HullClear( point )
    end )

    return spot or HH.FindPoint( cabin.center, cabin.radius, maxDist * 2, 60 ) or cabin.center
end

-- Spawns the killer for a moment to learn what it looks like, for the film and the glimpses.
local function probeKiller( class, pos, yaw )
    local ent = ents.Create( class )
    if not IsValid( ent ) then return nil end

    ent.CanChatMessage = false
    ent:SetPos( pos )
    ent:SetAngles( Angle( 0, yaw, 0 ) )
    ent:Spawn()
    ent:Activate()

    local look = {
        model = ent:GetModel() or "",
        skin = ent:GetSkin() or 0,
        bodygroups = {},
    }
    for i = 0, ent:GetNumBodyGroups() - 1 do
        look.bodygroups[i + 1] = ent:GetBodygroup( i )
    end

    ent:Remove()

    return look
end

local function giveLoadout( ply )
    ply:StripWeapons()

    for _, class in ipairs( string.Explode( ",", HH.CV.loadout:GetString() ) ) do
        class = string.Trim( class )
        if class ~= "" then
            ply:Give( class )
        end
    end

    ply:AllowFlashlight( true )
end

local function makeSpectator( ply )
    if not IsValid( ply ) then return end

    ply:SetNW2Bool( "HH_Out", true )
    if ply:Alive() then
        ply:KillSilent()
    end

    ply:StripWeapons()
    ply:Spectate( OBS_MODE_ROAMING )
end

function HH.BeginRound()
    if HH.GetPhase() ~= HH.PHASE_LOBBY then return end

    local class = string.Trim( HH.CV.killer_class:GetString() )
    if not HH.IsValidKillerClass( class ) then
        HH.NotifyAll( "[Until Sunrise] The killer class '" .. class .. "' doesn't exist on this server. An admin needs to fix it in the Horror Helper menu." )
        SetGlobal2Float( "HH_PhaseEnd", 0 )
        S.forced = false
        return
    end

    local cabin = chooseCabin()
    if not cabin then
        HH.SetPhase( HH.PHASE_IDLE )
        return
    end

    S.cabin = cabin
    S.killerClass = class
    S.roster = {}
    S.roundEnts = {}
    S.itemSpots = {}

    local navCount = HH.BuildNavCache()
    if navCount == 0 then
        HH.NotifyAll( "[Until Sunrise] This map has no navmesh, so items and the killer are placed roughly. An admin can run nav_generate to fix that." )
    end

    -- Hand-placed setup pieces would double up with the round's copies.
    HH.ClearPlacedPieces()

    for _, ent in ipairs( HH.SpawnCabinPieces( cabin, true ) ) do
        table.insert( S.roundEnts, ent )
    end

    for _, ent in ipairs( S.roundEnts ) do
        if ent:GetClass() == "hh_fusebox" then
            ent:SetNeeded( HH.CV.fuses_per_box:GetInt() )
        end
    end

    SetGlobal2Bool( "HH_Power", false )
    SetGlobal2Vector( "HH_CabinCenter", cabin.center )
    SetGlobal2Float( "HH_CabinRadius", cabin.radius )
    SetGlobal2String( "HH_CabinName", cabin.name )
    SetGlobal2Entity( "HH_Killer", NULL )
    SetGlobal2Int( "HH_Outcome", HH.OUTCOME_NONE )
    HH.RefreshTotals()

    -- One spare fuse, so a fuse lost somewhere awful doesn't end the night's hopes.
    local fuseCount = GetGlobal2Int( "HH_FusesNeeded", 0 )
    if fuseCount > 0 then
        fuseCount = fuseCount + 1
    end
    local plankCount = GetGlobal2Int( "HH_BoardsMax", 0 ) + HH.CV.spare_planks:GetInt()

    scatterItems( cabin, "hh_fuse", fuseCount )
    scatterItems( cabin, "hh_planks", plankCount )

    -- Everyone starts at the cabin.
    local taken = {}
    for _, ply in player.Iterator() do
        S.roster[ply] = true
        ply:SetNW2Bool( "HH_Out", false )
        ply:SetNW2Bool( "HH_Ready", false )
        ply:SetNW2Int( "HH_Fuses", 0 )
        ply:SetNW2Int( "HH_Planks", 0 )

        if ply:InVehicle() then
            ply:ExitVehicle()
        end
        ply:UnSpectate()
        ply:Spawn()
        giveLoadout( ply )

        local spot = HH.FindPlayerSpot( cabin.center, taken )
        table.insert( taken, spot )
        ply:SetPos( spot )
    end

    if HH.CV.darkness:GetBool() then
        setDarkness( true )
    end

    local introSpot = pickIntroSpot( cabin )
    S.introSpot = introSpot
    local toCabin = cabin.center - introSpot
    local yaw = toCabin:Angle().y
    S.killerLook = probeKiller( class, introSpot, yaw ) or { model = "", skin = 0, bodygroups = {} }
    SetGlobal2String( "HH_KillerModel", S.killerLook.model )
    SetGlobal2String( "HH_KillerName", killerDisplayName( class ) )

    if not HH.CV.intro:GetBool() then
        HH.StartNight()
        return
    end

    local start = CurTime() + 0.5
    HH.SetPhase( HH.PHASE_INTRO, start + HH.INTRO_LENGTH )

    net.Start( "HH_Intro" )
    net.WriteDouble( start )
    net.WriteVector( introSpot )
    net.WriteFloat( yaw )
    net.WriteVector( cabin.center )
    net.WriteString( S.killerLook.model )
    net.WriteUInt( math.Clamp( S.killerLook.skin, 0, 255 ), 8 )
    local groupCount = math.min( #S.killerLook.bodygroups, MAX_BODYGROUPS_SENT )
    net.WriteUInt( groupCount, 6 )
    for i = 1, groupCount do
        net.WriteUInt( math.Clamp( S.killerLook.bodygroups[i], 0, 255 ), 8 )
    end
    net.WriteString( GetGlobal2String( "HH_KillerName", "" ) )
    net.Broadcast()

    timer.Create( "HorrorHelper_IntroEnd", start + HH.INTRO_LENGTH - CurTime(), 1, function()
        if HH.GetPhase() == HH.PHASE_INTRO then
            HH.StartNight()
        end
    end )
end

function HH.StartNight()
    local length = HH.CV.night_minutes:GetFloat() * 60
    S.nightStart = CurTime()
    S.nightLength = length

    SetGlobal2Float( "HH_NightStart", S.nightStart )
    SetGlobal2Float( "HH_NightLength", length )
    HH.SetPhase( HH.PHASE_NIGHT, S.nightStart + length )

    HH.Director.Start()
end

--[[ Ending the round ]]

local function nightThink()
    if HH.GetPhase() ~= HH.PHASE_NIGHT then return end

    if CurTime() >= GetGlobal2Float( "HH_PhaseEnd", 0 ) then
        HH.EndRound( HH.OUTCOME_SURVIVED )
        return
    end

    if #HH.AlivePlayers() == 0 then
        HH.EndRound( HH.OUTCOME_KILLED )
    end
end

function HH.EndRound( outcome )
    if not HH.InRound() or HH.GetPhase() == HH.PHASE_RESULTS then return end

    timer.Remove( "HorrorHelper_IntroEnd" )
    HH.Director.Stop()

    SetGlobal2Int( "HH_Outcome", outcome )
    HH.SetPhase( HH.PHASE_RESULTS, CurTime() + HH.RESULTS_LENGTH )

    if outcome == HH.OUTCOME_SURVIVED then
        setDarkness( false )
        HH.SendCue( HH.CUE_SUNRISE )
    end

    timer.Create( "HorrorHelper_Cleanup", HH.RESULTS_LENGTH, 1, HH.Cleanup )
end

function HH.Cleanup()
    timer.Remove( "HorrorHelper_IntroEnd" )
    timer.Remove( "HorrorHelper_Cleanup" )
    HH.Director.Stop()

    for _, ent in ipairs( S.roundEnts or {} ) do
        if IsValid( ent ) then
            ent:Remove()
        end
    end
    S.roundEnts = {}

    -- Items dropped by the dead aren't in roundEnts if they were spawned late; sweep by flag.
    for _, ent in ents.Iterator() do
        if ent:GetNW2Bool( "HH_RoundEnt", false ) then
            ent:Remove()
        end
    end

    if S.dark then
        setDarkness( false )
    end

    local roster = S.roster or {}
    S.roster = {}
    HH.SetPhase( HH.PHASE_IDLE )
    SetGlobal2Bool( "HH_Power", false )
    SetGlobal2Entity( "HH_Killer", NULL )

    for _, ply in player.Iterator() do
        local wasPlaying = roster[ply] or HH.IsOut( ply )
        ply:SetNW2Bool( "HH_Out", false )
        ply:SetNW2Int( "HH_Fuses", 0 )
        ply:SetNW2Int( "HH_Planks", 0 )

        if wasPlaying then
            ply:UnSpectate()
            ply:Spawn()
        end
    end
end

function HH.Abort()
    local phase = HH.GetPhase()

    if phase == HH.PHASE_LOBBY then
        HH.SetPhase( HH.PHASE_IDLE )
        HH.NotifyAll( "[Until Sunrise] The waiting room was closed." )
        return
    end

    if HH.InRound() then
        HH.Cleanup()
        HH.NotifyAll( "[Until Sunrise] The night was called off." )
    end
end

--[[ Hooks ]]

hook.Add( "PlayerLoadout", "HorrorHelper_Loadout", function( ply )
    if not HH.InRound() or not S.roster[ply] then return end

    giveLoadout( ply )
    return true
end )

hook.Add( "PlayerSpawn", "HorrorHelper_LateJoin", function( ply )
    local phase = HH.GetPhase()
    if phase ~= HH.PHASE_INTRO and phase ~= HH.PHASE_NIGHT then return end
    if S.roster[ply] and not HH.IsOut( ply ) then return end

    -- Joined late or already died: watch from the dark.
    timer.Simple( 0, function()
        makeSpectator( ply )
    end )
end )

local function onDeath( ply )
    if not HH.InRound() or not S.roster[ply] then return end
    if HH.IsOut( ply ) then return end

    dropCarried( ply )
    ply:SetNW2Bool( "HH_Out", true )
    local deathPos = ply:GetPos()

    timer.Simple( SPECTATE_DELAY, function()
        if not IsValid( ply ) or not HH.InRound() or ply:Alive() then return end

        ply:Spectate( OBS_MODE_ROAMING )
        ply:SetPos( deathPos + Vector( 0, 0, 48 ) )
    end )
end

hook.Add( "PlayerDeath", "HorrorHelper_Death", onDeath )
hook.Add( "PlayerSilentDeath", "HorrorHelper_Death", onDeath )

hook.Add( "PlayerDeathThink", "HorrorHelper_NoRespawn", function( ply )
    if HH.InRound() and HH.IsOut( ply ) then return false end
end )

hook.Add( "PlayerDisconnected", "HorrorHelper_Leave", function( ply )
    if S.roster then
        S.roster[ply] = nil
    end
end )

hook.Add( "PlayerInitialSpawn", "HorrorHelper_JoinLights", function( ply )
    if not S.dark then return end

    timer.Simple( LIGHTS_JOIN_DELAY, function()
        if IsValid( ply ) and S.dark then
            sendLights( ply )
        end
    end )
end )

hook.Add( "PlayerCanHearPlayersVoice", "HorrorHelper_ProximityVoice", function( listener, talker )
    if not HH.InRound() or not HH.CV.proxvoice:GetBool() then return end

    if HH.IsOut( listener ) then return true, false end
    if HH.IsOut( talker ) then return false end

    local range = HH.CV.voice_range:GetFloat()
    if listener:GetPos():DistToSqr( talker:GetPos() ) > range * range then return false end

    return true, true
end )

local function blockSpawning( ply )
    if HH.Restricts( ply ) then return false end
end

hook.Add( "PlayerSpawnProp", "HorrorHelper_Restrict", blockSpawning )
hook.Add( "PlayerSpawnNPC", "HorrorHelper_Restrict", blockSpawning )
hook.Add( "PlayerSpawnSENT", "HorrorHelper_Restrict", blockSpawning )
hook.Add( "PlayerSpawnSWEP", "HorrorHelper_Restrict", blockSpawning )
hook.Add( "PlayerGiveSWEP", "HorrorHelper_Restrict", blockSpawning )
hook.Add( "PlayerSpawnVehicle", "HorrorHelper_Restrict", blockSpawning )
hook.Add( "PlayerSpawnObject", "HorrorHelper_Restrict", blockSpawning )
hook.Add( "PlayerSpawnRagdoll", "HorrorHelper_Restrict", blockSpawning )
hook.Add( "PlayerSpawnEffect", "HorrorHelper_Restrict", blockSpawning )

-- The film is shot far from where everyone stands; make sure what's around it is sent.
hook.Add( "SetupPlayerVisibility", "HorrorHelper_IntroPVS", function()
    if HH.GetPhase() == HH.PHASE_INTRO and S.introSpot then
        AddOriginToPVS( S.introSpot )
    end
end )

timer.Create( "HorrorHelper_LobbyThink", LOBBY_THINK_INTERVAL, 0, lobbyThink )
timer.Create( "HorrorHelper_NightThink", NIGHT_THINK_INTERVAL, 0, nightThink )

--[[ Commands ]]

local function adminCommand( name, fn )
    concommand.Add( name, function( ply, cmd, args )
        if not HH.IsAdmin( ply ) then
            HH.Notify( ply, "Admins only." )
            return
        end

        fn( ply, cmd, args )
    end )
end

adminCommand( "hh_lobby", function( ply )
    HH.OpenLobby( ply )
end )

adminCommand( "hh_start", function( ply )
    if HH.GetPhase() == HH.PHASE_IDLE then
        HH.OpenLobby( ply )
    end
    if HH.GetPhase() ~= HH.PHASE_LOBBY then return end

    S.forced = true
    SetGlobal2Float( "HH_PhaseEnd", CurTime() + FORCED_START_DELAY )
end )

adminCommand( "hh_stop", function()
    HH.Abort()
end )

adminCommand( "hh_set", function( ply, _, args )
    local name = args[1] or ""
    if not HH.CvarByName[name] then
        HH.Notify( ply, "Unknown setting '" .. name .. "'." )
        return
    end

    local value = table.concat( args, " ", 2 )
    GetConVar( name ):SetString( value )
end )

adminCommand( "hh_killer_test", function( ply )
    if not IsValid( ply ) or HH.InRound() then return end

    local class = string.Trim( HH.CV.killer_class:GetString() )
    if not HH.IsValidKillerClass( class ) then
        HH.Notify( ply, "'" .. class .. "' isn't an NPC on this server." )
        return
    end

    local ent = ents.Create( class )
    if not IsValid( ent ) then return end

    ent:SetPos( ply:GetEyeTrace().HitPos + Vector( 0, 0, 8 ) )
    ent:SetAngles( Angle( 0, ply:EyeAngles().y + 180, 0 ) )
    ent:Spawn()
    ent:Activate()

    undo.Create( "NPC" )
    undo.AddEntity( ent )
    undo.SetPlayer( ply )
    undo.Finish()

    HH.Notify( ply, "Spawned '" .. class .. "' as '" .. killerDisplayName( class ) .. "'." )
end )
