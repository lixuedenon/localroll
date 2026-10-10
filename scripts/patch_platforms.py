# scripts/patch_platforms.py
"""Applies LocalRoll's settings to the platform folders `flutter create` generates.

Idempotent: safe to run again after regenerating or upgrading Flutter.
Run from the repository root:  python scripts/patch_platforms.py
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys
from xml.sax.saxutils import escape

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
    # Background transfer: foreground service with a progress notification.
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
    "android.permission.POST_NOTIFICATIONS",
]

ANDROID_SERVICE = (
    '<service\n'
    '            android:name=".TransferService"\n'
    '            android:exported="false"\n'
    '            android:foregroundServiceType="dataSync" />'
)

# Language content is data, not code: the languages come from
# packages/core/l10n/languages.json and the permission-prompt text from the
# "ios.*" keys in apps/mobile/l10n/<lang>.json. Info.plist gets the English
# text as the base; the translations go to <lproj>/InfoPlist.strings
# (written by scripts/gen_l10n.py, registered in the Xcode project below).
LANGUAGES = json.loads((ROOT / "packages" / "core" / "l10n" / "languages.json").read_text(encoding="utf-8"))["languages"]
MOBILE_EN = json.loads((MOBILE / "l10n" / "en.json").read_text(encoding="utf-8"))
IOS_PROMPTS = {
    "NSPhotoLibraryUsageDescription": "ios.photos",
    "NSCameraUsageDescription": "ios.camera",
    "NSLocalNetworkUsageDescription": "ios.local_network",
}
IOS_LPROJ = [lang["ios"] for lang in LANGUAGES]

IOS_PLIST_KEYS = {
    "CFBundleDisplayName": "<string>LocalRoll</string>",
    **{k: f"<string>{escape(MOBILE_EN[v])}</string>" for k, v in IOS_PROMPTS.items()},
    "NSBonjourServices": "<array>\n\t\t<string>_localroll._tcp</string>\n\t</array>",
    "NSAppTransportSecurity": "<dict>\n\t\t<key>NSAllowsLocalNetworking</key>\n\t\t<true/>\n\t</dict>",
    "PHPhotoLibraryPreventAutomaticLimitedAccessAlert": "<true/>",
    # Background transfer (iOS 26+ BGContinuedProcessingTask). Xcode expands
    # $(PRODUCT_BUNDLE_IDENTIFIER) at build time.
    "BGTaskSchedulerPermittedIdentifiers": "<array>\n\t\t<string>$(PRODUCT_BUNDLE_IDENTIFIER).transfer</string>\n\t</array>",
    "UIBackgroundModes": "<array>\n\t\t<string>processing</string>\n\t</array>",
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
        f"\t\t<string>{c}</string>\n" for c in IOS_LPROJ
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
    if ".TransferService" not in text:
        text = text.replace("</application>", "    " + ANDROID_SERVICE + "\n    </application>", 1)
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

def _xid(name: str) -> str:
    """Stable 24-hex Xcode object id (same input -> same id, so re-runs are no-ops)."""
    return hashlib.sha1(("localroll:" + name).encode()).hexdigest()[:24].upper()


def ios_pbxproj(text: str) -> str:
    """Adds the per-language InfoPlist.strings to the Runner target."""
    group = _xid("InfoPlist.strings group")
    build = _xid("InfoPlist.strings build")
    refs = {code: _xid("InfoPlist.strings " + code) for code in IOS_LPROJ}

    if group not in text:
        text = text.replace(
            "/* End PBXBuildFile section */",
            f"\t\t{build} /* InfoPlist.strings in Resources */ = {{isa = PBXBuildFile; fileRef = {group} /* InfoPlist.strings */; }};\n"
            "/* End PBXBuildFile section */", 1)
        text = text.replace(
            "/* Begin PBXVariantGroup section */",
            "/* Begin PBXVariantGroup section */\n"
            f"\t\t{group} /* InfoPlist.strings */ = {{\n\t\t\tisa = PBXVariantGroup;\n\t\t\tchildren = (\n"
            "\t\t\t);\n\t\t\tname = InfoPlist.strings;\n\t\t\tsourceTree = \"<group>\";\n\t\t};", 1)
        # Runner group and Runner's Copy Bundle Resources phase.
        text = re.sub(r"(97C146F01CF9000F007C117D /\* Runner \*/ = \{\s*isa = PBXGroup;\s*children = \()",
                      lambda m: m.group(1) + f"\n\t\t\t\t{group} /* InfoPlist.strings */,", text, count=1)
        text = re.sub(r"(97C146EC1CF9000F007C117D /\* Resources \*/ = \{\s*isa = PBXResourcesBuildPhase;\s*buildActionMask = \d+;\s*files = \()",
                      lambda m: m.group(1) + f"\n\t\t\t\t{build} /* InfoPlist.strings in Resources */,", text, count=1)

    for code, ref in refs.items():
        if ref in text:
            continue
        quoted = f'"{code}"' if "-" in code else code
        text = text.replace(
            "/* End PBXFileReference section */",
            f"\t\t{ref} /* {code} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.strings; "
            f"name = {quoted}; path = {code}.lproj/InfoPlist.strings; sourceTree = \"<group>\"; }};\n"
            "/* End PBXFileReference section */", 1)
        text = re.sub(re.escape(group) + r"( /\* InfoPlist.strings \*/ = \{\s*isa = PBXVariantGroup;\s*children = \()",
                      lambda m, r=ref, c=code: group + m.group(1) + f"\n\t\t\t\t{r} /* {c} */,", text, count=1)

    m = re.search(r"knownRegions = \((.*?)\);", text, re.S)
    if m:
        have = {r.strip().strip('"') for r in m.group(1).split(",") if r.strip()}
        add = [c for c in IOS_LPROJ if c not in have]
        if add:
            extra = "".join(f'\t\t\t\t{chr(34) + c + chr(34) if "-" in c else c},\n' for c in add)
            text = text[:m.end(1)].rstrip("\t") + extra + "\t\t\t" + text[m.end(1):]
    return text


def windows_main(text: str) -> str:
    return text.replace('L"localroll_desktop"', 'L"LocalRoll"')


def main() -> int:
    patch(MOBILE / "android" / "app" / "src" / "main" / "AndroidManifest.xml", android_manifest)
    patch(MOBILE / "android" / "app" / "build.gradle.kts", android_gradle)
    patch(MOBILE / "ios" / "Runner" / "Info.plist", ios_plist)
    patch(MOBILE / "ios" / "Runner.xcodeproj" / "project.pbxproj", ios_pbxproj)
    patch(DESKTOP / "windows" / "runner" / "main.cpp", windows_main)
    return 0


if __name__ == "__main__":
    sys.exit(main())
