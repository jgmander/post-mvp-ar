# Tech Stack — Post Spatial AR
Last updated: 2026-06-16

## Frontend (Flutter)
- **Framework:** Flutter 3.41.9 stable
- **Platform:** iOS 14+ / Android 8.0+
- **Core AR:** `arcore_flutter_plugin` (custom native Swift/Kotlin bridge, local plugin at /plugins/arcore_flutter_plugin)
- **Maps:** `google_maps_flutter` + `google_maps_flutter_android` (vector renderer, latest)
- **Auth:** `firebase_auth` (anonymous + Google Sign-In + Apple Sign-In + email/password)
- **Database:** `cloud_firestore` (client read-only; all writes go through backend)
- **Location:** `geolocator`
- **Share:** `share_plus` (SharePlus.instance.share + ShareParams API)
- **Prefs:** `shared_preferences` (hidden posts, free post flag)
- **Moderation:** `services/moderation_service.dart` (hide locally + report to Firestore)

## Backend (Python FastAPI)
- **Runtime:** Python 3.11, FastAPI, Uvicorn
- **Deploy:** Google Cloud Run (us-central1, max-instances=3)
- **AI:** Google Gemini 1.5 Flash via `google-generativeai` (content screening on create + re-analysis on report)
- **Auth:** Firebase Admin SDK (token verification)
- **DB:** Firestore via `firebase_admin.firestore`
- **Rate Limiting:** In-memory per-UID dict (20 posts/hr per instance)
- **Key endpoints:** POST /posts (gated by Gemini), DELETE /posts/{id}, POST /report

## Firebase / GCP
- **Project:** dbomar-post-mvp
- **Firestore:** Production database, rules block all direct client writes
- **Firebase Hosting:** dbomar-post-mvp.web.app / get-post.co (pending domain)
  - /privacy.html
  - /delete-account (rewrite → delete-account.html) — Play Store required
  - /child-safety (rewrite → child-safety.html) — Play Store required
  - /support.html
- **Budget:** $20 alert at 50%/90%/100% (billingbudgets API)
- **Service Account:** ag-agent@dbomar-post-mvp.iam.gserviceaccount.com (agent ops)
- **WIF:** Workload Identity Federation for GitHub Actions → GCP (keyless auth)

## CI/CD
- **Android + Backend + Firebase:** GitHub Actions (3 workflows in .github/workflows/)
  - deploy-android.yml: triggers on frontend/** push → APK → Firebase App Distribution + AAB → Play Store internal track
  - deploy-backend.yml: triggers on backend/** push → Docker → GCR → Cloud Run
  - deploy-firebase.yml: triggers on firebase.json/firestore.*/website/** → Firestore + Hosting
- **iOS:** Xcode Cloud (App Store Connect) — handles provisioning/signing natively
  - Bridge: frontend/ios/ci_scripts/ci_post_clone.sh (installs Flutter, injects dart-defines, pod install)
  - Secrets: Xcode Cloud Environment Variables (MAPS_API_KEY, MAP_ID, IOS_MAP_ID)

## Database/Routing Patterns
- Client read-only from Firestore (direct SDK for reads, streams)
- All write operations go through Cloud Run backend (authenticated)
- GeoHash fan-out for proximity queries (9-tile strategy)
- NoSQL collections: `posts`, `users`, `reports`

## Key Secrets (Never in source control)
- MAPS_API_KEY — Google Cloud Secret Manager + GitHub Secrets + Xcode Cloud
- ANDROID_KEYSTORE_BASE64 — GitHub Secret (backup in .agent/secrets/, git-ignored)
- WIF_PROVIDER, SA_EMAIL — GitHub Secrets (Workload Identity)
- PLAY_STORE_SERVICE_ACCOUNT_JSON — GitHub Secret
- FIREBASE_APP_ID — GitHub Secret (Firebase App Distribution)

## App Identifiers
- Bundle ID (iOS): com.post.spatial
- Package Name (Android): com.post.spatial
- Play Store: Internal track initialized, v25 / 1.0.0
- TestFlight: Build 31 (Founding Team + Mander Family groups)
