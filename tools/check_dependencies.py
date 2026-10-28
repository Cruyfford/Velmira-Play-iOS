#!/usr/bin/env python3
"""Fail early when the checkout lacks source dependencies required by iOS."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_DIRS = (
    "third-party/curl",
    "third-party/nanopb",
    "third-party/jerasure",
    "third-party/gf-complete",
)
REQUIRED_FILES = (
    "third-party/curl/CMakeLists.txt",
    "third-party/nanopb/CMakeLists.txt",
    "CMakeLists.txt",
    "ios/TPPlay.xcodeproj/project.pbxproj",
)
missing = [item for item in REQUIRED_DIRS if not (ROOT / item).is_dir()]
missing.extend(item for item in REQUIRED_FILES if not (ROOT / item).is_file())
if missing:
    print("Missing iOS build dependencies:", *missing, sep="\n  - ", file=sys.stderr)
    print("Use git submodule update --init --recursive.", file=sys.stderr)
    sys.exit(1)

print("Required iOS source dependencies are available.")
