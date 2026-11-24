# Post Spatial (`dbomar-post`) Workspace Rules

@[Post Spatial Agent Rules](.agent/agent_rules.md)

## GCP & Firebase Project Boundary
- Always target GCP / Firebase project `dbomar-post-mvp` (`com.post.spatial`, Apple App ID `6760303477`).

## CI/CD & Xcode Cloud Coexistence
- **Never push `[skip ci]` commits at the start of GitHub Actions:** Defer version-code and sprint-timestamp `[skip ci]` commits to the *end* (`if: success()`) of `.github/workflows/deploy-android.yml` so GitHub Actions never clobbers `main` HEAD before Xcode Cloud polls the push.
- **GitHub Actions path exclusions:** Never combine `paths:` and `paths-ignore:` on the same trigger; use negated globs (`'!frontend/ios/**'`, `'!frontend/macos/**'`) inside `paths:`.
- **Gradle Maven Central resilience:** Keep the GCS Maven Central mirror (`https://maven-central.storage-download.googleapis.com/maven2/`) and Gradle caching enabled in `deploy-android.yml` to avoid HTTP `429 Too Many Requests` on shared runners.
- **Release Notes Sync:** Always update both `frontend/release_notes.txt` (Android Firebase App Distribution) and `frontend/ios/TestFlight/WhatToTest.en-US.txt` (iOS Xcode Cloud TestFlight) when shipping user-facing changes.

## Brand & Visual Identity
- **Trademark-Distinct "Post" Mark:** Use Electric Post Blue (`#1A8CFF`) with crisp white vinyl trim and our custom **Post Folded-Note `P` Spatial Mark** (`PostBrandMark` / native vector stamp). Never use generic Google Maps or Apple Maps circular teardrop pins.
