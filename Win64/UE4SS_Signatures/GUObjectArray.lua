-- MultiVersus GUObjectArray override.
-- The game's FUObjectArray uses a custom, XOR-obfuscated layout that stock
-- UE4SS can't read. MvsRevival.dll keeps a stock-layout mirror ("shadow")
-- and publishes its address in MVS_SHADOW_GUOBJECTARRAY. We load the DLL
-- here so the mirror exists before UE4SS starts reading objects.

local FALLBACK_SHADOW = 0x0000010000000000

function Register()
    -- `movabs r11, 0x01B5DEAFD6B4068C` (object-table XOR key) — proves this is
    -- the build MvsRevival.dll was written for.
    return "49 BB 8C 06 B4 D6 AF DE B5 01"
end

function OnMatchFound(MatchAddress)
    if os.getenv("MVS_SHADOW_GUOBJECTARRAY") == nil then
        local ok, err = package.loadlib("MvsRevival.dll", "*")
        if not ok then print("[MvsRevival] loadlib failed: " .. tostring(err) .. "\n") end
    end

    -- Layout-probe runs: hold UE4SS's init thread (not the game) until the
    -- probe has measured the reflection layouts, so UE4SS can't crash first.
    local probe = io.open("MvsRevival.probe", "r")
    if probe then
        probe:close()
        print("[MvsRevival] waiting for layout probe...\n")
        local deadline = os.time() + 240
        while os.getenv("MVS_PROBE_DONE") == nil and os.time() < deadline do end
        print("[MvsRevival] layout probe finished\n")
    end

    local addr = tonumber(os.getenv("MVS_SHADOW_GUOBJECTARRAY") or "") or FALLBACK_SHADOW
    print(string.format("[MvsRevival] GUObjectArray -> shadow 0x%X\n", addr))
    return addr
end
