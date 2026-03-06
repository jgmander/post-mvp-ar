from fastapi import FastAPI, HTTPException
from models.post import PostCreate, PostResponse
from services.ai_service import analyze_post_content
from services.db_service import create_post, get_nearby_posts, increment_views
import uvicorn

app = FastAPI(title="Post AR MVP Backend")

@app.get("/")
def read_root():
    return {"status": "ok", "service": "post-mvp-backend"}

@app.get("/v1/auth/config")
def get_auth_config():
    from services.secret_service import get_prod_keys
    keys = get_prod_keys()
    if "MAPS_API_KEY" not in keys:
        raise HTTPException(status_code=500, detail="Missing secure keys")
    # In a full app, this would be obfuscated or session-limited
    return {"maps_api_key": keys["MAPS_API_KEY"]}

@app.post("/posts", response_model=PostResponse)
def api_create_post(post: PostCreate):
    # 1. Analyze with AI
    analysis = analyze_post_content(post.message_content, post.place_name, post.place_category)
    
    if not analysis.get("is_safe", True):
        raise HTTPException(status_code=400, detail="Content flagged by safety moderation.")
        
    # 2. Add AI results to post data
    post_dict = post.dict()
    post_dict.update({
        "cta_text": analysis.get("cta_text"),
        "cta_action": analysis.get("cta_action"),
        "is_safe": True
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
