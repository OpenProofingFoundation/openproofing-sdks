#!/usr/bin/env python3
"""Build the pinned document bridge as a distributable XCFramework, without unsafe client flags."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "native/DocumentOpenCVBridge"
NAME = "DocumentOpenCVBridge"
EXPORTS = {"_IEOpenCVDetectDocumentQuadrilateralRGBA", "_IEOpenCVID1Matrices", "_IEOpenCVWarpRGBA", "_IEOpenCVAnalyzeCardRGB", "_IEOpenCVCardAnalysisPoints", "_IEOpenCVCardAnalysisOffsets", "_IEOpenCVCardAnalysisMask", "_IEOpenCVCardAnalysisRelease"}
COMPILER_FLAGS = ["-std=c++20", "-O2", "-fno-rtti", "-fvisibility=hidden", "-fvisibility-inlines-hidden"]
SOURCES = [BRIDGE / "DocumentOpenCVBridge.mm"] + [BRIDGE / "Upstream/src" / (name + ".cpp") for name in ["DocumentDetector", "Utils", "WhitePaperTransform", "WhitePaperTransform2", "ColorSimplificationTransform"]]

SOURCES += [BRIDGE / "Spatial/SpatialAnalysis.cpp", BRIDGE / "Spatial/Vendor/EdgeDrawing/edge_drawing.cpp"] + sorted((BRIDGE / "Spatial/Native").glob("*.cpp"))

def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)

def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/native" / (NAME + ".xcframework"))
    args = parser.parse_args()
    destination = args.output.resolve()
    if destination.exists():
        raise SystemExit(f"Refusing to overwrite existing artifact: {destination}")
    run("python3", ROOT / "scripts/verify_capture_opencv.py")
    vendor = BRIDGE / "Spatial/Vendor/EdgeDrawing"
    manifest = json.loads((vendor / "manifest.json").read_text())
    for name, record in manifest["files"].items():
        if hashlib.sha256((vendor / name).read_bytes()).hexdigest() != record["sha256"]:
            raise SystemExit("Pinned EdgeDrawing source differs: " + name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    source_inputs = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(BRIDGE.rglob("*")) if p.is_file() and p.suffix in {".h", ".hpp", ".cpp", ".mm"}}
    # Map the checkout to "." so __FILE__ strings and debug info never carry this machine's path.
    prefix_maps = ["-ffile-prefix-map=" + str(ROOT) + "=.", "-fdebug-prefix-map=" + str(ROOT) + "=."]
    receipt = {"sourceInputs": source_inputs, "schemaVersion": 2, "xcode": output("xcodebuild", "-version"), "buildScriptSHA256": hashlib.sha256(Path(__file__).resolve().read_bytes()).hexdigest(), "compilerFlags": [flag.replace(str(ROOT), "<root>") for flag in prefix_maps + COMPILER_FLAGS], "sources": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}, "architectures": []}
    with tempfile.TemporaryDirectory(prefix="capture-bridge-") as temporary:
        work = Path(temporary)
        export_file = work / "exports.txt"
        export_file.write_text("\n".join(sorted(EXPORTS)) + "\n")
        frameworks = []
        profiles = [("iphoneos", "ios-arm64", ["arm64"], "ios18.0", "iPhoneOS"), ("iphonesimulator", "ios-arm64_x86_64-simulator", ["arm64", "x86_64"], "ios18.0-simulator", "iPhoneSimulator"), ("macosx", "macos-arm64_x86_64", ["arm64", "x86_64"], "macos13.0", "MacOSX")]
        for sdk, identifier, architectures, target_suffix, platform in profiles:
            framework = work / identifier / (NAME + ".framework")
            (framework / "Headers").mkdir(parents=True)
            (framework / "Modules").mkdir()
            shutil.copy2(BRIDGE / "include" / (NAME + ".h"), framework / "Headers")
            (framework / "Modules/module.modulemap").write_text(f'framework module {NAME} {{\n  umbrella header "{NAME}.h"\n  export *\n}}\n')
            info = {"CFBundleIdentifier": "org.kenshikilabs.document.opencv", "CFBundleName": NAME, "CFBundleExecutable": NAME, "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "CFBundleSupportedPlatforms": [platform], "MinimumOSVersion": "13.0" if sdk == "macosx" else "18.0"}
            (framework / "Info.plist").write_bytes(plistlib.dumps(info))
            opencv = ROOT / ".build/native/opencv2.xcframework" / identifier / "opencv2.framework"
            sdk_root = output("xcrun", "--sdk", sdk, "--show-sdk-path")
            binaries = []
            for arch in architectures:
                binary = work / identifier / (NAME + "-" + arch)
                target = arch + "-apple-" + target_suffix
                command = ["xcrun", "--sdk", sdk, "clang++", "-target", target, "-isysroot", sdk_root, *prefix_maps, *COMPILER_FLAGS, "-dynamiclib", "-install_name", "@rpath/" + NAME + ".framework/" + NAME, "-Wl,-exported_symbols_list," + str(export_file), "-I" + str(BRIDGE / "include"), "-I" + str(BRIDGE / "Spatial/Vendor/EdgeDrawing"), "-I" + str(BRIDGE / "Upstream/src/include"), "-F" + str(opencv.parent), *SOURCES, opencv / "opencv2", "-o", binary]
                for dependency in ["Accelerate", "Foundation", "AVFoundation", "CoreMedia", "CoreVideo", "CoreGraphics", "ImageIO", "QuartzCore", "AppKit" if sdk == "macosx" else "UIKit"]:
                    command += ["-framework", dependency]
                run(*command)
                actual = set(output("xcrun", "nm", "-gUj", binary).splitlines())
                if actual != EXPORTS:
                    raise SystemExit(f"Unexpected exported symbols for {target}: {sorted(actual ^ EXPORTS)}")
                binaries.append(binary)
                receipt["architectures"].append({"target": target, "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "exports": sorted(actual)})
            run("xcrun", "lipo", "-create", *binaries, "-output", framework / NAME)
            frameworks += ["-framework", framework]
        run("xcodebuild", "-create-xcframework", *frameworks, "-output", destination)
    receipt["artifactFiles"] = {str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(destination.rglob("*")) if p.is_file()}
    (destination.parent / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Built and export-verified {destination}")

if __name__ == "__main__":
    main()
