import os
from google.cloud import firestore
import json

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "dbomar-post-mvp")
db = firestore.Client(project=PROJECT_ID)

docs = db.collection("posts").order_by("created_at", direction=firestore.Query.DESCENDING).limit(100).stream()

print("POSTS INVOLVING DUSTIN:")
found = False
for doc in docs:
    d = doc.to_dict()
    d_str = json.dumps(d, default=str)
    if "dustin" in d_str.lower():
        found = True
        print(f"ID: {d.get('id', doc.id)}")
        print(f"Author: {d.get('author_name', d.get('author', d.get('user', 'N/A')))}")
        print(f"Content: {d.get('text', d.get('caption', d.get('content', 'N/A')))}")
        print(f"Created At: {d.get('created_at')}")
        print("-" * 20)

if not found:
    print("No posts found involving Dustin in the last 100 posts.")
