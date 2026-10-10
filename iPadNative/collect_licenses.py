"""Include dependency notices from the exact Cargo-resolved sources in the app."""
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent
metadata = json.loads(subprocess.check_output(
    ["cargo", "metadata", "--format-version", "1", "--manifest-path", str(root / "Rust/Cargo.toml")], text=True
))
parts = ["TouchBridge iPad Native: third-party notices\n"]
for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
    if package["source"] is None:
        continue
    directory = pathlib.Path(package["manifest_path"]).parent
    parts.append(f"\n=== {package['name']} {package['version']} / {package.get('license') or 'see license file'} ===\n")
    files = set()
    if package.get("license_file"):
        files.add(directory / package["license_file"])
    for folder in [directory, directory.parent if package["name"] == "idevice" else directory]:
        for pattern in ["LICENSE*", "License*", "COPYING*", "NOTICE*", "license*", "COPYRIGHT*"]:
            files.update(p for p in folder.glob(pattern) if p.is_file())
    for file in sorted(files):
        parts.append(f"\n--- {file.name} ---\n" + file.read_text(encoding="utf-8", errors="replace"))
(root / "ThirdPartyNotices.txt").write_text("\n".join(parts), encoding="utf-8")
