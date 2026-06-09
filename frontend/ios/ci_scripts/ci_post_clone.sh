#!/bin/sh

# Fail this script if any command fails.
set -e

echo "=== INITIALIZING XCODE CLOUD FLUTTER BRIDGE ==="

# 1. Install Flutter: clone the SDK and pin to version 3.41.9
echo "Installing Flutter 3.41.9..."
git clone https://github.com/flutter/flutter.git --depth 1 -b 3.41.9 $HOME/flutter

# 2. Set PATH
export PATH="$PATH:$HOME/flutter/bin"

# 3. Precache iOS artifacts
echo "Precaching iOS engine artifacts..."
flutter precache --ios

# 4. Resolve Dependencies
# $CI_PRIMARY_REPOSITORY_PATH is provided by Xcode Cloud and points to the git root.
echo "Navigating to project root and running pub get..."
cd $CI_PRIMARY_REPOSITORY_PATH/frontend
flutter pub get

# 5. Generate Configs (CRITICAL)
# This creates Generated.xcconfig with our injected secrets so Xcode can compile.
echo "Generating iOS configs..."
flutter build ios --release --no-codesign --config-only \
  --dart-define=MAPS_API_KEY="$MAPS_API_KEY" \
  --dart-define=MAP_ID="$MAP_ID" \
  --dart-define=IOS_MAP_ID="$IOS_MAP_ID"

# 6. Pod Install (CRITICAL)
echo "Installing CocoaPods..."
cd $CI_PRIMARY_REPOSITORY_PATH/frontend/ios
pod install

echo "=== FLUTTER BRIDGE COMPLETE. HANDING OFF TO XCODE ==="
