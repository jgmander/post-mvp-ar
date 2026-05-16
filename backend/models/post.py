from pydantic import BaseModel, Field
from typing import Optional, Literal
from datetime import datetime, timedelta
class PostCreate(BaseModel):
    latitude: float
    longitude: float
    altitude: float
    caption: str
    creator_id: str
    owner_id: Optional[str] = None
    visibility_type: Literal["1-to-1", "1-to-many"]
    reach: int = Field(default=0, description="The intended reach distance or amount")
    place_name: Optional[str] = None
    place_category: Optional[str] = None
    expires_at: Optional[datetime] = Field(default_factory=lambda: datetime.utcnow() + timedelta(hours=24))
    is_flagged: bool = False

class PostResponse(PostCreate):
    id: str
    created_at: datetime
    unique_views: int = 0
    cta_text: Optional[str] = None
    cta_action: Optional[str] = None
    is_safe: bool = True
    expires_at: Optional[datetime] = None
    is_flagged: bool = False
