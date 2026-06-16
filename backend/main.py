from fastapi import FastAPI, HTTPException
from models.post import PostCreate, PostResponse
from services.ai_service import analyze_post_content
from services.db_service import create_post, get_nearby_posts, increment_views
import uvicorn

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

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=True)
