#!/usr/bin/env bash
# scripts/setup-android-signing.sh
# Run ONCE. Makes LocalRoll's Android signing key and gives it to GitHub
# (as Actions secrets), so every CI build is signed with the same key and a
# new APK installs over the old one without losing data.
#
# The key stays on this PC (and in GitHub secrets, which nobody can read back):
#   C:\Users\lixue\Projects\LocalRoll-keys\localroll-android.jks
#   C:\Users\lixue\Projects\LocalRoll-keys\localroll-android-password.txt
# Back up that folder (USB stick / password manager). Never commit it.
#
# Usage (Git Bash):  cd /c/Users/lixue/Projects/localroll && ./scripts/setup-android-signing.sh
set -e
cd "$(dirname "$0")/.."
repo=lixuedenon/localroll
keys="$(cd .. && pwd)/LocalRoll-keys"
jks="$keys/localroll-android.jks"
pwfile="$keys/localroll-android-password.txt"

command -v gh >/dev/null || { echo "GitHub CLI not found. Run: winget install GitHub.cli (then reopen Git Bash)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Not logged in. Run once: gh auth login"; exit 1; }

mkdir -p "$keys"
if [ -f "$jks" ]; then
  echo "Key already exists: $(cygpath -w "$jks" 2>/dev/null || echo "$jks") — reusing it."
  pw="$(tr -d '\r\n' < "$pwfile")"
else
  pw="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  # keytool (Android Studio / a JDK) if there is one; otherwise the openssl
  # that comes with Git Bash. Both make a PKCS12 key store Android accepts.
  kt="$(command -v keytool || true)"
  for c in "/c/Program Files/Android/Android Studio/jbr/bin/keytool.exe" \
           "/c/Program Files/Android/Android Studio/jre/bin/keytool.exe" \
           "${JAVA_HOME:-/nonexistent}/bin/keytool.exe"; do
    [ -z "$kt" ] && [ -f "$c" ] && kt="$c"
  done
  if [ -n "$kt" ]; then
    "$kt" -genkeypair -keystore "$(cygpath -w "$jks" 2>/dev/null || echo "$jks")" -storetype PKCS12 \
      -keyalg RSA -keysize 3072 -validity 36500 -alias localroll \
      -storepass "$pw" -keypass "$pw" -dname "CN=LocalRoll, O=LocalRoll" >/dev/null
  elif command -v openssl >/dev/null; then
    tmp="$(mktemp -d)"
    MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:3072 -nodes -days 36500 \
      -subj "/CN=LocalRoll/O=LocalRoll" -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    openssl pkcs12 -export -name localroll -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
      -out "$jks" -passout "pass:$pw"
    rm -rf "$tmp"
  else
    echo "Neither keytool nor openssl found. Install Android Studio or a JDK, then run this again."
    exit 1
  fi
  printf '%s\n' "$pw" > "$pwfile"
  echo "Made a new key: $(cygpath -w "$jks" 2>/dev/null || echo "$jks")"
fi

base64 -w0 "$jks" | gh secret set LR_KEYSTORE_B64 -R "$repo"
printf '%s' "$pw" | gh secret set LR_KEYSTORE_PASSWORD -R "$repo"
printf '%s' "$pw" | gh secret set LR_KEY_PASSWORD -R "$repo"
printf '%s' "localroll" | gh secret set LR_KEY_ALIAS -R "$repo"

echo
echo "Done. GitHub now signs every Android build with this key."
echo "Back up the folder $(cygpath -w "$keys" 2>/dev/null || echo "$keys") somewhere safe."
echo "Next: start a build (tell Claude, or push any change), then run ./scripts/download-android.sh"
