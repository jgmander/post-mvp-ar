import os
import geohash2
from concurrent.futures import ThreadPoolExecutor, as_completed
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

# GeoHash precision levels:
#   precision=5 → ~4.9km x 4.9km cell (good for neighborhood queries)
#   precision=7 → ~153m x 153m cell (good for precise post placement)
GEOHASH_STORE_PRECISION = 7   # Written on each post document
GEOHASH_QUERY_PRECISION = 5   # Used to build the 9-tile bounding box

def create_post(post_data: dict) -> dict:
    if not db:
        raise Exception("Firestore client not initialized")

    # Encode geohash at high precision for the stored document
    lat = post_data.get("latitude", 0.0)
    lng = post_data.get("longitude", 0.0)
    post_data["geohash"] = geohash2.encode(lat, lng, precision=GEOHASH_STORE_PRECISION)

    doc_ref = db.collection(COLLECTION_NAME).document()

    full_data = {
        **post_data,
        "id": doc_ref.id,
        "created_at": datetime.now(timezone.utc),
        "unique_views": 0,
    }

    doc_ref.set(full_data)
    return full_data


def get_nearby_posts(lat: float, lng: float, radius_km: float = 1.0) -> list:
    """
    Queries Firestore using a GeoHash 9-tile bounding box strategy.

    Instead of fetching 100 posts globally and filtering on the client,
    we compute the user's GeoHash cell at precision=5 (~4.9km), add all
    8 neighboring tiles, and run one query per tile (max 9 queries) in
    parallel. This bounds the read cost to posts near the user regardless
    of total database size — O(neighborhood) not O(planet).
    """
    if not db:
        raise Exception("Firestore client not initialized")

    center_hash = geohash2.encode(lat, lng, precision=GEOHASH_QUERY_PRECISION)
    neighbors = geohash2.neighbors(center_hash)
    hashes_to_query = [center_hash] + list(neighbors.values())

    def query_tile(tile_hash: str) -> list:
        """Query all non-flagged posts in a single GeoHash tile."""
        # GeoHash range query: all hashes with this prefix fall within the tile.
        # Appending '~' (ASCII 126, highest printable char) captures the full prefix range.
        hash_end = tile_hash + "~"
        try:
            docs = (
                db.collection(COLLECTION_NAME)
                .where("is_flagged", "==", False)
                .where("geohash", ">=", tile_hash)
                .where("geohash", "<=", hash_end)
                .limit(50)
                .stream()
            )
            return [doc.to_dict() for doc in docs]
        except Exception as e:
            print(f"GeoHash tile query failed for {tile_hash}: {e}")
            return []

    results = []
    seen_ids = set()

    # Fan-out: run all 9 tile queries in parallel
    with ThreadPoolExecutor(max_workers=9) as executor:
        futures = {executor.submit(query_tile, h): h for h in hashes_to_query}
        for future in as_completed(futures):
            for post in future.result():
                post_id = post.get("id")
                if post_id and post_id not in seen_ids:
                    seen_ids.add(post_id)
                    results.append(post)

    return results


def increment_views(post_id: str) -> bool:
    if not db:
        return False
    doc_ref = db.collection(COLLECTION_NAME).document(post_id)
    doc_ref.update({"unique_views": firestore.Increment(1)})
    return True
