#!/bin/sh

# Fail this script if any command fails.
set -e

echo "=== INITIALIZING XCODE CLOUD FLUTTER BRIDGE ==="

# 1. Install Flutter: clone the SDK and pin to version 3.41.9
echo "Installing Flutter 3.41.9..."
# --progress ensures git keeps printing to stdout so Xcode Cloud doesn't time out
git clone https://github.com/flutter/flutter.git --depth 1 -b 3.41.9 --progress $HOME/flutter

# 2. Set PATH for Flutter
export PATH="$PATH:$HOME/flutter/bin"

# 3. Ensure CocoaPods is installed.
# Xcode Cloud runners (particularly Xcode 26.x images) do not guarantee CocoaPods
# is pre-installed, so we install it explicitly via RubyGems.
echo "Ensuring CocoaPods is installed..."
if ! command -v pod &> /dev/null; then
  echo "pod not found — installing via gem..."
  sudo gem install cocoapods --no-document
else
  echo "pod found at: $(which pod) — version: $(pod --version)"
fi

# 4. Precache iOS artifacts
# --verbose keeps stdout active during the ~1GB engine download — prevents Xcode Cloud timeout
echo "Precaching iOS engine artifacts..."
flutter precache --ios --verbose

# 5. Resolve Dependencies
# $CI_PRIMARY_REPOSITORY_PATH is provided by Xcode Cloud and points to the git root.
echo "Navigating to project root and running pub get..."
cd $CI_PRIMARY_REPOSITORY_PATH/frontend
flutter pub get --verbose

# 6. Generate Configs (CRITICAL)
# This creates Generated.xcconfig with our injected secrets so Xcode can compile.
echo "Generating iOS configs..."
flutter build ios --release --no-codesign --config-only \
  --dart-define=MAPS_API_KEY="$MAPS_API_KEY" \
  --dart-define=MAP_ID="$MAP_ID" \
  --dart-define=IOS_MAP_ID="$IOS_MAP_ID" \
  --verbose

# 7. Pod Install (CRITICAL)
echo "Running pod install..."
cd $CI_PRIMARY_REPOSITORY_PATH/frontend/ios
# --verbose keeps Xcode Cloud from timing out during pod fetch/compile
pod install --verbose

echo "=== FLUTTER BRIDGE COMPLETE. HANDING OFF TO XCODE ==="
