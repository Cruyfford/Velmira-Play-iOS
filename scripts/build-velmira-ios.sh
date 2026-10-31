#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null; then
  echo 'Building iOS requires macOS and Xcode.' >&2
  exit 2
fi
mkdir -p build
set -o pipefail
xcodebuild -project ios/TPPlay.xcodeproj -scheme TPPlay \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tee build/xcodebuild.log
mkdir -p build/package/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/TPPlay.app build/package/Payload/
# The one-class MW3 YOLOv8n weights are user-provided and must not be
# committed to this public GitHub repository. Provide an unpacked model at
# ios/TPPlay/Resources/VelmiraMW3.mlpackage or via VELMIRA_MW3_MODEL_PACKAGE.
# iOS compiles the raw MLProgram once at runtime, caching the .mlmodelc.
MODEL_PACKAGE="${VELMIRA_MW3_MODEL_PACKAGE:-ios/TPPlay/Resources/VelmiraMW3.mlpackage}"
if [[ -d "$MODEL_PACKAGE" ]]; then
  test -s "$MODEL_PACKAGE/Manifest.json" || { echo 'Missing Core ML package manifest'; exit 4; }
  cp -R "$MODEL_PACKAGE" "build/package/Payload/TPPlay.app/VelmiraMW3.mlpackage"
  echo 'Bundled trained MW3 YOLOv8n Core ML model.'
else
  echo 'WARNING: MW3 model was not provided. This source-only CI build cannot detect enemies.' >&2
fi
(cd build/package && zip -qry ../Velmira-iOS-UNSIGNED.ipa Payload)
echo 'Created build/Velmira-iOS-UNSIGNED.ipa. Signing is required before installation.'
