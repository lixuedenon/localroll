# scripts/update-windows.ps1
# Updates LocalRoll for Windows to the latest successful CI build, in one go.
#
# One-time setup:   winget install GitHub.cli    then    gh auth login
# Every update:     powershell -ExecutionPolicy Bypass -File update-windows.ps1
#
# Always installs into the same folder, so Windows Firewall keeps remembering
# the app and does not ask again.
param(
  [string]$InstallDir = "$env:LOCALAPPDATA\LocalRoll"
)
$ErrorActionPreference = 'Stop'
$repo = 'lixuedenon/localroll'

Write-Host 'Looking for the latest successful build...'
$runId = gh run list -R $repo -w CI -b main -s success -L 1 --json databaseId -q '.[0].databaseId'
if (-not $runId) { throw 'No successful build found.' }

Write-Host 'Closing LocalRoll...'
Get-Process -Name LocalRoll, localroll_desktop -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

$tmp = Join-Path $env:TEMP "localroll-update-$runId"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
Write-Host "Downloading build $runId..."
gh run download $runId -R $repo -n LocalRoll-Windows -D $tmp

if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
Move-Item $tmp $InstallDir

# Desktop shortcut (first run only).
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'LocalRoll.lnk'
if (-not (Test-Path $lnk)) {
  $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  $s.TargetPath = Join-Path $InstallDir 'LocalRoll.exe'
  $s.WorkingDirectory = $InstallDir
  $s.Save()
}

Write-Host "Starting LocalRoll from $InstallDir"
Start-Process (Join-Path $InstallDir 'LocalRoll.exe')
