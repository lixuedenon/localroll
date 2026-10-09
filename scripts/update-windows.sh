#!/usr/bin/env bash
# scripts/update-windows.sh
# Git Bash wrapper: pulls the latest code, then runs update-windows.ps1
# (downloads the latest CI build into ../LocalRoll-app and starts it).
#   cd /c/Users/lixue/Projects/localroll && ./scripts/update-windows.sh
set -e
cd "$(dirname "$0")/.."
git pull --ff-only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$PWD/scripts/update-windows.ps1")" "$@"
