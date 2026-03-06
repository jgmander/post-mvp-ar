#!/bin/bash

# Ensure gcloud is available
if ! command -v gcloud &> /dev/null
then
    echo "Google Cloud SDK (gcloud) is not installed. Please install it to fetch secrets."
    exit 1
fi

echo "🔐 Fetching MAPS_API_KEY from Google Cloud Secret Manager..."

# Fetch the secret
MAPS_API_KEY=\$(gcloud secrets versions access latest --secret="MAPS_API_KEY" --project="dbomar-post-mvp" 2>/dev/null)

if [ -z "\$MAPS_API_KEY" ]; then
    echo "❌ Failed to retrieve MAPS_API_KEY from Secret Manager. Are you logged in to gcloud?"
    exit 1
fi

echo "✅ MAPS_API_KEY retrieved securely."

echo "🚀 Starting Flutter with injected secrets..."

# Navigate to frontend if not already there
if [ -d "frontend" ]; then
    cd frontend
fi

# Run flutter passing the securely retrieved key
flutter run --dart-define=MAPS_API_KEY="\$MAPS_API_KEY"
