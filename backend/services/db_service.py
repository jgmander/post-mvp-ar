import os
import re
import geohash
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional
from google.cloud import firestore
from google.cloud.firestore_v1.base_query import FieldFilter
from models.post import PERMANENT_EXPIRES_AT
from datetime import datetime, timedelta, timezone

_SAFE_DOC_ID_RE = re.compile(r"^[A-Za-z0-9_-]{6,48}$")

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


def _ensure_utc(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is None:
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _is_post_active(post: dict, now_utc: datetime) -> bool:
    if post.get("is_permanent") is True:
        return True
    exp = post.get("expires_at")
    if exp is None:
        return True
    if isinstance(exp, datetime):
        return _ensure_utc(exp) > now_utc
    if isinstance(exp, str):
        try:
            parsed = datetime.fromisoformat(exp.replace("Z", "+00:00"))
            return _ensure_utc(parsed) > now_utc
        except ValueError:
            return True
    return True


def get_existing_post_if_owned(client_post_id: Optional[str], caller_uid: str) -> Optional[dict]:
    """Returns an already-created post if client_post_id exists and belongs to caller_uid."""
    if not db or not client_post_id or not _SAFE_DOC_ID_RE.match(client_post_id):
        return None
    doc_ref = db.collection(COLLECTION_NAME).document(client_post_id)
    snap = doc_ref.get()
    if not snap.exists:
        return None
    data = snap.to_dict()
    if data.get("creator_id") == caller_uid or data.get("owner_id") == caller_uid:
        data["id"] = snap.id
        return data
    return None


def create_post(post_data: dict) -> dict:
    if not db:
        raise Exception("Firestore client not initialized")

    requested_id = post_data.pop("client_post_id", None)
    caller_uid = post_data.get("creator_id")
    if requested_id and _SAFE_DOC_ID_RE.match(requested_id):
        existing = get_existing_post_if_owned(requested_id, caller_uid)
        if existing is not None:
            return existing
        doc_ref = db.collection(COLLECTION_NAME).document(requested_id)
    else:
        doc_ref = db.collection(COLLECTION_NAME).document()

    lat = post_data.get("latitude", 0.0)
    lng = post_data.get("longitude", 0.0)
    post_data["geohash"] = geohash.encode(lat, lng, precision=GEOHASH_STORE_PRECISION)

    if post_data.get("is_permanent"):
        # Store far-future sentinel so v1.0 clients filtering `expires_at > now`
        # continue to see permanent posts with zero breaking changes.
        post_data["expires_at"] = PERMANENT_EXPIRES_AT
    else:
        exp = _ensure_utc(post_data.get("expires_at"))
        post_data["expires_at"] = exp or (datetime.now(timezone.utc) + timedelta(hours=24))

    full_data = {
        **post_data,
        "id": doc_ref.id,
        "created_at": datetime.now(timezone.utc),
        "unique_views": 0,
    }

    doc_ref.set(full_data)
    return full_data


def get_nearby_posts(
    lat: float,
    lng: float,
    radius_km: float = 1.0,
    include_expired: bool = False,
) -> list:
    """
    Queries Firestore using a GeoHash 9-tile bounding box strategy.
    Filters out expired posts in memory so no extra composite index is required.
    """
    if not db:
        raise Exception("Firestore client not initialized")

    center_hash = geohash.encode(lat, lng, precision=GEOHASH_QUERY_PRECISION)
    neighbors = geohash.neighbors(center_hash)
    hashes_to_query = [center_hash] + neighbors

    def query_tile(tile_hash: str) -> list:
        hash_end = tile_hash + "~"
        try:
            docs = (
                db.collection(COLLECTION_NAME)
                .where(filter=FieldFilter("is_flagged", "==", False))
                .where(filter=FieldFilter("geohash", ">=", tile_hash))
                .where(filter=FieldFilter("geohash", "<=", hash_end))
                .limit(50)
                .stream()
            )
            items = []
            for doc in docs:
                d = doc.to_dict()
                if "id" not in d or not d["id"]:
                    d["id"] = doc.id
                items.append(d)
            return items
        except Exception as e:
            print(f"GeoHash tile query failed for {tile_hash}: {e}")
            return []

    results = []
    seen_ids = set()
    now_utc = datetime.now(timezone.utc)

    with ThreadPoolExecutor(max_workers=9) as executor:
        futures = {executor.submit(query_tile, h): h for h in hashes_to_query}
        for future in as_completed(futures):
            for post in future.result():
                post_id = post.get("id")
                if post_id and post_id not in seen_ids:
                    if not include_expired and not _is_post_active(post, now_utc):
                        continue
                    seen_ids.add(post_id)
                    results.append(post)

    return results


def increment_views(post_id: str) -> bool:
    if not db:
        return False
    doc_ref = db.collection(COLLECTION_NAME).document(post_id)
    doc_ref.update({"unique_views": firestore.Increment(1)})
    return True


def update_post(
    post_id: str,
    caller_uid: str,
    updates: dict,
    claim_from_uid: Optional[str] = None,
):
    """
    Updates a post if owned by caller_uid (or recently created by claim_from_uid
    when upgrading an anonymous session to an existing Google/Apple account).
    Returns:
      None  — post not found
      False — caller does not own the post
      dict  — updated post dictionary
    """
    if not db:
        raise Exception("Firestore client not initialized")

    doc_ref = db.collection(COLLECTION_NAME).document(post_id)
    doc = doc_ref.get()
    if not doc.exists:
        return None

    data = doc.to_dict()
    owner_id = data.get("owner_id") or data.get("creator_id")

    is_owner = owner_id == caller_uid or data.get("creator_id") == caller_uid
    is_valid_claim = False
    if not is_owner and claim_from_uid and (
        owner_id == claim_from_uid or data.get("creator_id") == claim_from_uid
    ):
        created_at = _ensure_utc(data.get("created_at"))
        if created_at and (datetime.now(timezone.utc) - created_at) <= timedelta(hours=2):
            is_valid_claim = True

    if not is_owner and not is_valid_claim:
        return False

    patch = {}
    if is_valid_claim:
        patch["owner_id"] = caller_uid

    if "caption" in updates and updates["caption"] is not None:
        patch["caption"] = updates["caption"]
    if "cta_text" in updates:
        patch["cta_text"] = updates["cta_text"]
    if "cta_action" in updates:
        patch["cta_action"] = updates["cta_action"]
    if "action_url" in updates and updates["action_url"] is not None:
        patch["action_url"] = updates["action_url"]

    if updates.get("is_permanent") is True:
        patch["is_permanent"] = True
        patch["expires_at"] = PERMANENT_EXPIRES_AT
    elif updates.get("is_permanent") is False:
        patch["is_permanent"] = False
        exp = _ensure_utc(updates.get("expires_at"))
        patch["expires_at"] = exp or (datetime.now(timezone.utc) + timedelta(hours=24))
    elif "expires_at" in updates and updates["expires_at"] is not None:
        patch["expires_at"] = _ensure_utc(updates["expires_at"])

    if patch:
        doc_ref.update(patch)
        data.update(patch)

    data["id"] = doc.id
    return data


def delete_post(post_id: str, caller_uid: str):
    """
    Deletes a post if it exists and belongs to the caller.
    Returns:
      None  — post not found
      False — caller does not own the post
      True  — deleted successfully
    """
    if not db:
        raise Exception("Firestore client not initialized")
    doc_ref = db.collection(COLLECTION_NAME).document(post_id)
    doc = doc_ref.get()
    if not doc.exists:
        return None
    data = doc.to_dict()
    owner_id = data.get("owner_id") or data.get("creator_id")
    if owner_id != caller_uid and data.get("creator_id") != caller_uid:
        return False
    doc_ref.delete()
    return True


def delete_user_posts(caller_uid: str) -> int:
    """Deletes all posts owned or created by caller_uid (used on Account Deletion)."""
    if not db:
        raise Exception("Firestore client not initialized")

    deleted_ids = set()
    for field in ("owner_id", "creator_id"):
        docs = db.collection(COLLECTION_NAME).where(field, "==", caller_uid).stream()
        for doc in docs:
            if doc.id not in deleted_ids:
                doc.reference.delete()
                deleted_ids.add(doc.id)
    return len(deleted_ids)
