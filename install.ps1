# MultiVersus Revival installer.
# Double-click Install.bat (or right-click this file -> "Run with PowerShell"). It finds MultiVersus in
# any Steam library on any drive, under any folder name, and copies the mod into the game.
# Also works without downloading anything first, from a PowerShell window:
#   irm https://raw.githubusercontent.com/DarrellBest/multiversus-revival/main/install.ps1 | iex
# Options: -GameDir "<folder containing MultiVersus.exe>"   -DryRun (only report what it would do)
#          -NoLaunch (do not offer to start the game)   -Local (install the files next to this script
#          instead of downloading the latest)
param([string]$GameDir = "", [switch]$DryRun, [switch]$NoLaunch, [switch]$Local)

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

# ---- the mod files: always the latest from GitHub (an old unzipped copy next to this script would
# otherwise put an old version back); the local copy only with -Local or when the download fails.
$localSource = $null
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot "Win64\MvsRevival.dll"))) { $localSource = Join-Path $PSScriptRoot "Win64" }
$source = $null
if ($Local -and $localSource) {
    $source = $localSource
} elseif ($DryRun) {
    $source = "(download from $RepoZip)"
} else {
    Say "Downloading the latest MultiVersus Revival..."
    try {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("mvs-revival-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $zip = Join-Path $tmp "mod.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $url = "$RepoZip" + "?nocache=" + [DateTime]::UtcNow.Ticks          # never a cached copy
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -Headers @{ "Cache-Control" = "no-cache"; "Pragma" = "no-cache" }
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp
        $source = Get-ChildItem -LiteralPath $tmp -Directory | ForEach-Object { Join-Path $_.FullName "Win64" } |
                  Where-Object { Test-Path -LiteralPath (Join-Path $_ "MvsRevival.dll") } | Select-Object -First 1
    } catch {
        Say "Download failed: $($_.Exception.Message)" "Yellow"
    }
    if (-not $source -and $localSource) {
        Say "Using the files next to this installer instead (they may be older)." "Yellow"
        $source = $localSource
    }
    if (-not $source) { Say "Could not get the mod files." "Red"; Pause-OnError; return }
}

if ($DryRun) {
    Say "Dry run: would copy $source -> $target" "Yellow"
    return
}

# ---- the game must be closed (its files are in use while it runs)
# (polled, never a keypress loop: without a keyboard Read-Host returns at once and spun forever)
if (Get-Process MultiVersus-Win64-Shipping, MultiVersus -ErrorAction SilentlyContinue) {
    Say "MultiVersus is running. Close the game; the install continues by itself." "Yellow"
    $until = (Get-Date).AddMinutes(10)
    while ((Get-Process MultiVersus-Win64-Shipping, MultiVersus -ErrorAction SilentlyContinue) -and (Get-Date) -lt $until) {
        Start-Sleep -Seconds 2
    }
    if (Get-Process MultiVersus-Win64-Shipping, MultiVersus -ErrorAction SilentlyContinue) {
        Say "MultiVersus is still running; nothing was installed. Close it and run the installer again." "Red"
        Pause-OnError; return
    }
    Start-Sleep -Seconds 2      # let Windows release the game's files
}

# ---- copy every file, replacing what is there, and check each one arrived intact
$from = (Resolve-Path -LiteralPath $source).Path.TrimEnd([char]92)
$files = Get-ChildItem -LiteralPath $from -Recurse -File
$failed = @()
foreach ($f in $files) {
    $rel = $f.FullName.Substring($from.Length).TrimStart([char]92)
    $dst = Join-Path $target $rel
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $want = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    $ok = $false
    for ($try = 1; $try -le 5 -and -not $ok; $try++) {
        try {
            if (Test-Path -LiteralPath $dst) { (Get-Item -LiteralPath $dst -Force).Attributes = 'Normal' }   # read-only, hidden
            [IO.File]::Copy($f.FullName, $dst, $true)
            $ok = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -eq $want
        } catch { }
        if (-not $ok) { Start-Sleep -Milliseconds 700 }
    }
    if (-not $ok) { $failed += $rel }
}
Say ""
if ($failed.Count -gt 0) {
    Say "These files could not be replaced:" "Red"
    foreach ($x in $failed) { Say "  $x" "Red" }
    Say "Close MultiVersus (and anything else using the game folder, e.g. an antivirus scan), then run the installer again." "Yellow"
    Pause-OnError; return
}
$dll = Get-Item -LiteralPath (Join-Path $target "MvsRevival.dll")
$ver = (Get-FileHash -LiteralPath $dll.FullName -Algorithm SHA256).Hash.Substring(0, 8).ToLower()
Say "Installed $($files.Count) files into $target" "Green"
Say "MvsRevival.dll version $ver (built $($dll.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" "Green"
Say "On the home screen, PLAY opens the multiplayer menu."
if (-not $NoLaunch -and $Host.Name -eq "ConsoleHost") {
    $answer = Read-Host "Start MultiVersus now? (Y/n)"
    if ($answer -notmatch '^[nN]') { Start-Process "steam://rungameid/$AppId" }
}
}

try { Install-Revival }
catch { Say "Install failed: $($_.Exception.Message)" "Red"; Pause-OnError }
