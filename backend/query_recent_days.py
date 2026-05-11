import os
from google.cloud import firestore
import json
from datetime import datetime, timedelta, timezone

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "dbomar-post-mvp")
db = firestore.Client(project=PROJECT_ID)

# last 7 days
recent_start = datetime.now(timezone.utc) - timedelta(days=7)

docs = db.collection("posts").where("created_at", ">=", recent_start).order_by("created_at", direction=firestore.Query.DESCENDING).stream()

print("RECENT POSTS (FULL DUMP):")
count = 0
for doc in docs:
    d = doc.to_dict()
    print(json.dumps(d, default=str, indent=2))
    print("-" * 40)
    count += 1

if count == 0:
    print("No posts found in the last 7 days.")
else:
    print(f"Total posts: {count}")
