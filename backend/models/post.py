from pydantic import BaseModel, Field
from typing import Optional, Literal
from datetime import datetime, timedelta, timezone

PERMANENT_EXPIRES_AT = datetime(2099, 12, 31, 0, 0, 0, tzinfo=timezone.utc)


def _default_expires_at() -> datetime:
    return datetime.now(timezone.utc) + timedelta(hours=24)


class PostCreate(BaseModel):
    latitude: float
    longitude: float
    altitude: float
    post_type: str = "pin"
    caption: str
    creator_id: str
    owner_id: Optional[str] = None
    visibility_type: Literal["1-to-1", "1-to-many"]
    reach: int = Field(default=0, description="The intended reach distance or amount")
    place_name: Optional[str] = None
    place_category: Optional[str] = None
    expires_at: Optional[datetime] = Field(default_factory=_default_expires_at)
    is_permanent: bool = False
    anchor_surface: Optional[str] = None
    action_url: Optional[str] = None
    is_flagged: bool = False


class PostUpdate(BaseModel):
    caption: Optional[str] = None
    is_permanent: Optional[bool] = None
    expires_at: Optional[datetime] = None
    action_url: Optional[str] = None
    claim_from_uid: Optional[str] = None


class PostResponse(PostCreate):
    id: str
    created_at: datetime
    unique_views: int = 0
    cta_text: Optional[str] = None
    cta_action: Optional[str] = None
    is_safe: bool = True
    expires_at: Optional[datetime] = None
    is_permanent: bool = False
    is_flagged: bool = False
