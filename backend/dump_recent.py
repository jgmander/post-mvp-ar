import os
from google.cloud import firestore
import json

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "dbomar-post-mvp")
db = firestore.Client(project=PROJECT_ID)

docs = db.collection("posts").order_by("created_at", direction=firestore.Query.DESCENDING).limit(5).stream()

print("RECENT POSTS (FULL DUMP):")
for doc in docs:
    d = doc.to_dict()
    print(json.dumps(d, default=str, indent=2))
    print("-" * 40)
