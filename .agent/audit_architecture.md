# Tech Stack — Post Spatial AR
Last updated: 2026-06-20

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
  - deploy-android.yml: triggers on frontend/** push (path filter excludes bot commits) → APK → Firebase App Distribution + AAB → Play Store internal track
  - deploy-backend.yml: triggers on backend/** push → Docker → GCR → Cloud Run
  - deploy-firebase.yml: triggers on firebase.json/firestore.*/website/** → Firestore + Hosting
- **iOS:** Xcode Cloud (App Store Connect) — handles provisioning/signing natively
  - Bridge: frontend/ios/ci_scripts/ci_post_clone.sh (installs Flutter, injects dart-defines, pod install)
  - Secrets: Xcode Cloud Environment Variables (MAPS_API_KEY, MAP_ID, IOS_MAP_ID)
  - File path filter: frontend/lib/ and frontend/ios/ — bot commits do NOT trigger iOS builds

## AR Anchor Architecture — CRITICAL
This section documents a hard-won lesson. Do not regress.

### Anchor type: resolveAnchorOnTerrainAsync (ARCore Geospatial API)
- Used for ALL post placement: both ground pins and sky balloons
- Signature: resolveAnchorOnTerrainAsync(node, latitude, longitude, altitudeAboveTerrain)
- `altitudeAboveTerrain` is METERS ABOVE THE TERRAIN SURFACE — NOT absolute WGS-84 altitude

### post.altitude field semantics (LOCKED — DO NOT CHANGE)
- Ground pin: post.altitude = 0.0 (terrain surface)
- Sky balloon: post.altitude = 15.0 (15 meters above terrain)
- This is a terrain-relative offset, NOT GPS/WGS-84 ellipsoidal altitude
- NEVER store _currentPose['altitude'] (raw GPS) into post.altitude
  → In NY/LI area, GPS ellipsoidal altitude is -8m to -30m at ground level
  → Storing GPS alt + 15m for balloons gives +6m absolute → renders at ground level in AR

### Why GPS altitude is wrong here
- WGS-84 ellipsoidal height vs. orthometric (sea-level) height differ by ~35m in NY/LI
- resolveAnchorOnTerrainAsync handles the terrain surface automatically — we only supply the offset
- addEarthAnchorNode uses absolute altitude — DO NOT use for post rendering

### Anchor failure handling
- If resolveAnchorOnTerrainAsync fails: remove post from _renderedPostIds, retry on next VPS tick
- Do NOT fall back to addEarthAnchorNode — it uses absolute GPS altitude → underground in NY
- Legacy posts with post.altitude < 0 (pre-2026-06-20): guard to 0.0 (pin) or 15.0 (balloon)

### VPS lock requirement
- Posts render only when _currentPose accuracy < 3.0m (VPS locked)
- _renderPosts() is called on every VPS lock tick (not one-shot) to enable retry of failed anchors
- _renderedPostIds set prevents duplicate renders; only failed (removed) posts retry

## Database/Routing Patterns
- Client read-only from Firestore (direct SDK for reads, streams)
- All write operations go through Cloud Run backend (authenticated)
- GeoHash fan-out for proximity queries (9-tile strategy)
- NoSQL collections: `posts`, `users`, `reports`
- posts.altitude = terrain-relative offset in meters (0.0 or 15.0) — see AR Anchor Architecture

## Key Secrets (Never in source control)
- MAPS_API_KEY — Google Cloud Secret Manager + GitHub Secrets + Xcode Cloud
- ANDROID_KEYSTORE_BASE64 — GitHub Secret (backup in .agent/secrets/, git-ignored)
- WIF_PROVIDER, SA_EMAIL — GitHub Secrets (Workload Identity)
- PLAY_STORE_SERVICE_ACCOUNT_JSON — GitHub Secret
- FIREBASE_APP_ID — GitHub Secret (Firebase App Distribution)

## App Identifiers
- Bundle ID (iOS): com.post.spatial
- Package Name (Android): com.post.spatial
- Play Store: Internal track, version code auto-incrementing via CI
- TestFlight: Build 61 (Founding Team + Founding Visionaries + Mander Family)
