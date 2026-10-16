# MultiVersus Revival

MultiVersus went offline, but the game is still on our drives. **MultiVersus Revival** brings it back to life: every fighter and cosmetic unlocked, and real online matches with your friends again, hosted by players over Steam, with no official servers and no port forwarding.

This is a community preservation project. It uses the game you already have installed; nothing from the game is redistributed here.

## What you get

- **Everything unlocked:** all fighters, variants, banners, profile icons, ring-out effects and perk sets.
- **Online play over Steam:** one player hosts from their own game. Friends join with a 5-letter code or a Steam invite. Steam handles the connection, so no router setup is needed.
- **The original screens, working again:**
  - **Custom Game lobbies:** teams, time, ring-outs, hazards, map selection, handicap and bots.
  - **Fighter and skin select**, and the **faceoff screen** with perk selection.
  - **Results screen**, then **Return to Lobby** for the next match.
- **Quick match:** the Unranked 1v1 and 2v2 tiles find another player who pressed the same tile.

## Install (2 minutes)

You need **MultiVersus installed through Steam on Windows**. Every player installs the mod.

1. **Download this project:** click the green **Code** button above, then **Download ZIP**.
2. **Unzip it** anywhere, for example your Desktop.
3. Open the unzipped folder, **right-click `install.ps1`** and choose **Run with PowerShell**.
   - The installer finds MultiVersus in your Steam library and copies the mod into the game folder.
   - If Windows asks whether to run the script, choose **Open** or **Run**.
   - If it can't find the game, see **Manual install** below.
4. **Start MultiVersus from Steam** as usual.

That's it. On the home screen, **PLAY** opens the multiplayer menu.

### Manual install

If the installer can't find the game:

1. In Steam, right-click **MultiVersus**, then choose **Manage** and **Browse local files**.
2. Open `MultiVersus\Binaries\Win64`. It contains `MultiVersus-Win64-Shipping.exe`.
3. Copy **everything inside this project's `Win64` folder** into it. Allow it to replace files if asked.

### Uninstall

In Steam, right-click **MultiVersus**, then choose **Properties**, **Installed Files** and **Verify integrity of game files**.

## Play with friends

**Custom Game (with friends)**
1. **Host:** Home, then **PLAY**, then **Custom Game**. Your lobby code is shown below the player list.
2. **Friends:** Home, then **PLAY**, then **Custom Game**. Type the host's code in the code box and press **JOIN**. Accepting the host's Steam invite also works.
3. **Everyone:** click the ✏️ on your own slot, then **Edit Fighter**, and pick your fighter and variant. Press **READY**.
4. **Host:** choose settings and maps, add bots with **+ BOT** if you like, then press **START MATCH**.
5. **Faceoff:** pick perks with **EDIT PERKS**, or just press **READY**.
6. After the match, **RETURN TO LOBBY** brings everyone back for the next one.

**Quick match:** Home, then **PLAY**, then **Unranked 1v1** or **Unranked 2v2**. The match starts when the lobby is full.

## Screenshots

Gameplay screenshots are on the way. They are being captured from the current test build.

## Troubleshooting

- **Nothing changed in the game:** make sure the files went into `MultiVersus\Binaries\Win64`, next to `MultiVersus-Win64-Shipping.exe`.
- **Friends can't join:** everyone needs the mod installed and Steam running. Double-check the code; it's 5 letters.
- **Something broke:** send these two files from your game's `Binaries\Win64` folder:
  - `MvsRevival.log`
  - `UE4SS.log`
- **The game crashed:** also send the newest folder in `%LOCALAPPDATA%\MultiVersus\Saved\Crashes` (paste that path into File Explorer's address bar), zipped.
- **Updating:** download the ZIP again and re-run `install.ps1`. It replaces the old files.
- **Skip the faceoff:** create an empty file named `MvsRevival.nofaceoff` next to the game's exe to go straight to the stage.

## For modders and contributors

- The game's pak **AES key** is in [`AES-KEY.txt`](AES-KEY.txt). Use it with FModel or CUE4Parse; the engine is UE 5.1.
- **How it works:**
  - [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) loads two Lua mods and `MvsRevival.dll`.
  - The DLL emulates the old online backend locally and runs the match relay.
  - It uses Steam lobbies and Steam Datagram Relay for connections.

## Credits and licenses

- **UE4SS:** © Narknon and contributors, MIT license, see [`licenses/UE4SS-LICENSE.txt`](licenses/UE4SS-LICENSE.txt).
- **OpenVersus:** the netcode start handshake and several protocol details were cross-checked against [OpenVersus](https://github.com/openversus)' rollback server (MIT license). Thanks to that team.
- **MultiVersus** is © Warner Bros. Games / Player First Games. This is an unofficial fan project, not affiliated with or endorsed by them. You need your own copy of the game.
