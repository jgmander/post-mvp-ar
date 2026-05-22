#!/bin/bash
set -e

echo "=== INITIALIZING TESTFLIGHT PIPELINE ==="

# 1. Clear the volatile cache
cd frontend
echo "Cleaning build cache..."
flutter clean
flutter pub get

# 2. Extract Secrets
# Note: We fetch the live maps key securely. 
export LIVE_MAPS_KEY=$(gcloud secrets versions access latest --secret="MAPS_API_KEY" --project="dbomar-post-mvp" 2>/dev/null)

# 3. Build the IPA
echo "Building iOS IPA (Build 22)..."
flutter build ipa --release \
  --build-name=1.0.0 \
  --build-number=22 \
  --export-options-plist=ios/config/ExportOptions.plist \
  --dart-define=MAPS_API_KEY="$LIVE_MAPS_KEY" \
  --dart-define=IOS_MAP_ID="1bf9740a3948b2695b963ae7" \
  --dart-define=MAP_ID="1bf9740a3948b26976700a08"

echo "=== BUILD COMPLETE ==="
echo "IPA located at: build/ios/ipa/*.ipa"
