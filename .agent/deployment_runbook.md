# Deployment Runbook & CI/CD Architecture

This document serves as the permanent architectural record for the Post AR MVP deployment pipeline. It ensures zero context loss regarding how the application is built, signed, and distributed across platforms.

## Core Security Principle: Zero-Drift & Headless Secrets
All API keys and secrets (e.g., `MAPS_API_KEY`) are injected dynamically at build time. They are NEVER stored in local `.env` files. We rely on Dart's `String.fromEnvironment()` to securely compile these secrets directly into the binary.

---

## 1. iOS: Xcode Cloud Architecture

Apple's Xcode Cloud is used exclusively for iOS builds to automatically handle Developer Certificates and Provisioning Profiles, bypassing the traditional Fastlane/match nightmares.

### The Flutter Bridge (`ci_post_clone.sh`)
Because Xcode Cloud does not natively support Flutter, we intercept the build sequence using a custom script located at `frontend/ios/ci_scripts/ci_post_clone.sh`.

**Execution Flow:**
1. Clones the pinned Flutter SDK (e.g., 3.41.9).
2. Runs `flutter precache --ios` to download engine artifacts.
3. Runs `flutter build ios --release --no-codesign --config-only` while injecting secrets via `--dart-define`. This generates the `Generated.xcconfig` file.
4. Runs `pod install` to resolve native dependencies.
5. Hands execution back to Xcode to perform the native Archive and App Store Connect signing.

### Secret Injection
Secrets are added to the Xcode Cloud UI under the **Environment** tab as "Secret" variables. The bash script passes them to Flutter:
`--dart-define=MAPS_API_KEY=$MAPS_API_KEY`

---

## 2. Android: GitHub Actions (`deploy-android.yml`)
Because Android keystores are highly sensitive, they are completely excluded from the git repository.

### Keystore Automation
The production keystore was generated autonomously and securely using a "Base64 Injection" approach:
1. `upload-keystore.jks` was generated locally in the `.agent/secrets/` directory (which is safely git-ignored).
2. The keystore was converted to a Base64 string and piped directly into the GitHub Secret `ANDROID_KEYSTORE_BASE64` using the `gh` CLI.
3. The passwords (`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`) and `ANDROID_KEY_ALIAS` were injected into GitHub Secrets.

**Local Backup:** A backup of the `upload-keystore.jks` and its `key.properties` passwords exists locally in `.agent/secrets/` for recovery purposes. **Do NOT commit this folder.**

### Build & Distribution Flow
1. The GitHub Action decodes the Base64 secret back into a temporary `.jks` file living only in the runner's ephemeral `/tmp` memory.
2. The passwords are injected into the Gradle build via environment variables (`System.getenv`).
3. App secrets (`MAPS_API_KEY`, etc.) are injected via Flutter `--dart-define` arguments.
4. The signed APK is built and automatically uploaded to Firebase App Distribution via the Firebase CLI (using WIF authentication).

---

## 3. Firebase Infrastructure: GitHub Actions (`deploy-firebase.yml`)

We deploy Firestore Rules and Indexes automatically when they change, doing so securely without exposing long-lived Service Account keys.

### Authentication Strategy (Workload Identity Federation)
We leverage Google Cloud Workload Identity Federation (WIF). 
1. The GitHub Action requests a short-lived OIDC token from GitHub.
2. It trades that token with GCP (using the `WIF_PROVIDER` secret) for temporary access to the service account (`SA_EMAIL`).
3. The Firebase CLI natively supports these Application Default Credentials to deploy without any login prompts or downloaded JSON keys.

This is Google's absolute highest security recommendation for CI/CD.
