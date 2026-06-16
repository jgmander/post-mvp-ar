# Post Spatial — Frontend

Flutter application for **Post Spatial AR** — drop notes on real buildings using ARCore Geospatial VPS.

## Architecture

| Layer | Tech |
|---|---|
| Framework | Flutter 3.41.9 stable |
| AR | ARCore Geospatial API + StreetscapeGeometry (via custom `arcore_flutter_plugin`) |
| Maps | Google Maps Flutter (vector renderer, 3D buildings) |
| Auth | Firebase Auth (anonymous → Google / Apple / email upgrade) |
| Database | Cloud Firestore (client read-only via SDK; all writes through backend) |
| Backend | Python FastAPI on Cloud Run (GeoHash proximity, Gemini moderation, rate limiting) |

## Project Structure

```
lib/
├── config/
│   └── env_config.dart          # --dart-define validation (fails loudly if missing keys)
├── models/
│   ├── post.dart                # Post data model
│   └── user_profile.dart        # User profile model
├── screens/
│   ├── map_screen.dart          # Main map view + property sheets + profile + auth
│   ├── ar_reveal_screen.dart    # AR camera screen
│   └── admin_dashboard.dart     # RBAC admin panel
├── services/
│   ├── api_service.dart         # Cloud Run backend client (singleton)
│   ├── auth_service.dart        # Firebase Auth (sign in/out/delete account)
│   └── moderation_service.dart  # Hide (SharedPreferences) + Report (Firestore)
├── ui/
│   ├── ar_view.dart             # ARCore session, VPS lock, anchor placement, post tap
│   ├── ar_onboarding_overlay.dart
│   ├── create_post_view.dart    # Post creation form
│   └── progressive_view.dart    # Multi-stage location-aware view
└── widgets/
    └── auth_collision_sheet.dart # Handles account merge / collision flows
```

## Running Locally (Development)

> ⚠️ **SOP:** All production builds go through GitHub Actions (Android) and Xcode Cloud (iOS). Do not use `flutter build` to verify — push to `main` and check CI.

For local development with real keys:

```bash
LIVE_MAPS_KEY=$(gcloud secrets versions access latest \
  --secret="MAPS_API_KEY" \
  --project="dbomar-post-mvp" \
  --impersonate-service-account=ag-agent@dbomar-post-mvp.iam.gserviceaccount.com)

# Android
flutter run -d <android-device-id> \
  --dart-define=MAPS_API_KEY="$LIVE_MAPS_KEY" \
  --dart-define=MAP_ID="1bf9740a3948b26976700a08"

# iOS
flutter run -d <ios-device-id> \
  --dart-define=MAPS_API_KEY="$LIVE_MAPS_KEY" \
  --dart-define=IOS_MAP_ID="1bf9740a3948b2695b963ae7" \
  --dart-define=MAP_ID="1bf9740a3948b26976700a08"
```

## Key Environment Variables (--dart-define)

| Variable | Used By |
|---|---|
| `MAPS_API_KEY` | Google Maps, ARCore Geospatial, iOS ARCore session |
| `MAP_ID` | Android map cloud styling |
| `IOS_MAP_ID` | iOS map cloud styling |

These are injected at build time — never stored in source control.

## CI/CD

- **Android:** `deploy-android.yml` triggers on `frontend/**` push → signed APK (Firebase App Distribution) + signed AAB (Play Store internal track)
- **iOS:** Xcode Cloud triggers on push → TestFlight (Build 31+)

## App Identifiers

- Bundle ID: `com.post.spatial`
- Play Store Package: `com.post.spatial`
- Min SDK: Android 8.0 (API 26), iOS 14.0
