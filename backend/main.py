from fastapi import FastAPI, HTTPException, Header
from models.post import PostCreate, PostResponse
from services.ai_service import analyze_post_content
from services.db_service import create_post, get_nearby_posts, increment_views, delete_post
import firebase_admin
from firebase_admin import auth as firebase_auth, credentials
import uvicorn

# Initialize Firebase Admin SDK (uses Application Default Credentials on Cloud Run)
if not firebase_admin._apps:
    firebase_admin.initialize_app()

app = FastAPI(title="Post AR MVP Backend")

@app.get("/")
def read_root():
    return {"status": "ok", "service": "post-mvp-backend"}



def moderate_content(caption: str) -> bool:
    """
    Stub for Gemini AI moderation pipeline.
    Returns True if flagged, False otherwise.
    """
    caption_lower = caption.lower()
    if "test_nsfw" in caption_lower or "profanity_stub" in caption_lower:
        return True
    return False

@app.post("/posts", response_model=PostResponse)
def api_create_post(post: PostCreate):
    # 1. Analyze with AI
    analysis = analyze_post_content(post.caption, post.place_name, post.place_category)
    
    if not analysis.get("is_safe", True):
        # We still flag it and commit, just log or you could raise
        pass
        
    # 2. Add AI results to post data
    post_dict = post.dict()
    is_flagged = moderate_content(post.caption)
    
    # Check original safety too
    if not analysis.get("is_safe", True):
        is_flagged = True
        
    post_dict.update({
        "cta_text": analysis.get("cta_text"),
        "cta_action": analysis.get("cta_action"),
        "is_safe": analysis.get("is_safe", True),
        "is_flagged": is_flagged
    })
    
    # 3. Save to database
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

@app.delete("/posts/{post_id}")
def api_delete_post(post_id: str, authorization: str = Header(None)):
    """Authenticated delete. Validates Firebase ID token and confirms ownership."""
    # 1. Extract and verify the Firebase ID token
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
    id_token = authorization.split(" ", 1)[1]
    try:
        decoded = firebase_auth.verify_id_token(id_token)
        caller_uid = decoded["uid"]
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid or expired Firebase ID token")

    # 2. Confirm the caller owns this post
    success = delete_post(post_id=post_id, caller_uid=caller_uid)
    if success is None:
        raise HTTPException(status_code=404, detail="Post not found")
    if success is False:
        raise HTTPException(status_code=403, detail="You do not own this post")
    return {"status": "deleted"}

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=True)
