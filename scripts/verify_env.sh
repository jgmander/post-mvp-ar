#!/bin/bash
echo "=== Zero-Drift Environment Verification ==="
echo "Current Directory: $(pwd)"
if [ -f .env ]; then
  echo "Environment variables found."
else
  echo "WARNING: .env file missing. Sourcing skipped."
fi
