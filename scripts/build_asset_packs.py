#!/usr/bin/env python3
"""Build Apple-hosted Background Assets packs for on-device recognition models.

Keep pack IDs, directory names, and encoder choices in sync with
ios/ShareCore/Realtime/Recognition/RecognitionAssetPack.swift and
RealtimeFluidAudioEngineCache.swift.

Usage:
    scripts/build_asset_packs.py [--output build/asset-packs] [--platform iOS|macOS]

Then upload each .aar with `asc background-assets` (or Transporter). Test locally with
`xcrun ba-serve --host <host> build/asset-packs/*.aar` and a Background Assets URL override.
"""

import argparse
import json
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

REPO = "FluidInference/parakeet-unified-en-0.6b-coreml"
PACK_DIRECTORY = "ParakeetUnifiedEN"
SHARED_PATHS = [
    "parakeet_unified_decoder.mlmodelc",
    "parakeet_unified_joint_decision_single_step.mlmodelc",
    "vocab.json",
    "metadata.json",
]
# int8 cannot build an execution plan on A16 (FluidAudio #828), so iOS ships fp16.
PACKS = {
    "iOS": ("ParakeetUnifiedEN-iOS", "parakeet_unified_encoder_streaming_70_7_7.mlmodelc"),
    "macOS": ("ParakeetUnifiedEN-macOS", "parakeet_unified_encoder_streaming_70_7_7_int8.mlmodelc"),
}


def list_files(path: str) -> list[dict]:
    url = f"https://huggingface.co/api/models/{REPO}/tree/main/{urllib.parse.quote(path)}?recursive=true"
    with urllib.request.urlopen(url) as response:
        entries = json.load(response)
    return [entry for entry in entries if entry["type"] == "file"]


def download(path: str, size: int, destination: Path) -> None:
    if destination.exists() and destination.stat().st_size == size:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://huggingface.co/{REPO}/resolve/main/{urllib.parse.quote(path)}"
    print(f"download {path}")
    subprocess.run(["curl", "-fL", "--retry", "3", "-o", str(destination), url], check=True)


def fetch(path: str, source_root: Path) -> None:
    if path.endswith(".mlmodelc"):
        for entry in list_files(path):
            download(entry["path"], entry["size"], source_root / PACK_DIRECTORY / entry["path"])
    else:
        with urllib.request.urlopen(f"https://huggingface.co/api/models/{REPO}/tree/main") as response:
            sizes = {entry["path"]: entry.get("size", 0) for entry in json.load(response)}
        download(path, sizes[path], source_root / PACK_DIRECTORY / path)


def build(platform: str, output: Path) -> Path:
    pack_id, encoder = PACKS[platform]
    source_root = output / "sources" / platform
    paths = SHARED_PATHS + [encoder]
    for path in paths:
        fetch(path, source_root)

    manifest = {
        "assetPackID": pack_id,
        "downloadPolicy": {"onDemand": {}},
        "fileSelectors": [
            {"directory": f"{PACK_DIRECTORY}/{path}"} if path.endswith(".mlmodelc")
            else {"file": f"{PACK_DIRECTORY}/{path}"}
            for path in paths
        ],
        "platforms": [platform],
    }
    manifest_path = source_root / "Manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    archive = (output / f"{pack_id}.aar").resolve()
    subprocess.run(
        ["xcrun", "ba-package", "package", "Manifest.json", "--output-path", str(archive)],
        cwd=source_root,
        check=True,
    )
    print(f"built {archive}")
    return archive


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, default=Path("build/asset-packs"))
    parser.add_argument("--platform", choices=sorted(PACKS), action="append")
    args = parser.parse_args()
    for platform in args.platform or sorted(PACKS):
        build(platform, args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
