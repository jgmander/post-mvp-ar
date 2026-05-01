# Tech Stack
- Frontend: Flutter (iOS/Android mobile targeting)
- Core APIs: ARCore Geospatial API, Google Maps SDK
- Backend/Cloud: Python FastAPI (deployed via Google Cloud Run)
- Database: Firestore NoSQL No-Schema

# Key Dependencies
- `arcore_flutter_plugin` (Custom native Swift/Kotlin bridged code)
- `google_maps_flutter` 
- `pydantic`, `firebase_admin` (Python backend)

# Database/Routing Patterns
- Client routing is handled natively via Flutter Progressive views.
- Backend routing follows FastAPI structural patterns under `backend/main.py`.
- NoSQL operations run directly against Firestore collections (e.g. `posts`).
