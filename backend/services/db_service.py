import os
from google.cloud import firestore
from models.post import PostCreate, PostResponse
from datetime import datetime, timezone

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "dbomar-post-mvp")

try:
    db = firestore.Client(project=PROJECT_ID)
except Exception as e:
    print(f"Failed to initialize Firestore: {e}")
    db = None

COLLECTION_NAME = "posts"

def create_post(post_data: dict) -> dict:
    if not db:
        raise Exception("Firestore client not initialized")
    
    # post_data includes the AI analysis results
    doc_ref = db.collection(COLLECTION_NAME).document()
    
    full_data = {
        **post_data,
        "id": doc_ref.id,
        "created_at": datetime.now(timezone.utc),
        "unique_views": 0
    }
    
    # Avoid pushing datetime object directly, use timestamp or string
    save_data = full_data.copy()
    
    doc_ref.set(save_data)
    return full_data

def get_nearby_posts(lat: float, lng: float, radius_km: float = 1.0) -> list:
    if not db:
         raise Exception("Firestore client not initialized")
    
    # For a true MVP with Geospatial queries, Firestore doesn't have native geographic bounding boxes
    # out of the box without GeoHashes. For simplicity in the MVP, we will fetch recent posts.
    # In a production environment, we'd use geofire or BigQuery GIS.
    
    docs = db.collection(COLLECTION_NAME).order_by("created_at", direction=firestore.Query.DESCENDING).limit(100).stream()
    
    # We will let the client filter out things that are too far away for the MVP.
    results = []
    for doc in docs:
        d = doc.to_dict()
        results.append(d)
        
    return results

def increment_views(post_id: str) -> bool:
     if not db:
         return False
     doc_ref = db.collection(COLLECTION_NAME).document(post_id)
     doc_ref.update({"unique_views": firestore.Increment(1)})
     return True
