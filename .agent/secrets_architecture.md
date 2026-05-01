# Secrets Architecture: Zero-Drift Pipeline

This document defines the exact structural methodology for persisting and hydrating Google Cloud API keys across the local development environment and the native ARCore compilation phase.

## Storage Protocol
- **Location:** The primary API key (e.g., `MAPS_API_KEY`) is stored locally inside the git-ignored `frontend/android/local.properties` file.
- **Security Constraint:** This file must *never* be committed to source control. It remains physically bound to the local developer machine or injected exclusively via CI/CD Secret Managers.

## Gradle Hydration Pipeline
- **Extraction:** During the `assembleDebug` or `assembleRelease` tasks, `frontend/android/app/build.gradle.kts` parses `local.properties` or accepts variables via the `--dart-define=MAPS_API_KEY` CLI arguments.
- **Hydration:** The extracted value is assigned to a Gradle variable (`mapsApiKey`).
- **Manifest Injection:** Gradle uses the `manifestPlaceholders` map to inject this value directly into the `AndroidManifest.xml` during the final APK compilation.

## Android Manifest Binding
Both Google Maps and ARCore tracking services rely on the exact same underlying secret. The `AndroidManifest.xml` exposes dynamic bindings using the exact syntax:
- `<meta-data android:name="com.google.android.geo.API_KEY" android:value="\${MAPS_API_KEY}" />`
- `<meta-data android:name="com.google.ar.core.API_KEY" android:value="\${MAPS_API_KEY}" />`

This ensures that the sensitive API key strings never physically exist inside the raw XML file in the source repository.
