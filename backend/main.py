from fastapi import FastAPI, HTTPException, Header
from models.post import PostCreate, PostResponse
from services.ai_service import analyze_post_content
from services.db_service import create_post, get_nearby_posts, increment_views, delete_post
import firebase_admin
from firebase_admin import auth as firebase_auth, credentials, firestore as fb_firestore
import uvicorn
from collections import defaultdict
from datetime import datetime, timedelta
import threading

# ── Firebase Admin ─────────────────────────────────────────────────────────────
if not firebase_admin._apps:
    firebase_admin.initialize_app()

app = FastAPI(title="Post AR MVP Backend")

# ── Per-UID In-Memory Rate Limiter ─────────────────────────────────────────────
# Caps post creation to MAX_POSTS_PER_HOUR per authenticated user.
# Resets automatically as timestamps age out.
# Note: across Cloud Run instances this is per-instance. With max=3 instances
# the effective limit is 3× — acceptable for MVP. Use Firestore counters for
# strict global limiting.
MAX_POSTS_PER_HOUR = 20
_rate_lock = threading.Lock()
_post_timestamps: dict = defaultdict(list)

def _check_rate_limit(uid: str) -> bool:
    """Returns True if UID is within the hourly post limit."""
    now = datetime.utcnow()
    cutoff = now - timedelta(hours=1)
    with _rate_lock:
        _post_timestamps[uid] = [t for t in _post_timestamps[uid] if t > cutoff]
        if len(_post_timestamps[uid]) >= MAX_POSTS_PER_HOUR:
            return False
        _post_timestamps[uid].append(now)
        return True

# ── Auth helper ────────────────────────────────────────────────────────────────
def _verify_token(authorization: str | None) -> str:
    """Verifies a Firebase Bearer token and returns the caller UID."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
    id_token = authorization.split(" ", 1)[1]
    try:
        decoded = firebase_auth.verify_id_token(id_token)
        return decoded["uid"]
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid or expired Firebase ID token")

# ── Routes ─────────────────────────────────────────────────────────────────────

@app.get("/")
def read_root():
    return {"status": "ok", "service": "post-mvp-backend"}


@app.post("/posts", response_model=PostResponse)
def api_create_post(post: PostCreate, authorization: str = Header(None)):
    """
    Create a post. Requires Firebase auth token.
    Content is screened by Gemini 2.5 Flash before storage.
    Unsafe content returns 422. Rate-limited to 20 posts/hr per UID.
    """
    # 1. Auth
    uid = _verify_token(authorization)

    # 2. Rate limit
    if not _check_rate_limit(uid):
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded. Max {MAX_POSTS_PER_HOUR} posts per hour."
        )

    # 3. Content length cap (protects Gemini token costs)
    caption = post.caption[:500] if post.caption else ""

    # 4. Gemini moderation — block unsafe content before storage
    analysis = analyze_post_content(caption, post.place_name, post.place_category)
    if not analysis.get("is_safe", True):
        raise HTTPException(
            status_code=422,
            detail="Post content did not pass safety review."
        )

    # 5. Build and save post
    post_dict = post.dict()
    post_dict["caption"] = caption          # use truncated version
    post_dict.update({
        "creator_id": uid,
        "cta_text": analysis.get("cta_text"),
        "cta_action": analysis.get("cta_action"),
        "is_safe": True,
        "is_flagged": False,
    })

    try:
        saved_post = create_post(post_dict)
        return saved_post
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/posts")
def api_get_posts(lat: float = 0.0, lng: float = 0.0, radius_km: float = 1.0):
    try:
        posts = get_nearby_posts(lat=lat, lng=lng, radius_km=radius_km)
        return posts
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/posts/{post_id}/view")
def api_view_post(post_id: str):
    success = increment_views(post_id)
    if success:
        return {"status": "success"}
    raise HTTPException(status_code=500, detail="Failed to update view count")


@app.post("/posts/{post_id}/report")
def api_report_post(post_id: str, authorization: str = Header(None)):
    """
    User-flagged report. Requires Firebase auth.
    Gemini re-analyzes the post content:
      - Confirmed unsafe → post auto-deleted, report status = 'auto_removed'
      - Ambiguous        → report filed for manual review, status = 'pending'
    """
    reporter_uid = _verify_token(authorization)

    db = fb_firestore.client()

    # 1. Fetch the post
    post_ref = db.collection("posts").document(post_id)
    post_snap = post_ref.get()
    if not post_snap.exists:
        raise HTTPException(status_code=404, detail="Post not found")

    post_data = post_snap.to_dict()
    caption = post_data.get("caption", post_data.get("message_content", ""))

    # 2. Re-analyze with Gemini
    analysis = analyze_post_content(caption)
    confirmed_unsafe = not analysis.get("is_safe", True)

    # 3. Write report document
    report_doc = {
        "postId": post_id,
        "reporterId": reporter_uid,
        "reason": "user_reported",
        "timestamp": fb_firestore.SERVER_TIMESTAMP,
        "geminiVerified": confirmed_unsafe,
        "status": "auto_removed" if confirmed_unsafe else "pending",
    }
    db.collection("reports").add(report_doc)

    # 4. Auto-delete if Gemini confirms the violation
    if confirmed_unsafe:
        post_ref.delete()
        return {"status": "removed", "detail": "Post removed after safety review."}

    return {"status": "reported", "detail": "Report filed for manual review."}


@app.delete("/posts/{post_id}")
def api_delete_post(post_id: str, authorization: str = Header(None)):
    """Authenticated delete. Validates Firebase ID token and confirms ownership."""
    caller_uid = _verify_token(authorization)

    success = delete_post(post_id=post_id, caller_uid=caller_uid)
    if success is None:
        raise HTTPException(status_code=404, detail="Post not found")
    if success is False:
        raise HTTPException(status_code=403, detail="You do not own this post")
    return {"status": "deleted"}


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=True)
