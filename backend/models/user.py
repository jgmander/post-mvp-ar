from pydantic import BaseModel, Field
from typing import Optional

class UserProfile(BaseModel):
    uid: str
    email: str
    role: str = Field(default="user", description="User role, e.g., 'user' or 'admin'")
    tier: str = Field(default="free", description="Subscription tier, e.g., 'free' or 'premium'")
