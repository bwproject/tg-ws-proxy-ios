#!/bin/bash
set -euo pipefail

echo "=== TG WS Proxy iOS 15 — Build Script ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="build"
APP_NAME="TgWsProxy"
MIN_IOS="15.0"

if ! command -v go &> /dev/null; then
    echo "ERROR: Go not found. Install from https://go.dev/dl/"
    exit 1
fi

if ! command -v xcodebuild &> /dev/null; then
    echo "ERROR: Xcode Command Line Tools not found."
    exit 1
fi

echo "--- Step 1: Building XCFramework for iOS ${MIN_IOS}+ ---"
rm -rf "$BUILD_DIR/ios" "$BUILD_DIR/sim" "$BUILD_DIR/$APP_NAME.xcframework"
mkdir -p "$BUILD_DIR/ios" "$BUILD_DIR/sim"

IOS_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_CC="$(xcrun --sdk iphoneos -f clang)"
SIM_SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SIM_CC="$(xcrun --sdk iphonesimulator -f clang)"

CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
  CC="$IOS_CC" \
  CGO_CFLAGS="-isysroot $IOS_SDK_PATH -arch arm64 -mios-version-min=${MIN_IOS}" \
  CGO_LDFLAGS="-isysroot $IOS_SDK_PATH -arch arm64 -mios-version-min=${MIN_IOS}" \
  go build -v -buildmode=c-archive -o "$BUILD_DIR/ios/libtgwsproxy.a" .

CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
  CC="$SIM_CC" \
  CGO_CFLAGS="-isysroot $SIM_SDK_PATH -arch arm64 -mios-simulator-version-min=${MIN_IOS}" \
  CGO_LDFLAGS="-isysroot $SIM_SDK_PATH -arch arm64 -mios-simulator-version-min=${MIN_IOS}" \
  go build -v -buildmode=c-archive -o "$BUILD_DIR/sim/libtgwsproxy.a" .

xcodebuild -create-xcframework \
  -library "$BUILD_DIR/ios/libtgwsproxy.a" -headers include \
  -library "$BUILD_DIR/sim/libtgwsproxy.a" -headers include \
  -output "$BUILD_DIR/$APP_NAME.xcframework"

echo ""
echo "--- Step 2: Building unsigned .app with iOS ${MIN_IOS} deployment target ---"
rm -rf "$BUILD_DIR/$APP_NAME.xcarchive"
xcodebuild archive \
  -project TgWsProxy.xcodeproj \
  -scheme "$APP_NAME" \
  -configuration Release \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  "LIBRARY_SEARCH_PATHS=$(pwd)/$BUILD_DIR/ios" \
  "OTHER_LDFLAGS=$(pwd)/$BUILD_DIR/ios/libtgwsproxy.a"

APP="$BUILD_DIR/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app"
if [ ! -d "$APP" ]; then
    echo "ERROR: .app was not produced"
    exit 1
fi

MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP/Info.plist")"
echo "MinimumOSVersion: $MIN_OS"
if [ "$MIN_OS" != "$MIN_IOS" ]; then
    echo "ERROR: Expected MinimumOSVersion=${MIN_IOS}, got ${MIN_OS}"
    exit 1
fi

echo ""
echo "--- Step 3: Creating .ipa ---"
rm -rf "$BUILD_DIR/ipa"
mkdir -p "$BUILD_DIR/ipa/Payload"
cp -R "$APP" "$BUILD_DIR/ipa/Payload/"
cd "$BUILD_DIR/ipa"
zip -qry "../$APP_NAME.ipa" Payload
cd ../..

echo ""
echo "=== Done! ==="
echo "  IPA: $BUILD_DIR/$APP_NAME.ipa"
echo "  Minimum iOS: $MIN_IOS"
echo ""
echo "Установка на iPhone:"
echo "  1. AltStore"
echo "  2. Sideloadly"
echo "  3. Finder/iTunes"
