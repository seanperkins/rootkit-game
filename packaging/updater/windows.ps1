# ROOTKIT update helper (Windows). Ran by the game from the OS cache — the
# bundled copy is about to be deleted by the swap this performs. The game has
# already verified the archive (RSA-4096 signature + SHA-256); this only
# replaces the game directory and optionally relaunches it.
#
#   powershell -File windows.ps1 -Archive <zip> -Target <dir> [-Relaunch 1|0] [-State <file>]
#
# tar.exe (bsdtar) ships with Windows 10 1803+, so no unzip dependency.

param(
    [Parameter(Mandatory = $true)][string]$Archive,
    [Parameter(Mandatory = $true)][string]$Target,
    [int]$Relaunch = 0,
    [string]$State = ""
)
$ErrorActionPreference = "Stop"

# The game spawned us and then quits. Wait for it so the exe handle is gone.
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Process -Name "ROOTKIT" -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
}

$stage = Join-Path $Target (".ROOTKIT-update-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
& tar -xf $Archive -C $stage
if ($LASTEXITCODE -ne 0) { throw "unpack failed" }
if (-not (Test-Path (Join-Path $stage "ROOTKIT.exe"))) { throw "no ROOTKIT.exe in the archive" }

# Clean swap: remove the old contents, move the new ones in. The old helper
# script is already executing from the OS cache, so removing it is safe.
Get-ChildItem -Path $Target -Force | Remove-Item -Recurse -Force
Get-ChildItem -Path $stage -Force | Move-Item -Destination $Target -Force
Remove-Item -Recurse -Force $stage
if ($State -and (Test-Path $State)) { Remove-Item $State -Force }
if (Test-Path $Archive) { Remove-Item $Archive -Force }

if ($Relaunch -eq 1) {
    Start-Process -FilePath (Join-Path $Target "ROOTKIT.exe")
}
