# MultiVersus Revival installer: copies the mod into the game's Binaries\Win64 folder.
# Usage:  right-click -> "Run with PowerShell"
#    or:  powershell -ExecutionPolicy Bypass -File install.ps1 [-GameDir "D:\SteamLibrary\steamapps\common\MultiVersus"]
param([string]$GameDir = "")

if (-not $GameDir) {
    # Look in every Steam library for the MultiVersus install.
    $steam = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    $libs = @()
    if ($steam) {
        $libs += Join-Path $steam "steamapps"
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches).Matches) {
                $libs += (Join-Path ($m.Groups[1].Value -replace '\\\\', '\') "steamapps")
            }
        }
    }
    foreach ($lib in $libs) {
        $candidate = Join-Path $lib "common\MultiVersus"
        if (Test-Path (Join-Path $candidate "MultiVersus\Binaries\Win64\MultiVersus-Win64-Shipping.exe")) { $GameDir = $candidate; break }
    }
}
if (-not $GameDir) {
    Write-Host "MultiVersus was not found automatically."
    Write-Host "Run again with:  -GameDir ""<the folder that contains MultiVersus.exe>"""
    Read-Host "Press Enter to close"
    exit 1
}

$target = Join-Path $GameDir "MultiVersus\Binaries\Win64"
if (-not (Test-Path (Join-Path $target "MultiVersus-Win64-Shipping.exe"))) {
    Write-Host "No MultiVersus-Win64-Shipping.exe in $target"
    Read-Host "Press Enter to close"
    exit 1
}

Copy-Item -Path (Join-Path $PSScriptRoot "Win64\*") -Destination $target -Recurse -Force
Write-Host ""
Write-Host "MultiVersus Revival installed into:"
Write-Host "  $target"
Write-Host ""
Write-Host "Start MultiVersus from Steam. On the home screen press PLAY to open the multiplayer menu."
Read-Host "Press Enter to close"
