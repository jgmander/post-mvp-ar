import os
import json
from google.cloud import secretmanager

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "dbomar-post-mvp")

# In-memory cache
_secrets_cache = None

def get_prod_keys() -> dict:
    global _secrets_cache
    if _secrets_cache is not None:
        return _secrets_cache
        
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{PROJECT_ID}/secrets/POST_AR_PROD_KEYS/versions/latest"
    
    try:
        response = client.access_secret_version(request={"name": name})
        payload = response.payload.data.decode("UTF-8")
        _secrets_cache = json.loads(payload)
        return _secrets_cache
    except Exception as e:
        print(f"Failed to load secrets: {e}")
        return {}
