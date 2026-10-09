"""Build packaging for a preinstalled iOS 17+ WebDriverAgent runner."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.jonesnela.TouchBridge"


def write_ipa(app, ipa):
    """Include runtime files only; signing tools must never scan debug binaries."""
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob("*")):
            relative = path.relative_to(app.parent)
            if any(part.endswith((".dSYM", ".bcsymbolmap")) for part in relative.parts):
                continue
            if path.is_file():
                archive.write(path, "Payload/" + relative.as_posix())


def prepare():
    project = ROOT / "WebDriverAgent.xcodeproj/project.pbxproj"
    text = project.read_text(encoding="utf-8")
    old = "PRODUCT_BUNDLE_IDENTIFIER = com.facebook.WebDriverAgentRunner;"
    if old not in text:
        raise RuntimeError("Expected upstream runner bundle identifier not found")
    project.write_text(text.replace(old, f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE};"), encoding="utf-8")


def package():
    app = ROOT / "build/TouchBridge/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app"
    plugin = app / "PlugIns/WebDriverAgentRunner.xctest"
    if not (plugin / "WebDriverAgentRunner").is_file():
        raise RuntimeError("Built XCTest plugin is missing")
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if info["CFBundleIdentifier"] != BUNDLE + ".xctrunner":
        raise RuntimeError(f"Unexpected bundle identifier: {info['CFBundleIdentifier']}")
    info["CFBundleDisplayName"] = "TouchBridge"
    info["NSLocalNetworkUsageDescription"] = "连接您信任的局域网电脑以执行远程触控。"
    info_path.write_bytes(plistlib.dumps(info))

    # Follow upstream Scripts/ci/build-real.sh: iOS 17+ loads XCTest from DDI.
    # The plugin's own Frameworks directory, including WDA, must be retained.
    frameworks = app / "Frameworks"
    if frameworks.is_dir():
        shutil.rmtree(frameworks)
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    ipa = dist / "TouchBridge.ipa"
    write_ipa(app, ipa)
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    (dist / "SHA256SUMS.txt").write_text(f"{digest}  TouchBridge.ipa\n", encoding="utf-8")
    metadata = {
        "bundle_id": info["CFBundleIdentifier"],
        "signed": False,
        "architecture": "arm64",
        "runtime_target": "iOS/iPadOS 17+ with mounted DDI and developer mode",
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
        "sha256": digest,
    }
    (dist / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(f"Packaged {ipa.name}: {digest}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["prepare", "package"])
    args = parser.parse_args()
    {"prepare": prepare, "package": package}[args.action]()
