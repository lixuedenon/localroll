#!/usr/bin/env bash
# scripts/download-android.sh
# Downloads the latest Android build to a FIXED path next to the source folder:
#   C:\Users\lixue\Projects\LocalRoll-android\LocalRoll-Android.apk
# If the phone is plugged in by USB with "USB debugging" on and adb is
# installed, it is also installed straight onto the phone (data is kept).
# Usage (Git Bash):  cd /c/Users/lixue/Projects/localroll && ./scripts/download-android.sh
set -e
cd "$(dirname "$0")/.."
repo=lixuedenon/localroll
out="$(cd .. && pwd)/LocalRoll-android"

command -v gh >/dev/null || { echo "GitHub CLI not found. Run: winget install GitHub.cli (then reopen Git Bash)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in. Run once: gh auth login"; exit 1; }

run=$(gh run list -R "$repo" -w CI -b main -s success -L 1 --json databaseId -q '.[0].databaseId')
[ -n "$run" ] || { echo "No successful build found."; exit 1; }

tmp="$(mktemp -d)"
echo "Downloading Android build $run..."
gh run download "$run" -R "$repo" -n LocalRoll-Android -D "$tmp"
mkdir -p "$out"
mv -f "$tmp/app-release.apk" "$out/LocalRoll-Android.apk"
rm -rf "$tmp"
apk="$out/LocalRoll-Android.apk"
echo
echo "Done: $(cygpath -w "$apk" 2>/dev/null || echo "$apk")"

if command -v adb >/dev/null && adb get-state >/dev/null 2>&1; then
  echo "Phone found over USB, installing..."
  adb install -r "$(cygpath -w "$apk" 2>/dev/null || echo "$apk")"
  echo "Installed. Open LocalRoll on the phone."
else
  echo "To install: copy this file to the phone (or send it to yourself) and open it."
  echo "Allow \"Install unknown apps\" when Android asks. Updating keeps your settings."
fi
