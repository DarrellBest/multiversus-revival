# MultiVersus Revival installer.
# Double-click Install.bat (or right-click this file -> "Run with PowerShell"). It finds MultiVersus in
# any Steam library on any drive, under any folder name, and copies the mod into the game.
# Also works without downloading anything first, from a PowerShell window:
#   irm https://raw.githubusercontent.com/DarrellBest/multiversus-revival/main/install.ps1 | iex
# Options: -GameDir "<folder containing MultiVersus.exe>"   -DryRun (only report what it would do)
#          -NoLaunch (do not offer to start the game)
param([string]$GameDir = "", [switch]$DryRun, [switch]$NoLaunch)

$ErrorActionPreference = "Stop"
$AppId = "1818750"                               # MultiVersus on Steam
$ExeRel = "MultiVersus\Binaries\Win64\MultiVersus-Win64-Shipping.exe"
$RepoZip = "https://github.com/DarrellBest/multiversus-revival/archive/refs/heads/main.zip"
# (Environment overrides, for the one-line form and testing: MVS_INSTALL_DRYRUN=1, MVS_INSTALL_NOLAUNCH=1,
#  MVS_INSTALL_GAMEDIR=<folder>, MVS_INSTALL_LIBS=<steamapps;steamapps> instead of Steam's own list.)
if ($env:MVS_INSTALL_DRYRUN -eq "1") { $DryRun = $true }
if ($env:MVS_INSTALL_NOLAUNCH -eq "1") { $NoLaunch = $true }
if (-not $GameDir -and $env:MVS_INSTALL_GAMEDIR) { $GameDir = $env:MVS_INSTALL_GAMEDIR }

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
# Never "exit": in the one-line form (irm | iex) that would close the user's PowerShell window.
function Pause-OnError {
    if (-not $DryRun -and -not $NoLaunch -and $Host.Name -eq "ConsoleHost") { Read-Host "`nPress Enter to close" | Out-Null }
}
function Test-Game($dir) { return $dir -and (Test-Path -LiteralPath (Join-Path $dir $ExeRel)) }

# ---- every Steam library folder ("...\steamapps") we can learn about
function Get-SteamLibraries {
    if ($env:MVS_INSTALL_LIBS) { return $env:MVS_INSTALL_LIBS -split ';' | Where-Object { $_ -and (Test-Path -LiteralPath $_) } }
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in "HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam") {
        $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        foreach ($v in $p.SteamPath, $p.InstallPath) { if ($v) { $roots.Add(($v -replace '/', '\')) } }
    }
    $proc = Get-Process steam -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) { $roots.Add((Split-Path $proc.Path)) }
    $libs = New-Object System.Collections.Generic.List[string]
    foreach ($root in ($roots | Select-Object -Unique)) {
        $libs.Add((Join-Path $root "steamapps"))
        foreach ($vdf in (Join-Path $root "steamapps\libraryfolders.vdf"), (Join-Path $root "config\libraryfolders.vdf")) {
            if (-not (Test-Path -LiteralPath $vdf)) { continue }
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libs.Add((Join-Path ($m.Groups[1].Value -replace '\\\\', '\') "steamapps"))
            }
        }
    }
    return $libs | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique
}

# ---- the game folder in a library: from Steam's app manifest, else any folder holding the exe
function Find-InLibrary($lib) {
    $acf = Join-Path $lib "appmanifest_$AppId.acf"
    if (Test-Path -LiteralPath $acf) {
        $m = [regex]::Match((Get-Content -LiteralPath $acf -Raw), '"installdir"\s+"([^"]+)"')
        if ($m.Success) {
            $dir = Join-Path $lib ("common\" + $m.Groups[1].Value)
            if (Test-Game $dir) { return $dir }
        }
    }
    $common = Join-Path $lib "common"
    if (Test-Path -LiteralPath $common) {
        foreach ($d in Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue) {
            if (Test-Game $d.FullName) { return $d.FullName }
        }
    }
    return $null
}

function Find-MultiVersus {
    foreach ($lib in Get-SteamLibraries) { $dir = Find-InLibrary $lib; if ($dir) { return $dir } }
    if ($env:MVS_INSTALL_LIBS) { return $null }
    # Steam's records did not lead to it: look for steamapps folders near the top of every drive.
    Say "Searching your drives for MultiVersus..."
    foreach ($drive in Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 }) {
        $found = Get-ChildItem -LiteralPath $drive.Root -Directory -Filter "steamapps" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                 Select-Object -First 5
        foreach ($lib in $found) { $dir = Find-InLibrary $lib.FullName; if ($dir) { return $dir } }
    }
    return $null
}

function Pick-Folder {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "MultiVersus was not found automatically. Select the MultiVersus game folder (Steam: right-click MultiVersus > Manage > Browse local files)."
        if ($dlg.ShowDialog() -eq "OK") { return $dlg.SelectedPath }
    } catch { }
    return $null
}

function Install-Revival {
Say "MultiVersus Revival installer" "Cyan"

# ---- where is the game
if ($GameDir -and -not (Test-Game $GameDir)) { Say "No MultiVersus found in $GameDir" "Yellow"; $GameDir = "" }
if (-not $GameDir) { $GameDir = Find-MultiVersus }
if (-not $GameDir -and -not $DryRun) {
    $picked = Pick-Folder
    if ($picked) {
        # accept the game folder itself or anything inside it
        $probe = $picked
        while ($probe -and -not (Test-Game $probe)) { $probe = Split-Path $probe -Parent }
        $GameDir = $probe
    }
}
if (-not $GameDir) {
    Say "Could not find MultiVersus. Is it installed through Steam?" "Red"
    Say "You can also run:  install.ps1 -GameDir ""<the MultiVersus folder>"""
    Pause-OnError; return
}
$target = Join-Path $GameDir "MultiVersus\Binaries\Win64"
Say "Found MultiVersus: $GameDir" "Green"

# ---- the mod files: next to this script, else downloaded
$source = $null
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot "Win64\MvsRevival.dll"))) {
    $source = Join-Path $PSScriptRoot "Win64"
} elseif ($DryRun) {
    $source = "(download from $RepoZip)"
} else {
    Say "Downloading the latest MultiVersus Revival..."
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("mvs-revival-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp "mod.zip"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $RepoZip -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp
    $source = Get-ChildItem -LiteralPath $tmp -Directory | ForEach-Object { Join-Path $_.FullName "Win64" } |
              Where-Object { Test-Path -LiteralPath (Join-Path $_ "MvsRevival.dll") } | Select-Object -First 1
    if (-not $source) { Say "The download did not contain the mod files." "Red"; Pause-OnError; return }
}

if ($DryRun) {
    Say "Dry run: would copy $source -> $target" "Yellow"
    return
}

# ---- the game must be closed (its files are in use while it runs)
while (Get-Process MultiVersus-Win64-Shipping -ErrorAction SilentlyContinue |
       Where-Object { $_.Path -and $_.Path.StartsWith($target, [StringComparison]::OrdinalIgnoreCase) }) {
    Say "MultiVersus is running. Close the game, then press Enter to continue." "Yellow"
    Read-Host | Out-Null
}

Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force
Say ""
Say "Installed into $target" "Green"
Say "On the home screen, PLAY opens the multiplayer menu."
if (-not $NoLaunch -and $Host.Name -eq "ConsoleHost") {
    $answer = Read-Host "Start MultiVersus now? (Y/n)"
    if ($answer -notmatch '^[nN]') { Start-Process "steam://rungameid/$AppId" }
}
}

try { Install-Revival }
catch { Say "Install failed: $($_.Exception.Message)" "Red"; Pause-OnError }
