import os
from google.cloud import firestore
import json

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "dbomar-post-mvp")
db = firestore.Client(project=PROJECT_ID)

docs = db.collection("posts").stream()

print("ALL POSTS INVOLVING DUSTIN:")
found = False
for doc in docs:
    d = doc.to_dict()
    d_str = json.dumps(d, default=str)
    if "dustin" in d_str.lower():
        found = True
        print(f"ID: {d.get('id', doc.id)}")
        print(d)
        print("-" * 20)

if not found:
    print("No posts found involving Dustin in the entire database.")
