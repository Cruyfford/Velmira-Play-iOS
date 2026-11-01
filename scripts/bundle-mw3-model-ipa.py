#!/usr/bin/env python3
"""Add the user-supplied MW3 Core ML model to a source-only unsigned CI IPA.

Run from any OS: python3 scripts/bundle-mw3-model-ipa.py SOURCE.ipa MODEL.mlpackage OUTPUT.ipa
The output must be signed before installation. Never commit private trained weights.
"""
import argparse
import json
from pathlib import Path
import sys
import zipfile

MODEL_NAME = "VelmiraMW3.mlpackage"
REQUIRED_FILES = (
    "Manifest.json",
    "Data/com.apple.CoreML/model.mlmodel",
    "Data/com.apple.CoreML/weights/weight.bin",
)

def validate_model(model_dir: Path) -> None:
    if not model_dir.is_dir():
        raise ValueError(f"Missing Core ML package: {model_dir}")
    for relative in REQUIRED_FILES:
        path = model_dir / relative
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Missing Core ML resource: {relative}")
    if (model_dir / REQUIRED_FILES[-1]).stat().st_size < 1_000_000:
        raise ValueError("Core ML model weights are incomplete")
    with (model_dir / "Manifest.json").open(encoding="utf-8") as f:
        if not isinstance(json.load(f), dict):
            raise ValueError("Invalid Core ML manifest")

def bundle(source_ipa: Path, model_dir: Path, output_ipa: Path) -> None:
    validate_model(model_dir)
    if source_ipa.resolve() == output_ipa.resolve():
        raise ValueError("Output must differ from source IPA")
    with zipfile.ZipFile(source_ipa) as src:
        roots = sorted({path.removesuffix("Info.plist") for path in src.namelist()
                        if path.startswith("Payload/") and path.endswith(".app/Info.plist")})
        if len(roots) != 1:
            raise ValueError("IPA must contain exactly one application bundle")
        app = roots[0]
        if app + "TPPlay" not in src.namelist():
            raise ValueError("Not a Velmira TPPlay application")
        output_ipa.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output_ipa, "w", allowZip64=True) as dst:
            for info in src.infolist():
                if info.filename.startswith(app + MODEL_NAME + "/"):
                    continue
                dst.writestr(info, src.read(info.filename))
            for path in sorted(model_dir.rglob("*")):
                if path.is_symlink():
                    raise ValueError("Model package must not contain symlinks")
                if path.is_file():
                    dest = app + MODEL_NAME + "/" + path.relative_to(model_dir).as_posix()
                    dst.write(path, arcname=dest, compress_type=zipfile.ZIP_DEFLATED)
    with zipfile.ZipFile(output_ipa) as dst:
        for relative in REQUIRED_FILES:
            if app + MODEL_NAME + "/" + relative not in dst.namelist():
                raise ValueError("Missing bundled Core ML resource: " + relative)
        if bad := dst.testzip():
            raise ValueError("Corrupt IPA member: " + bad)
    print(f"Verified unsigned IPA with MW3 model: {output_ipa}")

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_ipa", type=Path)
    parser.add_argument("model_dir", type=Path)
    parser.add_argument("output_ipa", type=Path)
    args = parser.parse_args()
    try:
        bundle(args.source_ipa, args.model_dir, args.output_ipa)
        return 0
    except (OSError, ValueError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
