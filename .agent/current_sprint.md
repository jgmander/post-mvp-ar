# SPRINT 8 / LAUNCH SPRINT — Store Submission & MVP Launch
Last updated: 2026-08-31

## Sprint Goal
Finalize remaining administrative tasks, store listings/screenshots, and submit Post Spatial AR to the Apple App Store and Google Play Store for public production release.

## Status: IN PROGRESS (Final Administrative & Store Submission Phase)

## Completed Features & Technical Foundation
- [x] **AR Geospatial & Altitude Fixes:** Pinned terrain-relative offsets (ground pin: 0.0m, sky balloon: 15.0m) via `resolveAnchorOnTerrainAsync` to eliminate NY/LI datum drift and underground rendering.
- [x] **Cross-Device Real-Time Sync:** Replaced polling with Firestore real-time listener (geohash 9-tile + expires_at index) for immediate cross-platform visibility.
- [x] **VPS Precision & Retry Mechanism:** Dynamic retry loop on VPS lock ticks (2.5m threshold) to handle difficult lighting and initial lock delay.
- [x] **Full-Stack Dependency & CI Hygiene:** Updated Flutter & Firebase plugins (`firebase_core 4.11.0`, `wakelock_plus 1.6.1`, etc.) and synchronized `frontend/ios/Podfile.lock`.
- [x] **Automated Android CI/CD:** GitHub Actions pipeline auto-bumping version codes on every deploy to Firebase App Distribution + Google Play internal track (current: `1.0.0+40`).
- [x] **iOS Xcode Cloud Bridge:** `ci_post_clone.sh` automated build pipeline with headless secrets injection (`--dart-define`) and synchronized CocoaPods.
- [x] **Compliance & Moderation:** Gemini AI content screening, report endpoints, Delete Account and Child Safety hosting pages deployed with clean URL rewrites.
- [x] **Maps & Places Integration:** Places API (50m radius POI) and Geocoding active on GCP project `dbomar-post-mvp`.

## Current Version Codes
- Android: `1.0.0+40` (Production AAB on Google Play Internal Track)
- iOS: TestFlight Build (managed via Xcode Cloud)

## Pending for Public Launch (Administrative & Store Listings)
- [ ] **Apple App Store Review Package (CRITICAL — resolves Guideline 2.1 & 2.3.3):**
  - **Reviewer Demo Video Link:** Host a 1–2 min physical iOS screen recording (YouTube Unlisted / Google Drive) showing full flow: permission prompts -> 2D Map -> Outdoor VPS AR scan & lock -> Dropping an AR pin -> Viewing posts.
  - **App Review Notes:** Insert explanation that Post is an outdoor AR app requiring physical building facades with Google Street View coverage, with the demo video URL.
  - **Real UI Screenshots:** Pure device UI captures (iPhone 6.7"/6.5" and iPad 13" if enabled) without stylized promotional borders.
  - **Review Account / Sign-In:** Clarify anonymous/guest mode or provide test credentials.
- [ ] **Google Play Console (Android):** Finalize Target Audience declaration, upload live screenshots, and promote from Internal Track (`1.0.0+40`) to Production review.
- [ ] **Custom Domain & Email:** Install `get-post.co` / `spatial-labs.net` and forward `safety@get-post.co` / `report@get-post.co` -> `jgmander@gmail.com`.
- [ ] **Final Smoke Test:** Walkthrough verification on iOS and Android devices in outdoor VPS-enabled area.


## Fast-Follow / Backlog Ideas (Post-Launch)
- [ ] **Dynamic & Editable Posts (Restaurant / Local Merchant Use Case):**
  - Ability for post creators/merchants to update their post text (e.g. live wait times, daily specials) without deleting/re-anchoring.
  - Interactive Action Links: Clickable buttons/links on AR cards to join waitlists, open menus, call venue, or open external web apps.
- [ ] **AR Anchor Real-Time Logging (`ar_logs` collection):** Telemetry for field diagnostics.
## Deployment History
Last Android deploy: 2026-06-18 03:06 UTC — commit 89fc502a0cb3a715fe30ad09d439f3930adf91bf ✅
Last Android deploy: 2026-06-18 16:11 UTC — commit 9908dbfecb47ea17f908e7d90b5a57c6f0006b11 ✅
Last Android deploy: 2026-06-20 14:03 UTC — commit c87ec44a29f73370b0184a0362b85c330eb67401 ✅
Last Android deploy: 2026-06-23 20:36 UTC — commit 7ced1954a3056ee1a8b41ab9f6b1579d56bf7357 ✅
Last Android deploy: 2026-06-24 03:36 UTC — commit d783a73d81c360810be883fa46288a141d3bc437 ✅
Last Android deploy: 2026-06-25 00:21 UTC — commit 5bd219c2645afe546b6b1d0ee467208352c3da8e ✅
Last Android deploy: 2026-06-25 01:49 UTC — commit c85de9786fefc2adc7295d7d354044e5f18ea910 ✅
