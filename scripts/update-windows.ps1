# scripts/update-windows.ps1
# Updates LocalRoll for Windows to the latest successful CI build, in one go.
#
# One-time setup:   winget install GitHub.cli    then    gh auth login
# Every update:     powershell -ExecutionPolicy Bypass -File update-windows.ps1
#
# Installs the app next to the source folder, e.g.
#   source:  C:\Users\lixue\Projects\localroll
#   app:     C:\Users\lixue\Projects\LocalRoll-app
# Always the same folder, so Windows Firewall remembers it and does not ask again.
# Another folder:  ... -File update-windows.ps1 -InstallDir D:\Apps\LocalRoll
param(
  [string]$InstallDir = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'LocalRoll-app')
)
$ErrorActionPreference = 'Stop'

# The install folder is wiped on every update — never let that be a source tree.
# (Compare with a trailing '\' so "...\LocalRoll-app" is not taken as inside "...\localroll".)
$repoRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\') + '\'
$full = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$ic = [StringComparison]::OrdinalIgnoreCase
if ((Test-Path (Join-Path $full '.git')) -or $repoRoot.StartsWith($full + '\', $ic) -or ($full + '\').StartsWith($repoRoot, $ic)) {
  throw "InstallDir $full is (inside) the source folder; pick a separate folder."
}
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
