#!/bin/bash
EXPECTED_PROJECT="dbomar-post-mvp"
CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null)

if [ "$CURRENT_PROJECT" != "$EXPECTED_PROJECT" ]; then
    echo "FATAL ERROR: gcloud project mismatch! Pre-flight check failed."
    echo "Expected: $EXPECTED_PROJECT"
    echo "Actual:   $CURRENT_PROJECT"
    exit 1
fi

echo "Project ID verified: $EXPECTED_PROJECT. Proceeding."
