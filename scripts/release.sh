#!/bin/bash
# Builds the release assets into .build/release/: libidevice_ffi.a and an unsigned,
# entitlement-free iphone-use-app.ipa (free Apple ID build, for SideStore/AltStore).
# Then: gh release create v<version> .build/release/*, and add the version to source.json.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f iPhoneUse/idevice/libidevice_ffi.a ] || scripts/build-idevice.sh
xcodebuild -project iPhoneUse.xcodeproj -scheme iPhoneUse -configuration Release \
  -destination generic/platform=iOS -derivedDataPath .build/dd -quiet \
  BUILTIN_VPN=NO CODE_SIGNING_ALLOWED=NO build
OUT=.build/release; rm -rf $OUT; mkdir -p $OUT/Payload
cp -R .build/dd/Build/Products/Release-iphoneos/iPhoneUse.app $OUT/Payload/
# Useless without the Network Extension entitlement, and it would take a free account's app ID.
rm -rf $OUT/Payload/iPhoneUse.app/PlugIns/TunnelProvider.appex
(cd $OUT && zip -qry iphone-use-app.ipa Payload && rm -rf Payload)
cp iPhoneUse/idevice/libidevice_ffi.a $OUT/
ls -l $OUT
