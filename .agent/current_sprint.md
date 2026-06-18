SPRINT 7 — Play Store Production Submission
Last updated: 2026-06-17

## Sprint Goal
Complete Google Play Store production submission and all Phase 2 features before taking real screenshots for final store listing.

## Status: IN PROGRESS

## Completed This Sprint
- [x] Play Console App Content declarations (Data Safety, Content Rating, Child Safety, Advertising ID)
- [x] Delete Account in-app button (map_screen.dart profile sheet)
- [x] Share buttons — AR tap dialog + Map property sheet (using SharePlus.instance.share)
- [x] child-safety.html deployed at https://dbomar-post-mvp.web.app/child-safety
- [x] delete-account.html deployed at https://dbomar-post-mvp.web.app/delete-account
- [x] firebase.json rewrites for both clean URLs
- [x] Gemini AI moderation (content screening on post create + re-analysis on report)
- [x] Per-UID rate limiting (20 posts/hr in-memory)
- [x] Cloud Run max-instances=3 cost cap
- [x] $20 GCP budget alert (50%/90%/100% thresholds)
- [x] Backend /report endpoint with auto-delete
- [x] ModerationService (hide/report) in ArView + MapScreen
- [x] CRITICAL BUG FIX: createPost missing Authorization header (all POST /posts returning 401)
- [x] Missing Firestore composite index: is_flagged + geohash (GeoHash tile 400 errors fixed)
- [x] Gemini SDK migration: vertexai.generative_models → google-genai (deadline: June 24 2026)
- [x] Places API + Geocoding API enabled on GCP project (place_name was "Unknown Location" for all posts)
- [x] Places API search radius: 15m → 50m (better POI coverage in open areas)
- [x] CI/CD: Auto-bump version code on every Android deploy (no more manual pubspec.yaml bumps)
- [x] CI/CD: Node.js 24 opt-in across all 3 workflows
- [x] CI/CD: track → tracks deprecation fix in upload-google-play action
- [x] CI/CD: Deploy timestamp stamp to current_sprint.md on successful deploy

## Current Version Codes
- Android: 1.0.0+28 (auto-incrementing from now on via CI)
- iOS: Build 31 (TestFlight — needs new Xcode Cloud build for latest features)

## Pending This Sprint
- [ ] **URGENT: AR anchor regression** — Dustin reports balloon placed at office appeared 0.5mi away
  and same balloon later showed up outside his house. Also: iPhone not showing posts that Android sees.
  Investigate ar_view.dart anchor placement, GPS coordinate storage, and cross-platform post visibility.
- [ ] Xcode Cloud: trigger new iOS build with all June 17 fixes (auth header, Gemini SDK, Places API)
- [ ] App Store Connect: submit to App Review (Build 31 or newer)
- [ ] Play Console: complete store listing (need live screenshots on device)
- [ ] Play Console: Target Audience declaration
- [ ] Play Console: Submit for review
- [ ] Email forward: safety@get-post.co → jgmander@gmail.com (do when custom domain installed)
- [ ] **HIGH PRIORITY: Comprehensive test suite** (triggered by 2026-06-17 prod outage)
  - Layer 1: test/services/api_service_test.dart — mock http.Client, assert auth headers
  - Layer 2: backend/tests/test_posts.py — pytest + httpx.AsyncClient
  - Layer 3: presubmit.yml CI gate — flutter test + pytest block deploy
  - Layer 4: flutter test in ci_post_clone.sh to gate Xcode Cloud builds

## Sprint 6.3 Summary (Previous)
Completed:
- Native crash/memory leak fixes (ArCoreViewIOS.swift, AppDelegate.swift, MainActivity.kt)
- Security & billing protection (Firestore rules, removed /v1/auth/config)
- GeoHash scalability on Firestore
- Full CI/CD: GitHub Actions (3 workflows) + Xcode Cloud
- TestFlight Build 31 (Founding Team + Mander Family)
- Firebase App Distribution (Android internal)
- Play Store internal track initialized (v25 / 1.0.0)
- RBAC admin dashboard
- Map boot architecture overhaul (zero-latency, reactive location streaming)
- Peer review by Gemini Deep Research
Last Android deploy: 2026-06-18 03:06 UTC — commit 89fc502a0cb3a715fe30ad09d439f3930adf91bf ✅
