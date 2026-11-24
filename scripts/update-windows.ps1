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

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw 'GitHub CLI not found. Run: winget install GitHub.cli   (then reopen the terminal)'
}
gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw 'Not logged in to GitHub CLI. Run once: gh auth login' }

Write-Host 'Looking for the latest successful build...'
$runId = gh run list -R $repo -w CI -b main -s success -L 1 --json databaseId -q '.[0].databaseId'
if (-not $runId) { throw 'No successful build found.' }

# Close every running LocalRoll, wherever it was started from, and remember
# copies that run from another folder (those are old and should go).
Write-Host 'Closing LocalRoll...'
$others = @()
$running = Get-Process -Name LocalRoll, 'LocalRoll (1)', 'LocalRoll (2)', localroll_desktop -ErrorAction SilentlyContinue
foreach ($p in $running) {
  try {
    $dir = Split-Path $p.Path -Parent
    if ($dir -and ($dir.TrimEnd('\') -ne $full)) { $others += $dir }
  } catch {}
}
# Asked first (a Keepnear running as administrator can't be closed from a
# normal shell; it sees this file and quits by itself), then made to.
$quitFile = Join-Path $env:TEMP 'keepnear-quit.request'
if ($running) {
  Set-Content -LiteralPath $quitFile -Value 'update' -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Get-Process -Name LocalRoll, localroll_desktop -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 500
  }
}
Get-Process -Name LocalRoll, localroll_desktop -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# Its helpers too (screen pen, PDF, picker), if any are left.
Get-Process -Name lr_overlay, lr_pdf, lr_pick -ErrorAction SilentlyContinue | Where-Object {
  try { (Split-Path $_.Path -Parent).TrimEnd('\') -eq $full } catch { $false }
} | Stop-Process -Force -ErrorAction SilentlyContinue
# Wait until they are really gone (files stay locked until then).
for ($i = 0; $i -lt 20; $i++) {
  if (-not (Get-Process -Name LocalRoll, localroll_desktop -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 500
}
Remove-Item -LiteralPath $quitFile -ErrorAction SilentlyContinue
if (Get-Process -Name LocalRoll, localroll_desktop -ErrorAction SilentlyContinue) {
  throw 'Keepnear is still running (as administrator?). Quit it from its title bar, then run the update again.'
}

$tmp = Join-Path $env:TEMP "localroll-update-$runId"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
Write-Host "Downloading build $runId..."
gh run download $runId -R $repo -n LocalRoll-Windows -D $tmp
if (-not (Test-Path (Join-Path $tmp 'LocalRoll.exe'))) { throw 'Download incomplete (LocalRoll.exe missing). Nothing was changed.' }

# Old folder out completely, new folder in — never files mixed from two versions.
if (Test-Path $InstallDir) {
  Write-Host "Removing the old version in $InstallDir"
  Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
  if (Test-Path $InstallDir) {
    throw "Could not remove $InstallDir completely (a file is still in use). Close LocalRoll and any window showing that folder, then run the update again."
  }
}
Move-Item $tmp $InstallDir

# Desktop shortcut: always points at this folder (an old shortcut may point
# at a copy somewhere else).
$exe = Join-Path $InstallDir 'LocalRoll.exe'
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'LocalRoll.lnk'
# "Always open as administrator" switched on in Keepnear: the shortcut runs
# its scheduled task (administrator, no Windows prompt).
$task = $null
try { $task = Get-ScheduledTask -TaskName 'Keepnear' -ErrorAction Stop } catch {}
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
if ($task) {
  $s.TargetPath = Join-Path $env:SystemRoot 'System32\schtasks.exe'
  $s.Arguments = '/run /tn "Keepnear"'
  $s.WindowStyle = 7
} else {
  $s.TargetPath = $exe
  $s.Arguments = ''
}
$s.WorkingDirectory = $InstallDir
$s.IconLocation = "$exe,0"
$s.Save()

Write-Host ''
Write-Host "LocalRoll is installed in: $InstallDir"
Write-Host "Start it from the desktop shortcut 'LocalRoll' (it points there)."
foreach ($d in ($others | Select-Object -Unique)) {
  Write-Host ''
  Write-Host "NOTE: an old copy was running from $d" -ForegroundColor Yellow
  Write-Host '      It is not updated by this script. You can delete that folder.' -ForegroundColor Yellow
}
# Through the task when there is one (administrator, from any shell);
# otherwise the way this shell runs.
if ($task) {
  schtasks /run /tn 'Keepnear' | Out-Null
} else {
  # Through Explorer: as the signed-in user, not as administrator, even
  # when this shell runs as administrator (Keepnear then can't take
  # drag and drop, and what it opens can't be screenshotted).
  Start-Process explorer.exe -ArgumentList ('"' + $exe + '"')
}
