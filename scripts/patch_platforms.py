# scripts/patch_platforms.py
"""Applies LocalRoll's settings to the platform folders `flutter create` generates.

Idempotent: safe to run again after regenerating or upgrading Flutter.
Run from the repository root:  python scripts/patch_platforms.py
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOBILE = ROOT / "apps" / "mobile"
DESKTOP = ROOT / "apps" / "desktop"

ANDROID_PERMISSIONS = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.CHANGE_WIFI_MULTICAST_STATE",
    "android.permission.CAMERA",
    # Photo library (Android 13+ granular, 14+ partial access, ≤12 legacy).
    "android.permission.READ_MEDIA_IMAGES",
    "android.permission.READ_MEDIA_VIDEO",
    "android.permission.READ_MEDIA_VISUAL_USER_SELECTED",
    # Without this Android strips GPS from originals handed to apps.
    "android.permission.ACCESS_MEDIA_LOCATION",
    "android.permission.WAKE_LOCK",
]

# English is the base text for the iOS permission prompts.
IOS_PLIST_KEYS = {
    "CFBundleDisplayName": "<string>LocalRoll</string>",
    "NSPhotoLibraryUsageDescription": "<string>LocalRoll reads your photos and videos so it can send the originals to your computer.</string>",
    "NSCameraUsageDescription": "<string>Scan the pairing QR code shown on your computer.</string>",
    "NSLocalNetworkUsageDescription": "<string>Find and connect to computers running LocalRoll on your local network. Files never go through the cloud.</string>",
    "NSBonjourServices": "<array>\n\t\t<string>_localroll._tcp</string>\n\t</array>",
    "NSAppTransportSecurity": "<dict>\n\t\t<key>NSAllowsLocalNetworking</key>\n\t\t<true/>\n\t</dict>",
    "PHPhotoLibraryPreventAutomaticLimitedAccessAlert": "<true/>",
    # UIScene lifecycle: on iOS 26 apps without it can silently lose permission
    # prompts (photos/camera never appear). Requires Flutter >= 3.38.
    "UIApplicationSceneManifest": (
        "<dict>\n"
        "\t\t<key>UIApplicationSupportsMultipleScenes</key>\n\t\t<false/>\n"
        "\t\t<key>UISceneConfigurations</key>\n\t\t<dict>\n"
        "\t\t\t<key>UIWindowSceneSessionRoleApplication</key>\n\t\t\t<array>\n\t\t\t\t<dict>\n"
        "\t\t\t\t\t<key>UISceneClassName</key>\n\t\t\t\t\t<string>UIWindowScene</string>\n"
        "\t\t\t\t\t<key>UISceneDelegateClassName</key>\n\t\t\t\t\t<string>FlutterSceneDelegate</string>\n"
        "\t\t\t\t\t<key>UISceneConfigurationName</key>\n\t\t\t\t\t<string>flutter</string>\n"
        "\t\t\t\t\t<key>UISceneStoryboardFile</key>\n\t\t\t\t\t<string>Main</string>\n"
        "\t\t\t\t</dict>\n\t\t\t</array>\n\t\t</dict>\n\t</dict>"
    ),
    # Tells iOS which UI languages the app supports (Flutter needs this to
    # receive the user's real language instead of always English).
    "CFBundleLocalizations": "<array>\n" + "".join(
        f"\t\t<string>{c}</string>\n"
        for c in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "pt", "ru",
                  "it", "ar", "hi", "id", "vi", "th", "tr"]
    ) + "\t</array>",
}

# Keys whose value is rewritten even if already present.
IOS_OVERRIDE = {"CFBundleDisplayName", "NSPhotoLibraryUsageDescription", "NSCameraUsageDescription",
                "NSLocalNetworkUsageDescription", "CFBundleLocalizations"}


def patch(path: pathlib.Path, fn) -> None:
    if not path.exists():
        print(f"skip (missing): {path.relative_to(ROOT)}")
        return
    old = path.read_text(encoding="utf-8")
    new = fn(old)
    if new != old:
        path.write_text(new, encoding="utf-8")
        print(f"patched: {path.relative_to(ROOT)}")
    else:
        print(f"ok: {path.relative_to(ROOT)}")


def android_manifest(text: str) -> str:
    missing = [p for p in ANDROID_PERMISSIONS if f'android:name="{p}"' not in text]
    lines = ""
    for p in missing:
        lines += f'<uses-permission android:name="{p}" />\n    '
    legacy = 'android.permission.READ_EXTERNAL_STORAGE'
    if legacy not in text:
        lines += f'<uses-permission android:name="{legacy}" android:maxSdkVersion="32" />\n    '
    if lines:
        text = text.replace("<application", lines + "\n    <application", 1)
    # Plain HTTP to the PC on the LAN; nothing ever goes to the internet.
    if "usesCleartextTraffic" not in text:
        text = text.replace("<application", '<application\n        android:usesCleartextTraffic="true"', 1)
    if "requestLegacyExternalStorage" not in text:
        text = text.replace("<application", '<application\n        android:requestLegacyExternalStorage="true"', 1)
    text = re.sub(r'android:label="[^"]*"', 'android:label="LocalRoll"', text, count=1)
    return text


def android_gradle(text: str) -> str:
    # mobile_scanner needs API 23+; use 24 (Android 7) as the floor.
    return re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 24", text)


def ios_plist(text: str) -> str:
    for key, value in IOS_PLIST_KEYS.items():
        marker = f"<key>{key}</key>"
        if marker in text:
            if key in IOS_OVERRIDE:
                text = re.sub(
                    re.escape(marker) + r"\s*(<string>[^<]*</string>|<array>.*?</array>)",
                    lambda _m, k=marker, v=value: f"{k}\n\t{v}",
                    text,
                    count=1,
                    flags=re.S,
                )
            continue
        idx = text.rfind("</dict>")
        text = text[:idx] + f"\t{marker}\n\t{value}\n" + text[idx:]
    return text

def windows_main(text: str) -> str:
    return text.replace('L"localroll_desktop"', 'L"LocalRoll"')


def main() -> int:
    patch(MOBILE / "android" / "app" / "src" / "main" / "AndroidManifest.xml", android_manifest)
    patch(MOBILE / "android" / "app" / "build.gradle.kts", android_gradle)
    patch(MOBILE / "ios" / "Runner" / "Info.plist", ios_plist)
    patch(DESKTOP / "windows" / "runner" / "main.cpp", windows_main)
    return 0


if __name__ == "__main__":
    sys.exit(main())
