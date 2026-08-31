# Agent Rules — Post Spatial AR
Last updated: 2026-06-20

These rules exist to prevent regressions on hard-won fixes. Every agent working on this codebase must read and follow them.

---

## RULE 1: Never store GPS ellipsoidal altitude in post.altitude

**post.altitude is a terrain-relative offset in meters. It is NOT GPS/WGS-84 altitude.**

- Ground pin → post.altitude = 0.0
- Sky balloon → post.altitude = 15.0
- Never do: `post.altitude = _currentPose['altitude'] + offset`
- Never do: `post.altitude = geolocator.altitude + anything`

Why: In NY/LI area, GPS ellipsoidal altitude is -8m to -30m at ground level. Storing GPS altitude as post altitude causes pins to render underground and balloons to appear at near-ground level.

Fixed in: commit c87ec44 (2026-06-20)

---

## RULE 2: Never use addEarthAnchorNode for post rendering

addEarthAnchorNode takes absolute WGS-84 altitude. This is wrong for post rendering in most locations due to datum offsets. Always use resolveAnchorOnTerrainAsync with a terrain-relative offset.

- ✅ `arCoreController.resolveAnchorOnTerrainAsync(node, lat, lng, altitudeAboveTerrain)`
- ❌ `arCoreController.addEarthAnchorNode(node, lat, lng, gpsAltitude)`

The only valid use of addEarthAnchorNode would be if you have a verified orthometric (sea-level corrected) altitude from an external geoid model — which we do not.

---

## RULE 3: Always guard legacy negative altitudes

Posts created before 2026-06-20 have negative GPS altitudes stored (e.g. -9m, -27m). When rendering these posts, guard:

```dart
double altOffset = post.altitude;
if (altOffset < 0) {
  altOffset = post.postType == 'balloon' ? 15.0 : 0.0;
}
```

Do not remove this guard without first purging all pre-fix posts from Firestore.

---

## RULE 4: _renderPosts must be called on every VPS lock tick

Do not revert _renderPosts() to a one-shot call. Failed terrain anchors are removed from _renderedPostIds and must be retried on the next VPS tick. The _renderedPostIds set prevents duplicates — calling _renderPosts() repeatedly is safe.

---

## RULE 5: No hallucinations — verify before diagnosing

When diagnosing AR or location bugs:
1. Query Firestore first — check actual stored values
2. Extract video frames if screen recordings are available
3. Cross-reference stored values against visual observations
4. Only then propose a root cause

Do not propose build version issues, stale cache issues, or network issues without checking Firestore data first.

---

## RULE 6: Production logging gap — known issue

There is currently no real-time AR anchor logging. When users report AR issues:
1. Ask for labeled post captions so Firestore can be queried directly
2. Ask for screen recordings if available
3. Query posts collection by caption/timestamp to get ground truth

Adding an ar_logs Firestore collection is in the Sprint 8 backlog.

---

## RULE 7: CI/CD bot commit filter — do not remove

Xcode Cloud file path filter (frontend/lib/ and frontend/ios/) prevents CI bot commits (auto-bump, deploy timestamp) from triggering cascading iOS builds. Do not remove or widen this filter.

---

## RULE 8: Podfile.lock synchronization on dependency updates

Whenever Flutter dependencies (especially Firebase SDK, Google Maps, or native plugins) are updated in `pubspec.yaml`:
1. Always run `flutter pub get` and `cd frontend/ios && pod update <PodName>` (or `pod install --repo-update`) locally.
2. Verify and commit the resulting `frontend/ios/Podfile.lock`.
3. Xcode Cloud runs `pod install` in `ci_post_clone.sh` which strictly adheres to `Podfile.lock`. Out-of-sync snapshot constraints (e.g., `Firebase/CoreOnly` version mismatches) will fail the CI build immediately.

