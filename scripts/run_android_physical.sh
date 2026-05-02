#!/bin/bash
LIVE_MAPS_KEY=$(gcloud secrets versions access latest --secret="MAPS_API_KEY" --project="dbomar-post-mvp" 2>/dev/null)
cd frontend
flutter run -d 57130DLCQ0050R --dart-define=MAPS_API_KEY="$LIVE_MAPS_KEY" --dart-define=MAP_ID="1bf9740a3948b26976700a08" --dart-define=IOS_MAP_ID="1bf9740a3948b2695b963ae7"
