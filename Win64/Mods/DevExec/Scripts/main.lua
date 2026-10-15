-- DevExec — runs MvsCmd.lua (next to the exe) in the game thread whenever it
-- appears, then renames it to MvsCmd.done. Output goes to UE4SS.log via print.
-- Lets tooling drive the game without keyboard/mouse input or hot reloads.
--
-- Also provides Press(obj, fn): asks MvsRevival.dll to call UFunction `fn`
-- (default "HandleButtonClicked") on `obj` natively via ProcessEvent — e.g. to
-- click a CommonUI button. The DLL runs it on the game thread from its
-- item-count hook, which we nudge via IsDebugAllUnlocked().

local CMD, DONE, CALL = "MvsCmd.lua", "MvsCmd.done", "MvsRevival.call"

-- A command left behind by a run that died would otherwise execute during boot,
-- before the engine's objects exist, and crash UE4SS (null UObject reads).
for _, stale in ipairs({ CMD, CALL, "MvsRevival.peek", "MvsRevival.poke", "MvsNet.txt" }) do os.remove(stale) end

-- Object scans (FindFirstOf/FindAllOf) are unsafe while assets stream in: the
-- async loader registers objects before their class is set, and UE4SS then reads
-- a null class (crash in UE4SS.dll). NotifyOnNewObject callbacks are no better
-- (they run on the loader thread). So everything here hangs off the game
-- instance, captured when a world's game state initialises (game thread), through
-- property chains and engine helper libraries; Cached() scans remain only for
-- ad-hoc commands at idle moments.
local game_instance = nil
local function remember_gi(ctx)
    pcall(function()
        game_instance = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetGameInstance(ctx:get())
    end)
end
-- The first world's game state passes through InitGameState (native hook, game
-- thread): remember the game instance from it.
pcall(RegisterInitGameStatePostHook, function(ctx)
    if game_instance and game_instance:IsValid() then return end   -- only needed once
    local gs = ctx:get()
    remember_gi({ get = function() return gs end })
end)

local function statics() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end

-- Travel guard: MvsRevival.dll writes MvsRevival.travel whenever the game calls
-- OpenLevel. The current world is then torn down while the next one streams in;
-- touching any world object in that window crashes UE4SS (it cannot detect freed
-- objects). Traveling() is true for TRAVEL_QUIET seconds after each travel.
local TRAVEL_QUIET = 8
local travel_until = 0
function Traveling()
    local f = io.open("MvsRevival.travel", "r")
    if f then
        f:close(); os.remove("MvsRevival.travel")
        travel_until = os.clock() + TRAVEL_QUIET
        print("[DevExec] travel: world queries paused\n")
    end
    return os.clock() < travel_until
end

-- Cached UI objects die with their world (travel), and UE4SS's IsValid() can't
-- detect a freed object, so everything but long-lived singletons is dropped
-- whenever the world's game state changes.
local cache, cache_world = {}, nil
local persistent = { InventoryManager = true, MvsGameplayConfig = true, cfg = true }
function Cached(class_name)
    if game_instance and game_instance:IsValid() then
        local gs = statics():GetGameState(game_instance)
        local w = (gs and gs:IsValid()) and gs:GetAddress() or 0
        if w ~= cache_world then
            for k in pairs(cache) do if not persistent[k] then cache[k] = nil end end
            cache_world = w
        end
    end
    local o = cache[class_name]
    if o and o:IsValid() then return o end
    for _, x in ipairs(FindAllOf(class_name) or {}) do
        -- live instances sit under /Engine/Transient (the game instance); skip class
        -- defaults and Blueprint widget templates
        local n = x:IsValid() and x:GetFullName() or ""
        if n:find("/Engine/Transient", 1, true) and not n:find("Default__", 1, true) then cache[class_name] = x; return x end
    end
    return nil
end

function GameInstance()
    if game_instance and game_instance:IsValid() then return game_instance end
    return nil
end

-- WorldInfo(): "<game state class> <seconds since the world changed>" without any
-- object scan — safe to poll at any time (tools wait for age >= 6 before scanning).
local world_addr, world_since = nil, os.clock()
function WorldInfo()
    if Traveling() then world_addr = nil; world_since = os.clock(); return "traveling 0" end
    local gi = GameInstance()
    local gs = gi and statics():GetGameState(gi)
    if not gs or not gs:IsValid() then world_addr = nil; world_since = os.clock(); return "loading 0" end
    if gs:GetAddress() ~= world_addr then world_addr = gs:GetAddress(); world_since = os.clock() end
    return string.format("%s %d", Name(gs:GetClass()), math.floor(os.clock() - world_since))
end

-- The current match's game state (nil in the front end / while loading).
local fixed_gs_class = nil
function GameState()
    local gi = GameInstance()
    if not gi then return nil end
    local gs = statics():GetGameState(gi)
    if not gs or not gs:IsValid() then return nil end
    fixed_gs_class = fixed_gs_class or StaticFindObject("/Script/PfgFixed2DGame.PfgFixedGameStateBase")
    if gs:IsA(fixed_gs_class) then return gs end
    return nil
end

function Config()
    local c = cache.cfg
    if c and c:IsValid() then return c end
    local gi = GameInstance()
    if gi then
        c = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetGameInstanceSubsystem(gi,
            StaticFindObject("/Script/MultiVersus.MvsGameplayConfig"))
        if c and c:IsValid() then cache.cfg = c; return c end
    end
    return Cached("MvsGameplayConfig")
end

local function pump()
    local inv = Cached("InventoryManager")  -- long-lived; scanned once at an idle moment
    if inv and inv:IsValid() then inv:IsDebugAllUnlocked() end
end

function Press(obj, fn)
    if not obj or not obj:IsValid() then return "invalid object" end
    local f = io.open(CALL, "w")
    f:write(string.format("%X %s", obj:GetAddress(), fn or "HandleButtonClicked"))
    f:close()
    pump()
    return "requested " .. (fn or "HandleButtonClicked") .. " on " .. obj:GetFName():ToString()
end

-- Peek(obj_or_address, offset, length): MvsRevival.dll hex-dumps native memory
-- into MvsRevival.log (fields that reflection doesn't expose).
function Peek(target, offset, len)
    local base = type(target) == "number" and target or target:GetAddress()
    local f = io.open("MvsRevival.peek", "w")
    f:write(string.format("%X %X", base + (offset or 0), len or 0x40))
    f:close()
    pump()
    return string.format("peek %X+%X", base, offset or 0)
end

-- Poke(obj_or_address, offset, "hexbytes"): MvsRevival.dll writes native memory.
function Poke(target, offset, hex)
    local base = type(target) == "number" and target or target:GetAddress()
    local f = io.open("MvsRevival.poke", "w")
    f:write(string.format("%X %s", base + (offset or 0), hex))
    f:close()
    pump()
    return string.format("poke %X+%X", base, offset or 0)
end

-- Auto-connect: if MvsNet.txt exists ("ip port team player matchid matchkey env"),
-- call StartMatch on each new match game state as soon as its netcode session
-- exists, before the match begins, so the session drives the match from frame 0.
local last_gs = nil

-- The game possesses fighters by controller id, and a remote human (LocalControllerId
-- -1) listed after the local player steals the local controller: the host then drives
-- the other player's fighter and its own netcode input stays empty. For the first
-- seconds of each match, make sure our controller is on the fighter with our index.
local possess_key, possess_until = nil, 0
local function fix_possession(gs, match_key, player)
    if possess_key ~= match_key then possess_key = match_key; possess_until = os.clock() + 20 end
    if os.clock() > possess_until then return end
    local pc = statics():GetPlayerController(gs, 0)
    if not pc or not pc:IsValid() then return end
    local pawn = pc.Pawn
    if pawn and pawn:IsValid() and pawn.PlayerIndex == player then return end
    for _, c in ipairs(FindAllOf("MvsFixedCharacter") or {}) do
        if c:IsValid() and c.PlayerIndex == player then
            pc:Possess(c)
            print(string.format("[DevExec] controller moved to our fighter (player %d)\n", player))
            return
        end
    end
end

local function auto_connect()
    local f = io.open("MvsNet.txt", "r")
    if not f then return end
    local line = f:read("l") or ""; f:close()
    local ip, port, team, player, mid, key, env = line:match("^(%S+)%s+(%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
    if not ip then return end
    local gs = GameState()
    if not gs then return end
    -- StartMatch writes into the session; calling it before the game state has
    -- created its UPfgNetcodeSession crashes (null+0x700).
    local session = gs.NetcodeSession
    if not session or not session:IsValid() then return end
    -- A reloaded map can reuse the game state's address, so key on the pair
    -- (game state, session); the session is created fresh for every match.
    -- (Calling GetFullName() on the just-spawned game state kills the process.)
    local match_key = string.format("%X/%X", gs:GetAddress(), session:GetAddress())
    if match_key == last_gs then
        if gs.MatchStarted then pcall(fix_possession, gs, match_key, tonumber(player)) end
        return
    end
    last_gs = match_key
    -- (MvsRevival.dll's StartMatch hook also clears the game state's "offline match"
    -- flag, without which AdvanceFrame never feeds the netcode session.)
    gs:StartMatch(ip, tonumber(port), tonumber(team), tonumber(player), mid, key, env)
    print(string.format("[DevExec] auto StartMatch %s:%s team=%s player=%s matchStarted=%s\n",
        ip, port, team, player, tostring(gs.MatchStarted)))
end

-- ApplyMatchSpec(): rewrites the current UMvsGameplayConfig from MvsSpec.txt so
-- every client builds the identical match. Format (one item per line):
--   local <slot>                       which slot this client controls
--   slot <i> <team> <CharacterDataPath> <SkinDataPath> [bot]
--   map <MapDataPath>                  stage (UMapData), so every client loads the same one
--   matchtype <n>                      EMvsMatchType: 1 PvP, 2 LocalPlay, 4 Lab
--   intro <0|1>                        play the fighter intro (ArmMatchSpec only)
-- Slots must already exist in the config (the Lab provides 2). Remote humans get
-- IsBot=false and LocalControllerId=-1; the local slot gets controller 0.
-- Takes effect on the next map load (reload the map afterwards).
function ApplyMatchSpec()
    local f = io.open("MvsSpec.txt", "r")
    if not f then return "no MvsSpec.txt" end
    local local_slot, slots, match_type, map_path = 0, {}, nil, nil
    for line in f:lines() do
        map_path = line:match("^map%s+(%S+)") or map_path
        local mt = line:match("^matchtype%s+(%d+)")   -- EMvsMatchType: 1 PvP, 2 LocalPlay, 4 Lab
        if mt then match_type = tonumber(mt) end
        local ls = line:match("^local%s+(%d+)")
        if ls then local_slot = tonumber(ls) end
        local i, team, cpath, spath = line:match("^slot%s+(%d+)%s+(%d+)%s+(%S+)%s+(%S+)")
        if i then slots[#slots + 1] = { tonumber(i), tonumber(team), cpath, spath, line:match("%sbot%s*$") ~= nil } end
    end
    f:close()
    local cfg = Config()
    if not cfg or not cfg:IsValid() then return "no config" end
    if match_type then cfg.MatchType = match_type end
    -- The fighter intro is sequenced by the front end's own travel; after our map
    -- reload it never runs and the fighters stay hidden. Skip it.
    cfg.PlayIntro = false
    if map_path then
        local m = LoadAsset(map_path)
        if m then cfg.MapData = m else print("[DevExec] spec: map not found " .. map_path .. "\n") end
    end
    for _, s in ipairs(slots) do
        local i, team, cpath, spath, bot = s[1], s[2], s[3], s[4], s[5]
        local p = cfg.Players[i + 1]
        if p then
            local c, k = LoadAsset(cpath), LoadAsset(spath)
            if c then p.Character = c end
            if k then p.Skin = k end
            p.TeamIndex = team
            p.PlayerIndex = i
            p.IsBot = bot
            p.LocalControllerId = (i == local_slot and not bot) and 0 or -1
        end
    end
    -- Local Play restores the last session's extra bots; every client must simulate
    -- exactly the spec's slots, so shrink Players (TArray Num at config+0x78).
    if #slots > 0 and #cfg.Players > #slots then
        Poke(cfg, 0x78, string.format("%02X000000", #slots))
    end
    return DescribeConfig("spec applied (local " .. local_slot .. ")")
end

-- ArmMatchSpec(): resolves MvsSpec.txt (same format as ApplyMatchSpec) to object
-- addresses and hands it to MvsRevival.dll, which applies it inside the game's own
-- OpenLevel when Local Play starts the match (config + stage in one atomic step).
-- Call it at an idle moment (e.g. on the Local Play screen, before Ready).
function ArmMatchSpec()
    local f = io.open("MvsSpec.txt", "r")
    if not f then return "no MvsSpec.txt" end
    local local_slot, slots, match_type, map_path, intro, duration = 0, {}, 2, nil, nil, nil
    for line in f:lines() do
        map_path = line:match("^map%s+(%S+)") or map_path
        intro = tonumber(line:match("^intro%s+(%d)") or intro)
        duration = tonumber(line:match("^duration%s+(%d+)") or duration)
        match_type = tonumber(line:match("^matchtype%s+(%d+)") or match_type)
        local_slot = tonumber(line:match("^local%s+(%d+)") or local_slot)
        local i, team, cpath, spath = line:match("^slot%s+(%d+)%s+(%d+)%s+(%S+)%s+(%S+)")
        if i then slots[#slots + 1] = { tonumber(i), tonumber(team), cpath, spath, line:match("%sbot%s*$") ~= nil } end
    end
    f:close()
    local cfg = Config()
    if not cfg then return "no config" end
    local out = { string.format("cfg %X", cfg:GetAddress()), string.format("matchtype %d", match_type),
                  string.format("count %d", #slots) }
    if intro then out[#out + 1] = string.format("playintro %d", intro) end
    if duration then out[#out + 1] = string.format("duration %d", duration) end
    if map_path then
        local m = LoadAsset(map_path)
        if not m or not m:IsValid() then return "map not found: " .. map_path end
        local level = m:GetFullName():match("%s(%S+)_[Dd]ata%.")
        out[#out + 1] = string.format("map %X %s", m:GetAddress(), level)
    end
    for _, s in ipairs(slots) do
        local c, k = LoadAsset(s[3]), LoadAsset(s[4])
        if not c or not c:IsValid() or not k or not k:IsValid() then return "asset not found for slot " .. s[1] end
        local bot = s[5]
        out[#out + 1] = string.format("slot %d %d %X %X %d %d", s[1], s[2], c:GetAddress(), k:GetAddress(),
            bot and 1 or 0, (s[1] == local_slot and not bot) and 0 or -1)
    end
    local w = io.open("MvsRevival.matchspec", "w")
    w:write(table.concat(out, "\n") .. "\n"); w:close()
    return "armed: " .. table.concat(out, " | ")
end

-- ReloadMatch(): restarts the match on the config's stage (UMapData.Level), which
-- rebuilds the game state from the (spec-edited) UMvsGameplayConfig.
function ReloadMatch()
    local cfg = Config()
    -- UMapData "<dir>/M018_V1_Data.M018_V1_Data" sits next to its level "<dir>/M018_V1"
    -- (GetLevelAssetPath()'s FString return comes back garbled through UE4SS).
    local full = cfg.MapData:GetFullName()
    local level = full:match("%s(%S+)_Data%.") or full:match("%s(%S+)_data%.")
    if not level then return "cannot derive level from " .. full end
    local k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    k:ExecuteConsoleCommand(GameInstance() or FindFirstOf("World"), "open " .. level, nil)
    return "reload " .. level
end

-- Name(obj): an object's short name, or "-" for null. (Calling methods on a null
-- object reference is a native access violation that pcall cannot catch.)
function Name(o)
    if o == nil or not o:IsValid() then return "-" end
    return o:GetFName():ToString()
end

-- Logs the pending match's UMvsGameplayConfig (players, fighters, skins, map, mode).
function DescribeConfig(tag)
    local cfg = Config()
    if not cfg or not cfg:IsValid() then return "no config" end
    local desc = {}
    for i = 1, #cfg.Players do
        local p = cfg.Players[i]
        local ok, d = pcall(function()
            return string.format("[%d team=%d idx=%d bot=%s ctrl=%d char=%s skin=%s]", i - 1, p.TeamIndex,
                p.PlayerIndex, tostring(p.IsBot), p.LocalControllerId,
                Name(p.Character), Name(p.Skin))
        end)
        desc[#desc + 1] = ok and d or ("[" .. (i - 1) .. " " .. tostring(d) .. "]")
    end
    local mapname = "-"
    mapname = Name(cfg.MapData)
    local line = string.format("config %s: players=%d map=%s mode=%s online=%s %s", tag or "", #cfg.Players,
        mapname, cfg.ModeString:ToString(), tostring(cfg.bIsOnlineMatch), table.concat(desc, " "))
    print("[DevExec] " .. line .. "\n")
    return line
end

-- ---------------------------------------------------------------------------
-- Lobby: in host/join mode MvsRevival.dll keeps MvsRevival.roster current
-- (match id, stage, our slot, every player's fighter). While the Local Play
-- screen is open we mirror it there: remote players become panels carrying
-- their fighters (selecting through a panel is what streams a fighter in), our
-- own pick is published, and the match spec stays armed, so Ready starts the
-- networked match. The host's Ready starts everyone (MvsRevival.start); joiners
-- are readied when the roster says go.
local DEFAULT_MAP = "/Game/FixedGameplay/Maps/M011/V1/M011_V1_Data.M011_V1_Data"
local lobby = { panel_pick = {}, armed = nil, readied = nil, started = nil }

local function read_roster()
    local f = io.open("MvsRevival.roster", "r")
    if not f then return nil end
    local r = { slots = {} }
    for line in f:lines() do
        local k, v = line:match("^(%S+)%s+(.*)$")
        if k == "slot" then
            local i, name, c, s = v:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if i then r.slots[#r.slots + 1] = { index = tonumber(i), name = name, char = c ~= "-" and c or nil, skin = s ~= "-" and s or nil } end
        elseif k == "server" then
            r.ip, r.port = v:match("^(%S+)%s+(%d+)")
        elseif k then
            r[k] = v
        end
    end
    f:close()
    r["local"] = tonumber(r["local"])
    return r
end

local function active_page(w)
    local ok, n = pcall(function() return Name(w.PageWidgetSwitcher:GetActiveWidget():GetClass()) end)
    return ok and n or "-"
end

-- Front end only. Widgets cached in one world are freed by travel, and UE4SS's
-- IsValid() cannot tell a freed object from a live one (it reads freed memory), so
-- the UI cache is dropped whenever the world changes.
local function in_front_end()
    if Traveling() then lobby.world = nil; return false end
    local gi = GameInstance()
    if not gi then return false end
    local gs = statics():GetGameState(gi)
    if not gs or not gs:IsValid() then return false end
    if lobby.world ~= gs:GetAddress() then
        lobby.world = gs:GetAddress()
        lobby.world_since = os.clock()
        cache["MvsLocalPlayScreen"] = nil
        lobby.panel_pick = {}
    end
    -- Object scans are only safe once the new world has finished streaming in.
    if os.clock() - (lobby.world_since or 0) < 6 then return false end
    return Name(gs:GetClass()):find("Frontend", 1, true) ~= nil
end

local function lobby_tick()
    local r = read_roster()
    if not r or not r["local"] then return end
    if not in_front_end() then return end
    local s = Cached("MvsLocalPlayScreen")
    if not s or not s:IsVisible() then return end
    local me = s.LocalPlayerWidget_1

    -- Publish our own pick: MvsRevival.dll reads the human player's fighter from
    -- SetupData.Players (a TMap, which Lua can't iterate) into MvsRevival.pick.
    local q = io.open("MvsRevival.query", "w")
    q:write(string.format("pick %X", s.SetupData:GetAddress())); q:close()
    pump()

    -- Remote players -> panels 2..n, in slot order.
    local p = 2
    for _, slot in ipairs(r.slots) do
        if slot.index ~= r["local"] and p <= 4 then
            local w = s["LocalPlayerWidget_" .. p]
            if slot.char and slot.skin then
                local page = active_page(w)
                if page:find("Join", 1, true) then
                    w:HandleAddBotButtonClicked()
                    lobby.panel_pick[p] = nil
                    print(string.format("[DevExec] lobby: panel %d -> %s\n", p, slot.name))
                elseif page:find("Bot", 1, true) and lobby.panel_pick[p] ~= slot.char .. slot.skin then
                    local ca, sa = LoadAsset(slot.char), LoadAsset(slot.skin)
                    if ca and ca:IsValid() and sa and sa:IsValid() then
                        w.CharacterSelect:OnRandomSelectedInternal(ca, sa)
                        lobby.panel_pick[p] = slot.char .. slot.skin
                        print(string.format("[DevExec] lobby: panel %d %s picks %s\n", p, slot.name, Name(ca)))
                    end
                end
            end
            p = p + 1
        end
    end

    -- Keep the spec armed once everyone has a fighter.
    local complete = #r.slots >= 2
    for _, slot in ipairs(r.slots) do complete = complete and slot.char ~= nil and slot.skin ~= nil end
    if complete then
        local spec = { "matchtype 1", "intro 0", "duration " .. (tonumber(r.duration) or 180),
                       "map " .. ((r.map and r.map ~= "-") and r.map or DEFAULT_MAP),
                       "local " .. r["local"] }
        for _, slot in ipairs(r.slots) do
            spec[#spec + 1] = string.format("slot %d %d %s %s", slot.index, slot.index, slot.char, slot.skin)
        end
        local text = table.concat(spec, "\n") .. "\n"
        -- Arm once per match id (re-arm only if the spec itself changes before the
        -- start). The DLL consumes the file in OpenLevel; never re-arm a consumed
        -- match, or the travel to the results screen would be redirected too. The
        -- host opens a new match id after each match.
        local pending = io.open("MvsRevival.matchspec", "r")
        if pending then pending:close() end
        local consumed = lobby.armed_match == r.match and not pending and r.go == "1"
        if not consumed and lobby.armed ~= text .. r.match then
            lobby.armed_match = r.match
            local f = io.open("MvsSpec.txt", "w"); f:write(text); f:close()
            local res = ArmMatchSpec()
            f = io.open("MvsNet.txt", "w")
            f:write(string.format("%s %s %d %d %s revival dev", r.ip, r.port, r["local"], r["local"], r.match)); f:close()
            lobby.armed = text .. r.match
            print("[DevExec] lobby: " .. tostring(res):sub(1, 120) .. "\n")
        end
    end

    -- Start: the host's own Ready starts everyone; joiners follow the roster.
    local ready_page = active_page(me):find("Ready", 1, true) ~= nil
    if r["local"] == 0 and complete and ready_page and lobby.started ~= r.match then
        local f = io.open("MvsRevival.start", "w"); f:write("1"); f:close()
        lobby.started = r.match
        print("[DevExec] lobby: host ready -> starting " .. r.match .. "\n")
    elseif r["local"] ~= 0 and r.go == "1" and complete and not ready_page then
        -- Ready is ignored while the panel's fighter/perk assets are still loading,
        -- so keep asking until the ready page shows.
        local now = os.clock()
        if (lobby.next_ready or 0) <= now then
            lobby.next_ready = now + 2
            if lobby.readied ~= r.match then print("[DevExec] lobby: host started " .. r.match .. " -> ready\n") end
            lobby.readied = r.match
            Press(me.PageWidgetPlayer.ReadyButton)
        end
    end
end

-- Throttled: FindFirstOf builds an FName and scans every object; doing it 10x/s
-- during loading contends with the async loader (FName pool lock) and makes
-- boots crawl. Only poll for the match game state every 500 ms.
local next_auto = 0
LoopAsync(100, function()
    local now = os.clock()
    if now >= next_auto then
        next_auto = now + 0.5
        local armed = io.open("MvsNet.txt", "r")
        if armed then armed:close(); ExecuteInGameThread(auto_connect) end
        -- A Custom Game lobby is open: let MvsRevival.dll sync the shared roster into it
        -- (its pump runs on the game thread from the inventory hook).
        local cg = io.open("MvsRevival.cgactive", "r")
        if cg then cg:close(); ExecuteInGameThread(function() if not Traveling() then pump() end end) end
        local roster = io.open("MvsRevival.roster", "r")
        if roster then
            roster:close()
            ExecuteInGameThread(function()
                local ok, err = pcall(lobby_tick)
                if not ok then print("[DevExec] lobby error: " .. tostring(err) .. "\n") end
            end)
        end
    end
    local pending = io.open(CALL, "r")
    if pending then pending:close(); ExecuteInGameThread(pump) end
    local f = io.open(CMD, "r")
    if not f then return false end
    local src = f:read("a"); f:close()
    os.remove(DONE); os.rename(CMD, DONE)
    ExecuteInGameThread(function()
        local chunk, err = load(src, "=MvsCmd")
        if not chunk then print("[DevExec] compile error: " .. tostring(err) .. "\n"); return end
        local ok, res = pcall(chunk)
        print("[DevExec] " .. (ok and "ok" or "error") .. ": " .. tostring(res) .. "\n")
    end)
    return false
end)
print("[DevExec] watching " .. CMD .. "\n")
