-- UnlockEverything — MultiVersus revival.
-- The unlock lives in MvsRevival.dll: a native hook on the Hydra client's
-- item-count lookup that answers 1 for the developer item "debug_all_unlocked",
-- which every ownership check honours. The hook stays inactive during boot
-- (enabling it early stalls startup); this script arms it once the offline
-- main menu is shown, then asks the UI to refresh.
--
-- No polling with FindFirstOf: scanning the object array while assets stream in
-- races the async loader (objects registered before their class is set) and
-- crashes UE4SS. The main menu's display event runs on the game thread instead.

local TRIGGER, READY = "MvsRevival.unlock-now", "MvsRevival.menu-ready"
os.remove(READY)
local armed = false

local function on_menu_shown(ctx)
    if armed then return end
    armed = true
    local f = io.open(TRIGGER, "w")
    if f then f:write("1"); f:close() end
    f = io.open(READY, "w")
    if f then f:write("1"); f:close() end
    print("[UnlockEverything] main menu shown; unlock armed\n")
    -- Refresh ownership-dependent widgets a moment later, through the game
    -- instance (a property chain, not an object scan).
    local menu = ctx:get()
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                local inv = FindFirstOf("InventoryManager")  -- menu is idle by now
                print(string.format("[UnlockEverything] IsDebugAllUnlocked = %s\n", tostring(inv:IsDebugAllUnlocked())))
                inv:InventoryUpdated()
            end)
            if not ok then print("[UnlockEverything] refresh skipped: " .. tostring(err) .. "\n") end
        end)
    end)
end

-- The front end's game state initialises (native hook, game thread) shortly before
-- the menu appears; from then on look for the menu once a second (a single scan per
-- tick while the front end idles, stopping as soon as it is found).
local polling = false
local function poll_for_menu()
    if armed then return end
    ExecuteInGameThread(function()
        if armed then return end
        local menu = FindFirstOf("MvsOfflineMainMenu")
        if menu and menu:IsValid() then
            on_menu_shown({ get = function() return menu end })
        else
            ExecuteWithDelay(1000, poll_for_menu)
        end
    end)
end
local ok, err = pcall(RegisterInitGameStatePostHook, function(ctx)
    if armed or polling then return end
    polling = true
    print("[UnlockEverything] first game state initialised; waiting for the main menu\n")
    ExecuteWithDelay(4000, poll_for_menu)
end)
print("[UnlockEverything] InitGameState hook: " .. (ok and "ok" or tostring(err)) .. "\n")
