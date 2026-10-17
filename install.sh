#!/usr/bin/env bash
# MultiVersus Revival installer for Linux (Bazzite, SteamOS / Steam Deck and other distros using Proton).
# Run it from a terminal:  bash install.sh   (or double-click it in your file manager and choose Run)
# It finds MultiVersus in any Steam library, copies the mod into the game and sets up the game's Proton
# prefix (the dwmapi DLL override that makes Proton load the mod, and a new enough VC++ runtime).
# Also works without downloading anything first:
#   curl -fsSL https://raw.githubusercontent.com/DarrellBest/multiversus-revival/main/install.sh | bash
# Options: --game-dir "<folder containing MultiVersus.exe>"   --dry-run (only report what it would do)
#          --no-launch (do not offer to start the game)   --local (install the files next to this script
#          instead of downloading the latest)   --skip-prefix (only copy the files)
# (Environment overrides, for the one-line form and testing: MVS_INSTALL_DRYRUN=1, MVS_INSTALL_NOLAUNCH=1,
#  MVS_INSTALL_GAMEDIR=<folder>, MVS_INSTALL_LIBS=<steamapps:steamapps> instead of Steam's own list.)

set -u

APP_ID=1818750                                   # MultiVersus on Steam
EXE_REL="MultiVersus/Binaries/Win64/MultiVersus-Win64-Shipping.exe"
GAME_EXE="MultiVersus-Win64-Shipping.exe"
REPO_ZIP="https://github.com/DarrellBest/multiversus-revival/archive/refs/heads/main.zip"
PROTONTRICKS_FLATPAK="com.github.Matoking.protontricks"
MIN_VCRT="14.40"                                 # MvsRevival.dll is linked against 14.44 (needs _Mtx_lock)

GAME_DIR="${MVS_INSTALL_GAMEDIR:-}"
DRY_RUN=0; NO_LAUNCH=0; LOCAL=0; SKIP_PREFIX=0
[ "${MVS_INSTALL_DRYRUN:-}" = 1 ] && DRY_RUN=1
[ "${MVS_INSTALL_NOLAUNCH:-}" = 1 ] && NO_LAUNCH=1
while [ $# -gt 0 ]; do
    case "$1" in
        --game-dir) GAME_DIR="${2:-}"; shift ;;
        --game-dir=*) GAME_DIR="${1#*=}" ;;
        --dry-run) DRY_RUN=1 ;;
        --no-launch) NO_LAUNCH=1 ;;
        --local) LOCAL=1 ;;
        --skip-prefix) SKIP_PREFIX=1 ;;
        -h|--help) sed -n '2,13p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# The script's own folder, when run from a file (empty for curl | bash)
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Double-clicked in a file manager: there is no terminal to show anything in, so reopen in one.
# (Only when a file manager started us: anything else without a terminal is a script and gets no window.)
launched_from_file_manager() {
    case "$(ps -o comm= -p "$PPID" 2>/dev/null)" in
        dolphin|nautilus|nemo|thunar|pcmanfm*|caja|kioclient*|kioworker*|kio_exec|kdeinit*) return 0 ;;
    esac
    return 1
}
if [ ! -t 1 ] && [ -n "$SCRIPT_DIR" ] && [ -z "${MVS_INSTALL_IN_TERMINAL:-}" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] &&
   launched_from_file_manager; then
    export MVS_INSTALL_IN_TERMINAL=1
    self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
    for term in konsole gnome-terminal kgx ptyxis xfce4-terminal alacritty kitty xterm; do
        command -v "$term" >/dev/null 2>&1 || continue
        case "$term" in
            gnome-terminal|kgx|ptyxis) exec "$term" -- bash "$self" "$@" ;;
            *) exec "$term" -e bash "$self" "$@" ;;
        esac
    done
fi

if [ -t 1 ]; then
    C_CYAN=$'\e[36m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_OFF=$'\e[0m'
else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
ok()   { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF"; }
err()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF"; }

# Questions read from the terminal itself: with curl | bash, stdin is the script.
HAVE_TTY=0
if [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi
ask() {   # ask "question" -> answer in $REPLY ("" when there is no terminal)
    REPLY=""
    [ "$HAVE_TTY" = 1 ] && read -r -p "$1 " REPLY </dev/tty
}
# Keep the window open when we opened it ourselves, so the result can be read.
finish() {
    local code=$1
    if [ -n "${MVS_INSTALL_IN_TERMINAL:-}" ] && [ "$HAVE_TTY" = 1 ]; then
        read -r -p $'\nPress Enter to close ' </dev/tty
    fi
    exit "$code"
}

is_game() { [ -n "$1" ] && [ -f "$1/$EXE_REL" ]; }
# Under Proton the process name is the exe name cut to 15 characters, and argv[0] a Windows path.
# (Not a plain "pgrep -f": that also matches any shell or editor with the exe's name on its command line.)
game_running() {
    pgrep -x "${GAME_EXE:0:15}" >/dev/null 2>&1 || pgrep -f "^[A-Za-z]:\\\\.*\\\\$GAME_EXE" >/dev/null 2>&1
}

# ---- every Steam library folder (".../steamapps") we can learn about
steam_libraries() {
    if [ -n "${MVS_INSTALL_LIBS:-}" ]; then
        tr ':' '\n' <<<"$MVS_INSTALL_LIBS" | while read -r l; do [ -n "$l" ] && [ -d "$l" ] && echo "$l"; done
        return
    fi
    local root vdf
    {
        for root in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" \
                    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
                    "$HOME/.var/app/com.valvesoftware.Steam/data/Steam" \
                    "$HOME/snap/steam/common/.local/share/Steam"; do
            [ -d "$root" ] || continue
            echo "$root/steamapps"
            for vdf in "$root/steamapps/libraryfolders.vdf" "$root/config/libraryfolders.vdf"; do
                [ -f "$vdf" ] || continue
                sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$vdf" | sed 's/$/\/steamapps/'
            done
        done
    } | while read -r l; do
        [ -d "$l" ] && readlink -f "$l"
    done | awk '!seen[$0]++'
}

# ---- the game folder in a library: from Steam's app manifest, else any folder holding the exe
find_in_library() {
    local lib=$1 acf="$1/appmanifest_$APP_ID.acf" name d
    if [ -f "$acf" ]; then
        name=$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$acf" | head -n1)
        if [ -n "$name" ] && is_game "$lib/common/$name"; then echo "$lib/common/$name"; return 0; fi
    fi
    for d in "$lib"/common/*/; do
        d=${d%/}
        if is_game "$d"; then echo "$d"; return 0; fi
    done
    return 1
}

find_multiversus() {
    local lib dir
    while read -r lib; do
        dir=$(find_in_library "$lib") && { echo "$dir"; return 0; }
    done < <(steam_libraries)
    [ -n "${MVS_INSTALL_LIBS:-}" ] && return 1
    # Steam's records did not lead to it: look for steamapps folders on the usual mount points.
    warn "Searching your drives for MultiVersus..." >&2
    while read -r lib; do
        dir=$(find_in_library "$lib") && { echo "$dir"; return 0; }
    done < <(find "$HOME" /mnt /media /run/media /var/mnt -maxdepth 5 -type d -name steamapps 2>/dev/null)
    return 1
}

# ---- the game's Proton prefix: compatdata lives in the same library as the game
prefix_dir() { echo "$(dirname "$(dirname "$GAME_DIR")")/compatdata/$APP_ID/pfx"; }

# FILEVERSION of a Windows DLL as "major.minor" (empty when unreadable)
dll_version() {
    command -v python3 >/dev/null 2>&1 || return 0
    python3 -I - "$1" <<'EOF' 2>/dev/null
import struct, sys
d = open(sys.argv[1], 'rb').read()
i = d.find(struct.pack('<I', 0xFEEF04BD))     # VS_FIXEDFILEINFO signature
if i >= 0:
    ms, = struct.unpack_from('<I', d, i + 8)
    print(f"{ms >> 16}.{ms & 0xffff:02d}")
EOF
}
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# protontricks, native or the Flatpak (Bazzite ships the Flatpak)
PT=()
find_protontricks() {
    if command -v protontricks >/dev/null 2>&1; then PT=(protontricks); return 0; fi
    if command -v flatpak >/dev/null 2>&1 && flatpak info "$PROTONTRICKS_FLATPAK" >/dev/null 2>&1; then
        PT=(flatpak run "$PROTONTRICKS_FLATPAK"); return 0
    fi
    if command -v flatpak >/dev/null 2>&1; then
        ask "Protontricks is needed to set up the game's Proton prefix. Install it from Flathub now? (Y/n)"
        if [[ ! "$REPLY" =~ ^[nN] ]]; then
            flatpak install --user -y flathub "$PROTONTRICKS_FLATPAK" && { PT=(flatpak run "$PROTONTRICKS_FLATPAK"); return 0; }
        fi
    fi
    return 1
}

# The Flatpak only sees ~/.local/share/Steam unless allowed into the game's library.
allow_flatpak_library() {
    [ "${PT[0]}" = flatpak ] || return 0
    local lib; lib=$(dirname "$(dirname "$GAME_DIR")")
    case "$lib" in "$HOME/.local/share/Steam"/*|"$HOME/.local/share/Steam") return 0 ;; esac
    flatpak override --user --filesystem="$lib" "$PROTONTRICKS_FLATPAK" >/dev/null 2>&1 || true
}

# ---- Proton loads its own dwmapi.dll unless told otherwise; UE4SS comes in through ours.
# Set in the prefix's registry for the game's exe only, so it needs no Steam launch option.
has_dll_override() {   # is dwmapi=native,builtin in the game's AppDefaults key of user.reg
    MVS_KEY="[Software\\\\Wine\\\\AppDefaults\\\\$GAME_EXE\\\\DllOverrides]" awk '
        index(tolower($0), tolower(ENVIRON["MVS_KEY"])) == 1 { s = 1; next }
        /^\[/ { s = 0 }
        s && tolower($0) ~ /^"dwmapi"="native,builtin"/ { f = 1 }
        END { exit !f }' "$1/user.reg" 2>/dev/null
}
setup_dll_override() {
    local pfx=$1 i
    if has_dll_override "$pfx"; then
        ok "DLL override for the mod: already set"
        return 0
    fi
    say "Setting the dwmapi DLL override in the game's prefix..."
    "${PT[@]}" -c "\"\$WINE\" reg add 'HKCU\\Software\\Wine\\AppDefaults\\$GAME_EXE\\DllOverrides' /v dwmapi /d native,builtin /f; \"\$WINESERVER\" -w" "$APP_ID" >/dev/null 2>&1
    for ((i = 0; i < 10; i++)); do has_dll_override "$pfx" && break; sleep 1; done   # written when wineserver exits
    if has_dll_override "$pfx"; then
        ok "DLL override for the mod: set"
    else
        warn "Could not set the DLL override. In Steam, set MultiVersus' Launch Options to:"
        say  '    WINEDLLOVERRIDES="dwmapi=n,b" %command%'
    fi
}

# ---- the stock prefix has VC++ 14.31; MvsRevival.dll crashes in msvcp140 with anything older than 14.40
setup_vcrt() {
    local pfx=$1 ver
    ver=$(dll_version "$pfx/drive_c/windows/system32/msvcp140.dll")
    if [ -n "$ver" ] && version_ge "$ver" "$MIN_VCRT"; then
        ok "Visual C++ runtime in the prefix: $ver"
        return 0
    fi
    say "Installing the Visual C++ 2022 runtime into the game's prefix (${ver:-unknown} is too old)."
    say "This takes a minute or two; Wine's \"fixme\" lines are normal."
    "${PT[@]}" "$APP_ID" -q vcrun2022
    ver=$(dll_version "$pfx/drive_c/windows/system32/msvcp140.dll")
    if [ -n "$ver" ] && version_ge "$ver" "$MIN_VCRT"; then
        ok "Visual C++ runtime in the prefix: $ver"
    else
        warn "The Visual C++ runtime may not have installed (found ${ver:-nothing}). If the game crashes on start, run:"
        say  "    ${PT[*]} $APP_ID -q vcrun2022"
    fi
}

wait_for_game_exit() {   # polled, never a keypress loop
    local i
    for ((i = 0; i < 300; i++)); do game_running || return 0; sleep 2; done
    ! game_running
}

launch_game() {
    if command -v steam >/dev/null 2>&1; then
        nohup steam "steam://rungameid/$APP_ID" >/dev/null 2>&1 &
    else
        xdg-open "steam://rungameid/$APP_ID" >/dev/null 2>&1 &
    fi
}

install_revival() {
    info "MultiVersus Revival installer"

    # ---- where is the game
    if [ -n "$GAME_DIR" ] && ! is_game "$GAME_DIR"; then
        # accept anything inside the game folder too
        local probe; probe=$(readlink -f "$GAME_DIR" 2>/dev/null || echo "$GAME_DIR")
        while [ "$probe" != / ] && [ -n "$probe" ] && ! is_game "$probe"; do probe=$(dirname "$probe"); done
        if is_game "$probe"; then GAME_DIR=$probe; else warn "No MultiVersus found in $GAME_DIR"; GAME_DIR=""; fi
    fi
    [ -z "$GAME_DIR" ] && GAME_DIR=$(find_multiversus)
    if [ -z "$GAME_DIR" ]; then
        err "Could not find MultiVersus. Is it installed through Steam?"
        say "In Steam: right-click MultiVersus > Manage > Browse local files, then run:"
        say "    bash install.sh --game-dir \"<that folder>\""
        return 1
    fi
    local target="$GAME_DIR/MultiVersus/Binaries/Win64"
    ok "Found MultiVersus: $GAME_DIR"

    # ---- the mod files: always the latest from GitHub (an old unzipped copy next to this script would
    # otherwise put an old version back); the local copy only with --local or when the download fails.
    local local_source="" source="" tmp
    [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/Win64/MvsRevival.dll" ] && local_source="$SCRIPT_DIR/Win64"
    if [ "$LOCAL" = 1 ] && [ -n "$local_source" ]; then
        source=$local_source
    elif [ "$DRY_RUN" = 1 ]; then
        source="(download from $REPO_ZIP)"
    else
        say "Downloading the latest MultiVersus Revival..."
        tmp=$(mktemp -d "${TMPDIR:-/tmp}/mvs-revival-XXXXXX")
        TMP_DL=$tmp; trap 'rm -rf "$TMP_DL"' EXIT
        local url="$REPO_ZIP?nocache=$(date +%s%N)"          # never a cached copy
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL -H "Cache-Control: no-cache" -H "Pragma: no-cache" -o "$tmp/mod.zip" "$url"
        else
            wget -q --no-cache -O "$tmp/mod.zip" "$url"
        fi && {
            if command -v unzip >/dev/null 2>&1; then
                unzip -q "$tmp/mod.zip" -d "$tmp/x"
            elif command -v bsdtar >/dev/null 2>&1; then
                mkdir -p "$tmp/x" && bsdtar -xf "$tmp/mod.zip" -C "$tmp/x"
            else
                python3 -I -m zipfile -e "$tmp/mod.zip" "$tmp/x"
            fi
        } && for d in "$tmp"/x/*/Win64; do
            [ -f "$d/MvsRevival.dll" ] && { source=$d; break; }
        done
        [ -z "$source" ] && warn "Download failed."
        if [ -z "$source" ] && [ -n "$local_source" ]; then
            warn "Using the files next to this installer instead (they may be older)."
            source=$local_source
        fi
        if [ -z "$source" ]; then err "Could not get the mod files."; return 1; fi
    fi

    local pfx; pfx=$(prefix_dir)
    if [ "$DRY_RUN" = 1 ]; then
        warn "Dry run: would copy $source -> $target"
        if [ "$SKIP_PREFIX" = 0 ]; then
            if [ -d "$pfx" ]; then
                warn "Dry run: would check the prefix at $pfx"
                say  "  Visual C++ runtime: $(dll_version "$pfx/drive_c/windows/system32/msvcp140.dll") (needs $MIN_VCRT+)"
                if has_dll_override "$pfx"; then say "  dwmapi override: set"; else say "  dwmapi override: not set"; fi
            else
                warn "Dry run: no Proton prefix yet at $pfx (MultiVersus has never been started)"
            fi
        fi
        return 0
    fi

    # ---- the game must be closed (its files are in use while it runs)
    if game_running; then
        warn "MultiVersus is running. Close the game; the install continues by itself."
        if ! wait_for_game_exit; then
            err "MultiVersus is still running; nothing was installed. Close it and run the installer again."
            return 1
        fi
        sleep 3   # let Proton shut down
    fi

    # ---- copy every file, replacing what is there, and check each one arrived intact
    local failed=() count=0 rel want try
    while IFS= read -r -d '' rel; do
        rel=${rel#./}
        count=$((count + 1))
        mkdir -p "$target/$(dirname "$rel")"
        want=$(sha256sum "$source/$rel" | cut -d' ' -f1)
        for try in 1 2 3 4 5; do
            cp -f "$source/$rel" "$target/$rel" 2>/dev/null &&
                [ "$(sha256sum "$target/$rel" | cut -d' ' -f1)" = "$want" ] && continue 2
            sleep 0.7
        done
        failed+=("$rel")
    done < <(cd "$source" && find . -type f -print0)
    say ""
    if [ ${#failed[@]} -gt 0 ]; then
        err "These files could not be replaced:"
        printf '%s  %s%s\n' "$C_RED" "${failed[@]}" "$C_OFF"
        warn "Close MultiVersus, check you can write to $target, then run the installer again."
        return 1
    fi
    local dll="$target/MvsRevival.dll"
    ok "Installed $count files into $target"
    ok "MvsRevival.dll version $(sha256sum "$dll" | cut -c1-8) (built $(date -r "$dll" '+%Y-%m-%d %H:%M'))"

    # ---- the Proton prefix
    if [ "$SKIP_PREFIX" = 0 ]; then
        say ""
        if [ ! -d "$pfx" ]; then
            warn "MultiVersus has no Proton prefix yet; it is created the first time the game starts."
            ask "Start MultiVersus once now to create it? Close the game when it reaches the title screen. (Y/n)"
            if [ "$HAVE_TTY" = 1 ] && [[ ! "$REPLY" =~ ^[nN] ]]; then
                launch_game
                say "Waiting for the game to start..."
                local i
                for ((i = 0; i < 90; i++)); do game_running && break; sleep 2; done
                say "Close MultiVersus; the install continues by itself."
                wait_for_game_exit && sleep 3
            fi
        fi
        if [ ! -f "$pfx/user.reg" ]; then
            warn "Still no prefix at $pfx."
            warn "Start MultiVersus once from Steam, close it, then run this installer again to finish."
            return 1
        fi
        if ! find_protontricks; then
            err "Protontricks was not found, so the game's prefix could not be set up."
            say "Install it (flatpak install flathub $PROTONTRICKS_FLATPAK) and run this installer again."
            return 1
        fi
        allow_flatpak_library
        setup_dll_override "$pfx"
        setup_vcrt "$pfx"
    fi

    say ""
    say "On the home screen, PLAY opens the multiplayer menu."
    say "To check it worked: after a launch, UE4SS.log and MvsRevival.log appear in $target"
    if [ "$NO_LAUNCH" = 0 ] && [ "$HAVE_TTY" = 1 ]; then
        ask "Start MultiVersus now? (Y/n)"
        [[ "$REPLY" =~ ^[nN] ]] || launch_game
    fi
}

install_revival
finish $?
