SPRINT 7 — Play Store Production Submission
Last updated: 2026-06-16

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

## Pending This Sprint
- [ ] GitHub Actions build green (deploy-android.yml triggered by b76a218 push)
- [ ] Xcode Cloud build green (iOS, check App Store Connect)
- [ ] App Store Connect: submit Build 31 to App Review
- [ ] Play Console: complete store listing (text ready, need live screenshots after features confirmed)
- [ ] Email forward: safety@get-post.co → jgmander@gmail.com (do when custom domain installed)
- [ ] Play Console: Target Audience declaration
- [ ] Play Console: Submit for review

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
