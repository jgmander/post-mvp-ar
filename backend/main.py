from fastapi import FastAPI, HTTPException, Header
from models.post import PostCreate, PostResponse, PostUpdate
from services.ai_service import analyze_post_content
from services.db_service import (
    create_post,
    get_nearby_posts,
    increment_views,
    update_post,
    delete_post,
    delete_user_posts,
)
import firebase_admin
from firebase_admin import auth as firebase_auth, firestore as fb_firestore
import uvicorn
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import threading

# ── Firebase Admin ─────────────────────────────────────────────────────────────
if not firebase_admin._apps:
    firebase_admin.initialize_app()

app = FastAPI(title="Post AR MVP Backend")

# ── Per-UID In-Memory Rate Limiter ─────────────────────────────────────────────
MAX_POSTS_PER_HOUR = 20
_rate_lock = threading.Lock()
_post_timestamps: dict = defaultdict(list)


def _check_rate_limit(uid: str) -> bool:
    """Returns True if UID is within the hourly post limit."""
    now = datetime.now(timezone.utc)
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
    uid = _verify_token(authorization)

    if not _check_rate_limit(uid):
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded. Max {MAX_POSTS_PER_HOUR} posts per hour.",
        )

    caption = post.caption[:500] if post.caption else ""

    analysis = analyze_post_content(caption, post.place_name, post.place_category)
    if not analysis.get("is_safe", True):
        raise HTTPException(
            status_code=422,
            detail="Post content did not pass safety review.",
        )

    post_dict = post.model_dump() if hasattr(post, "model_dump") else post.dict()
    post_dict["caption"] = caption
    post_dict.update({
        "creator_id": uid,
        "owner_id": uid,
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
def api_get_posts(
    lat: float = 0.0,
    lng: float = 0.0,
    radius_km: float = 1.0,
    include_expired: bool = False,
):
    try:
        posts = get_nearby_posts(
            lat=lat,
            lng=lng,
            radius_km=radius_km,
            include_expired=include_expired,
        )
        return posts
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.patch("/posts/{post_id}", response_model=PostResponse)
def api_update_post(
    post_id: str,
    payload: PostUpdate,
    authorization: str = Header(None),
):
    """
    Authenticated update for post caption, TTL/permanence, or anonymous-to-signed-in claim.
    Re-runs Gemini safety screening whenever caption text is modified.
    """
    caller_uid = _verify_token(authorization)

    updates: dict = {}
    if payload.caption is not None:
        trimmed = payload.caption.strip()[:500]
        if not trimmed:
            raise HTTPException(status_code=400, detail="Caption cannot be empty")
        analysis = analyze_post_content(trimmed)
        if not analysis.get("is_safe", True):
            raise HTTPException(
                status_code=422,
                detail="Updated post content did not pass safety review.",
            )
        updates["caption"] = trimmed
        updates["cta_text"] = analysis.get("cta_text")
        updates["cta_action"] = analysis.get("cta_action")

    if payload.is_permanent is not None:
        updates["is_permanent"] = payload.is_permanent
    if payload.expires_at is not None:
        updates["expires_at"] = payload.expires_at
    if payload.action_url is not None:
        updates["action_url"] = payload.action_url

    updated = update_post(
        post_id=post_id,
        caller_uid=caller_uid,
        updates=updates,
        claim_from_uid=payload.claim_from_uid,
    )
    if updated is None:
        raise HTTPException(status_code=404, detail="Post not found")
    if updated is False:
        raise HTTPException(status_code=403, detail="You do not own this post")
    return updated


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

    post_ref = db.collection("posts").document(post_id)
    post_snap = post_ref.get()
    if not post_snap.exists:
        raise HTTPException(status_code=404, detail="Post not found")

    post_data = post_snap.to_dict()
    caption = post_data.get("caption", post_data.get("message_content", ""))

    analysis = analyze_post_content(caption)
    confirmed_unsafe = not analysis.get("is_safe", True)

    report_doc = {
        "postId": post_id,
        "reporterId": reporter_uid,
        "reason": "user_reported",
        "timestamp": fb_firestore.SERVER_TIMESTAMP,
        "geminiVerified": confirmed_unsafe,
        "status": "auto_removed" if confirmed_unsafe else "pending",
    }
    db.collection("reports").add(report_doc)

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


@app.delete("/users/me/posts")
def api_delete_my_posts(authorization: str = Header(None)):
    """Deletes all posts owned by the caller prior to Account Deletion."""
    caller_uid = _verify_token(authorization)
    deleted_count = delete_user_posts(caller_uid=caller_uid)
    return {"status": "deleted", "count": deleted_count}


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=True)
