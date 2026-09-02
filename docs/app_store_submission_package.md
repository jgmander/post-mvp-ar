# Post Spatial — App Store & Google Play Submission Package
**Date:** September 1, 2026  
**Entity:** Post Spatial, LLC  

---

## 1. Apple App Store Submission Details

### App Information
* **App Name:** Post Spatial (or Post)
* **Subtitle:** Pin digital notes to the real world
* **Primary Category:** Navigation
* **Secondary Category:** Social Networking
* **Content Rating:** 12+ (Infrequent/Mild Realistic Violence, Location Sharing)

### URLs
* **Privacy Policy URL:** `https://dbomar-post-mvp.web.app/privacy.html`
* **Terms and Conditions URL:** `https://dbomar-post-mvp.web.app/terms.html`
* **Support URL:** `https://dbomar-post-mvp.web.app/support.html`
* **Marketing URL:** `https://dbomar-post-mvp.web.app`

### Description
> Post brings digital messaging into the physical world through precision Augmented Reality.
>
> Pin digital notes, memories, and announcements directly to real-world buildings, storefronts, and outdoor spaces using Google Visual Positioning System (VPS) geospatial technology.
>
> **Key Features:**
> • **Interactive 2D Spatial Map:** Browse nearby posts, clusters, and points of interest before you arrive.
> • **Precision Outdoor AR:** View notes floating on real-world buildings and surfaces with sub-meter spatial accuracy.
> • **Drop Ground Pins & Sky Balloons:** Anchor notes at ground level or high up in the sky.
> • **Directions & Real-World Navigation:** Tap any post to get turn-by-turn walking or driving directions.
> • **Smart Content Safety:** Built-in AI moderation and instant reporting tools keep real-world locations safe and respectful.

### Keywords
`augmented reality,AR,spatial notes,geotag,visual positioning,VPS,digital pins,location messaging,street view,navigation`

---

## 2. CRITICAL: App Review Information (For Apple Reviewers)

**Paste this exact text into the "Notes" field under App Review Information in App Store Connect to satisfy Guideline 2.1:**

```text
NOTE TO APP REVIEW TEAM:
Post is an outdoor geospatial Augmented Reality (AR) application built on Google Visual Positioning System (VPS / ARCore Geospatial).

1. OUTDOOR ENVIRONMENT REQUIREMENT:
The AR feature requires scanning outdoor building facades that are mapped in Google Street View to achieve a Visual Positioning System (VPS) localization lock. Indoor office environments typically lack recognizable street-facing facades.

2. DEMO VIDEO (PHYSICAL IOS DEVICE):
As requested under Guideline 2.1, we have recorded an unedited demonstration video showing the complete end-to-end workflow on a physical iPhone (Permission handling -> 2D Map navigation -> Outdoor 0.4m VPS visual lock -> Dropping a post on a building -> Tapping and interacting with a post).

Video Link: [INSERT UNLISTED YOUTUBE OR GOOGLE DRIVE LINK HERE]

3. INDOOR GRACEFUL TIMEOUT:
If tested indoors, the app displays scanning instructions and includes a 15-second graceful fallback dialog ("Spatial Features Limited") that smoothly guides users back to the 2D Map mode.

4. USER SIGN-IN:
The app supports immediate anonymous browsing and guest exploration without requiring credentials. Sign-in with Apple / Google is also available.
```

---

## 3. Extracted App Store Screenshots
The following direct, unedited UI screenshots have been extracted at native iPhone resolution (`1180 x 2556`) from our physical device testing:

1. `docs/app_store_assets/screenshots/01_map_view.png` — 2D Interactive Map with post cluster pins.
2. `docs/app_store_assets/screenshots/02_ar_camera_view.png` — Outdoor AR Camera view showing `0.4m` VPS accuracy and floating digital balloons/pins.
3. `docs/app_store_assets/screenshots/03_create_post_sheet.png` — Post Creation sheet with reverse geocoding and Ground Pin / Sky Balloon selector.
4. `docs/app_store_assets/screenshots/04_post_interaction.png` — AR post detail card with Get Directions and sharing controls.

---

## 4. Google Play Console Listing Details
* **App Title:** Post Spatial
* **Short Description:** Pin digital notes and memories to the real world in augmented reality.
* **Full Description:** (Same as App Store description above)
* **Target Audience:** 13+
* **Data Safety:** Accurate to Privacy Policy (`/privacy.html`) — Camera processed locally on device, Location used for AR pin placement and nearby discovery.
