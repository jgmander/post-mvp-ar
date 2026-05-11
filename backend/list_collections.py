import os
from google.cloud import firestore

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "dbomar-post-mvp")
db = firestore.Client(project=PROJECT_ID)

collections = db.collections()
for col in collections:
    print(f"Collection: {col.id}")
