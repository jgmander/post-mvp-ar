import firebase_admin
from firebase_admin import credentials
from firebase_admin import firestore
import os

def migrate():
    print("Starting legacy schema migration...")
    
    # Initialize Firebase Admin SDK
    if not firebase_admin._apps:
        cred = credentials.ApplicationDefault()
        project_id = os.environ.get("GOOGLE_CLOUD_PROJECT", "dbomar-post-mvp")
        firebase_admin.initialize_app(cred, {
            'projectId': project_id,
        })
        
    db = firestore.client()
    posts_ref = db.collection('posts')
    docs = posts_ref.stream()
    
    migrated_count = 0
    total_count = 0
    
    for doc in docs:
        total_count += 1
        data = doc.to_dict()
        if 'is_flagged' not in data:
            doc.reference.update({'is_flagged': False})
            migrated_count += 1
            
    print(f"Migration complete!")
    print(f"Total documents scanned: {total_count}")
    print(f"Legacy documents migrated: {migrated_count}")

if __name__ == '__main__':
    migrate()
