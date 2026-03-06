from pydantic import BaseModel, Field
from typing import Optional, Literal
from datetime import datetime

class PostCreate(BaseModel):
    latitude: float
    longitude: float
    altitude: float
    message_content: str
    creator_id: str
    visibility_type: Literal["1-to-1", "1-to-many"]
    reach: int = Field(default=0, description="The intended reach distance or amount")

class PostResponse(PostCreate):
    id: str
    created_at: datetime
    unique_views: int = 0
    cta_text: Optional[str] = None
    cta_action: Optional[str] = None
    is_safe: bool = True
