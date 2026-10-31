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
# Bundle a real pretrained YOLOv3 Tiny Core ML model from Apple's model gallery.
# The app never falls back to Apple Vision if this model is missing.
MODEL_CACHE="${HOME}/Library/Caches/Velmira"
MODEL_NAME="YOLOv3TinyInt8LUT"
MODEL_URL="https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/${MODEL_NAME}.mlmodel"
mkdir -p "${MODEL_CACHE}" build/coreml
if [ ! -s "${MODEL_CACHE}/${MODEL_NAME}.mlmodel" ]; then
  curl --fail --location --silent --show-error --retry 3 \
    "${MODEL_URL}" -o "${MODEL_CACHE}/${MODEL_NAME}.mlmodel"
fi
xcrun coremlcompiler compile "${MODEL_CACHE}/${MODEL_NAME}.mlmodel" build/coreml
test -d "build/coreml/${MODEL_NAME}.mlmodelc"
cp -R "build/coreml/${MODEL_NAME}.mlmodelc" "build/package/Payload/TPPlay.app/"
echo "Bundled ${MODEL_NAME}.mlmodelc into application."
(cd build/package && zip -qry ../Velmira-iOS-UNSIGNED.ipa Payload)
echo 'Created build/Velmira-iOS-UNSIGNED.ipa. Signing is required before installation.'
