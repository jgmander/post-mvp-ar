#!/bin/bash
LIVE_MAPS_KEY=$(gcloud secrets versions access latest --secret="MAPS_API_KEY" --project="dbomar-post-mvp" 2>/dev/null)
cd frontend
flutter run -d 57130DLCQ0050R --dart-define=MAPS_API_KEY="$LIVE_MAPS_KEY"
