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
(cd build/package && zip -qry ../Velmira-iOS-UNSIGNED.ipa Payload)
echo 'Created build/Velmira-iOS-UNSIGNED.ipa. Signing is required before installation.'
