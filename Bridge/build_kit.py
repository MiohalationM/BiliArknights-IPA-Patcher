#!/usr/bin/env python3
"""Build source-built ABLoginBridge.dylib + official ABSDKCarrier.dylib kit for ios-ipa-tool."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parent
TOOL_ROOT = ROOT.parent
BIIOS_ROOT = TOOL_ROOT.parent
DEFAULT_UPSTREAM_KIT = BIIOS_ROOT / "releases/v7.5.1/profiles/2.7.91-76/kit"
BUILD_OUT = ROOT / "build"
KIT_OUT = TOOL_ROOT / "Packages/IPAPatcherCore/Sources/IPAPatcherCore/Resources/Kits/carrier-2.7.91"

EXPECTED_UPSTREAM_BRIDGE_SHA256 = "5fe8d0c934f533835f21b691415b318fda2e4e1ad5857310f0d885f9e37b16ce"
REVISION = "7.5-2.7.91-bridge-carrier-r5"
DETERMINISTIC_ZIP_DATETIME = (2026, 1, 1, 0, 0, 0)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_bridge_dylib() -> Path:
    BUILD_OUT.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    sources = [
        "Sources/ABPolicy.c",
        "Sources/ABLoginResult.m",
        "Sources/ABChannelControl.m",
        "Sources/ABLoginCallbacks.m",
        "Sources/ABRuntime.m",
        "Sources/ABHooks.m",
        "Sources/ABBootstrap.m",
    ]
    flags = [
        "xcrun", "--sdk", "iphoneos", "clang",
        "-target", "arm64-apple-ios13.0",
        "-isysroot", sdk,
        "-fobjc-arc",
        "-fvisibility=hidden",
        "-Wall", "-Wextra", "-Werror",
        "-Wno-incomplete-implementation",
        "-Wno-objc-protocol-method-implementation",
        "-Wno-deprecated-declarations",
        "-O2",
    ]
    objects = []
    for src in sources:
        obj = BUILD_OUT / (Path(src).stem + ".o")
        subprocess.run([*flags, "-c", str(ROOT / src), "-o", str(obj)], check=True)
        objects.append(str(obj))

    target = BUILD_OUT / "ABLoginBridge.dylib"
    subprocess.run([
        *flags, "-dynamiclib", *objects,
        "-framework", "Foundation",
        "-framework", "UIKit",
        "-framework", "CoreGraphics",
        "-framework", "QuartzCore",
        "-install_name", "@rpath/ABLoginBridge.dylib",
        "-Wl,-exported_symbol,_ABEnableBLoginHooks",
        "-Wl,-exported_symbol,_ABLoginState",
        "-Wl,-exported_symbol,_ABMakeU8LoginResult",
        "-Wl,-exported_symbol,_ABPrepareBLogin",
        "-Wl,-exported_symbol,_ABSDKLoadDiagnostic",
        "-o", str(target),
    ], check=True)
    subprocess.run(["codesign", "-s", "-", "--force", str(target)], check=True)
    return target


def prepare_sdk_carrier(upstream_payload_zip: Path) -> Path:
    with zipfile.ZipFile(upstream_payload_zip) as z:
        original = z.read("Payload/Arknights.app/Frameworks/ABLoginBridge.dylib")
    actual_sha = sha256_bytes(original)
    if actual_sha != EXPECTED_UPSTREAM_BRIDGE_SHA256:
        raise SystemExit(f"Unexpected official SDK carrier hash: {actual_sha}")

    buf = bytearray(original)
    # Disable the legacy bridge constructor at 0xeb90 (`ret` in ARM64).
    buf[0xeb90:0xeb94] = bytes.fromhex("c0035fd6")
    # Rename the two legacy bridge ObjC classes to avoid runtime collision with our source-built bridge.
    for old, new in [(b"ABLoginCoordinator", b"ZBLoginCoordinator"), (b"ABBootstrap", b"ZBBootstrap")]:
        assert len(old) == len(new)
        buf = buf.replace(old, new)

    target = BUILD_OUT / "ABSDKCarrier.dylib"
    target.write_bytes(buf)
    subprocess.run(["install_name_tool", "-id", "@rpath/ABSDKCarrier.dylib", str(target)], check=True)
    subprocess.run(["codesign", "--force", "-s", "-", str(target)], check=True)
    return target


def make_runtime_profile_plist() -> bytes:
    profile = {
        "schema": 1,
        "revision": REVISION,
        "version": "2.7.91",
        "build": "76",
        "unityUUID": "386e1e29-f538-38c5-84d3-40427d3e6eb1",
        "unityTextSize": 0x99F7A28,
        "unityTextSHA256": "ef43071f7010d6c429f34bd4b9dd3e347941db43dfd3b47913e146fe98f67443",
        "il2cppOffsets": {
            "sdkInterfaceClassSlot": 0xB9A5E38,
            "sdkExternalToolsClassSlot": 0xB99D618,
            "sdkMetaClassSlot": 0xB99D6C0,
            "networkerTypeSlot": 0xBA1CC48,
            "networkerExpectedClass": 0x6049B80,
            "gameFlowClassSlot": 0xB98F408,
            "getNetworkConfigFn": 0x77AD3AC,
            "overrideNetworkOptionsFn": 0x77AD968,
            "createStringFn": 0x7DCAF48,
            "internalSDKMetaFn": 0x6C5AFF4,
            "sdkMetaCtorFn": 0x6C62A84,
            "clearAuthStatusFn": 0x6C5C478,
            "clearLoginStatusFn": 0x6C5C53C,
            "getCurrentSceneFn": 0x18178D4,
        },
    }
    return plistlib.dumps(profile, fmt=plistlib.FMT_BINARY)


def build_kit(upstream_kit: Path) -> None:
    if not (upstream_kit / "payload.zip").is_file():
        raise SystemExit(
            f"Missing upstream kit at {upstream_kit} (pass --upstream-kit <dir> containing manifest.json & payload.zip)"
        )

    bridge_dylib = build_bridge_dylib()
    carrier_dylib = prepare_sdk_carrier(upstream_kit / "payload.zip")

    app_root = "Payload/Arknights.app/"
    with zipfile.ZipFile(upstream_kit / "payload.zip") as z:
        entries = {name: z.read(name) for name in z.namelist() if not name.endswith("/")}

    # Exclude frozen host Info.plist from static overlay: IPAPatcherCore dynamically merges
    # the B-server delta keys directly into the host IPA's own Info.plist!
    entries.pop(app_root + "Info.plist", None)

    bridge_bytes = bridge_dylib.read_bytes()
    carrier_bytes = carrier_dylib.read_bytes()
    entries[app_root + "Frameworks/ABLoginBridge.dylib"] = bridge_bytes
    entries[app_root + "Frameworks/ABSDKCarrier.dylib"] = carrier_bytes
    entries[app_root + "ABRuntimeProfile.plist"] = make_runtime_profile_plist()

    build_info = json.loads(entries[app_root + "ABBuildInfo.json"])
    build_info.update({
        "patch_revision": REVISION,
        "bridge_sha256": sha256_bytes(bridge_bytes),
        "sdk_carrier_sha256": sha256_bytes(carrier_bytes),
        "implementation": "audited data-driven bridge source + complete official Bilibili SDK carrier",
        "sdk": "official Bilibili SDK carrier (ABSDKCarrier.dylib)",
    })
    entries[app_root + "ABBuildInfo.json"] = (json.dumps(build_info, ensure_ascii=False, indent=2) + "\n").encode("utf-8")

    KIT_OUT.mkdir(parents=True, exist_ok=True)
    payload_path = KIT_OUT / "payload.zip"
    with zipfile.ZipFile(payload_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zout:
        for name in sorted(entries):
            info = zipfile.ZipInfo(filename=name, date_time=DETERMINISTIC_ZIP_DATETIME)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o100755 if name.endswith(".dylib") else 0o100644
            info.external_attr = mode << 16
            zout.writestr(info, entries[name], compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)

    base_manifest = json.loads((upstream_kit / "manifest.json").read_bytes())
    manifest = {
        "schema": 1,
        "revision": REVISION,
        "bundle_id": base_manifest["bundle_id"],
        "version": base_manifest["version"],
        "build": base_manifest["build"],
        "app_root": base_manifest["app_root"],
        "input_hash_allowlist_used": False,
        "host_binaries": base_manifest["host_binaries"],
        # Keep binary_patches metadata empty or informational — MachODylibInjector injects dynamically!
        "binary_patches": {},
        "dynamic_dylib_injection": {
            "target_binary": "Payload/Arknights.app/Frameworks/UnityFramework.framework/UnityFramework",
            "dylib_load_path": "@executable_path/Frameworks/ABLoginBridge.dylib",
        },
        "payload_sha256": sha256_bytes(payload_path.read_bytes()),
        "payload_entries": {name: sha256_bytes(entries[name]) for name in sorted(entries)},
        "runtime_note": "Audited source-built bridge + complete official Bilibili SDK carrier (ABSDKCarrier.dylib).",
        "encryption_policy": "Decrypted input required; no decryption, no signing",
        "sdk": "official Bilibili SDK carrier (ABSDKCarrier.dylib)",
    }

    manifest_raw = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    manifest_path = KIT_OUT / "manifest.json"
    manifest_path.write_bytes(manifest_raw)

    summary = {
        "revision": REVISION,
        "bridge_bytes": len(bridge_bytes),
        "bridge_sha256": sha256_bytes(bridge_bytes),
        "carrier_bytes": len(carrier_bytes),
        "carrier_sha256": sha256_bytes(carrier_bytes),
        "payload_entries": len(entries),
        "payload_zip_bytes": payload_path.stat().st_size,
        "payload_sha256": manifest["payload_sha256"],
        "manifest_sha256": sha256_bytes(manifest_raw),
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser(description="Build audited ABLoginBridge.dylib + ABSDKCarrier.dylib kit.")
    parser.add_argument(
        "--upstream-kit",
        type=Path,
        default=Path(os.environ.get("ARKNIGHTS_UPSTREAM_KIT", str(DEFAULT_UPSTREAM_KIT))),
        help="Path to upstream kit directory containing manifest.json and payload.zip",
    )
    args = parser.parse_args()
    build_kit(args.upstream_kit)


if __name__ == "__main__":
    main()
