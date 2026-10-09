#!/usr/bin/env bash
# scripts/download-ios.sh
# Downloads the latest unsigned iOS build to a FIXED path next to the source
# folder, so Sideloadly can always point at the same file:
#   C:\Users\lixue\Projects\LocalRoll-ios\LocalRoll-unsigned.ipa
# Usage (Git Bash):  cd /c/Users/lixue/Projects/localroll && ./scripts/download-ios.sh
set -e
cd "$(dirname "$0")/.."
repo=lixuedenon/localroll
out="$(cd .. && pwd)/LocalRoll-ios"

command -v gh >/dev/null || { echo "GitHub CLI not found. Run: winget install GitHub.cli (then reopen Git Bash)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in. Run once: gh auth login"; exit 1; }

run=$(gh run list -R "$repo" -w CI -b main -s success -L 1 --json databaseId -q '.[0].databaseId')
[ -n "$run" ] || { echo "No successful build found."; exit 1; }

tmp="$(mktemp -d)"
echo "Downloading iOS build $run..."
gh run download "$run" -R "$repo" -n LocalRoll-iOS-unsigned -D "$tmp"
mkdir -p "$out"
mv -f "$tmp/LocalRoll-unsigned.ipa" "$out/LocalRoll-unsigned.ipa"
rm -rf "$tmp"
echo
echo "Done: $(cygpath -w "$out/LocalRoll-unsigned.ipa" 2>/dev/null || echo "$out/LocalRoll-unsigned.ipa")"
echo "In Sideloadly, pick this file and press Start."
