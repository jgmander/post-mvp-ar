#!/bin/bash
echo "=== Zero-Drift Environment Verification ==="
echo "Current Directory: $(pwd)"
export LIVE_MAPS_KEY=$(gcloud secrets versions access latest --secret="MAPS_API_KEY" 2>/dev/null)
export MAP_ID=$(gcloud secrets versions access latest --secret="MAP_ID" 2>/dev/null)
export IOS_MAP_ID=$(gcloud secrets versions access latest --secret="IOS_MAP_ID" 2>/dev/null)

if [ -z "$LIVE_MAPS_KEY" ] || [ -z "$MAP_ID" ] || [ -z "$IOS_MAP_ID" ]; then
  echo "WARNING: Failed to fetch all secrets (MAPS_API_KEY, MAP_ID, IOS_MAP_ID)."
else
  echo "Successfully fetched MAPS_API_KEY and set Map IDs."
fi

if [ -f .env ]; then
  echo "Environment variables found."
else
  echo "WARNING: .env file missing. Sourcing skipped."
fi
