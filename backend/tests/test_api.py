import sys
import os
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

# Ensure backend directory is importable
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

# Mock firebase_admin and google.cloud.firestore before importing main
mock_fb_admin = MagicMock()
mock_fb_admin._apps = {"default": True}
sys.modules.setdefault("firebase_admin", mock_fb_admin)
sys.modules.setdefault("firebase_admin.auth", MagicMock())
sys.modules.setdefault("firebase_admin.credentials", MagicMock())
sys.modules.setdefault("firebase_admin.firestore", MagicMock())
try:
    import geohash as _gh  # noqa: F401
except ImportError:
    _mock_gh = MagicMock()
    _mock_gh.encode.side_effect = lambda lat, lng, precision=7: "9q5c1ab"[:precision]
    _mock_gh.neighbors.return_value = ["9q5c0", "9q5c2"]
    sys.modules["geohash"] = _mock_gh

from models.post import PERMANENT_EXPIRES_AT, PostCreate, PostUpdate
import services.db_service as db_service
import main


class FakeDocRef:
    def __init__(self, store: dict, doc_id: str):
        self._store = store
        self.id = doc_id
        self.reference = self

    def set(self, data: dict):
        self._store[self.id] = dict(data)

    def get(self):
        snap = MagicMock()
        if self.id in self._store:
            snap.exists = True
            snap.id = self.id
            snap.to_dict.return_value = dict(self._store[self.id])
        else:
            snap.exists = False
        return snap

    def update(self, patch_data: dict):
        self._store[self.id].update(patch_data)

    def delete(self):
        self._store.pop(self.id, None)


class FakeCollection:
    def __init__(self, store: dict):
        self._store = store
        self._counter = 0

    def document(self, doc_id: str = None):
        if doc_id is None:
            self._counter += 1
            doc_id = f"doc_{self._counter}"
        return FakeDocRef(self._store, doc_id)

    def where(self, field: str, op: str, val):
        query = MagicMock()

        def _stream():
            out = []
            for doc_id, data in list(self._store.items()):
                if op == "==" and data.get(field) == val:
                    snap = MagicMock()
                    snap.id = doc_id
                    snap.reference = FakeDocRef(self._store, doc_id)
                    snap.to_dict.return_value = dict(data)
                    out.append(snap)
            return out

        query.stream.side_effect = _stream
        return query


class FakeFirestoreDB:
    def __init__(self):
        self.store = {}
        self.col = FakeCollection(self.store)

    def collection(self, name: str):
        return self.col


class BackendUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.fake_db = FakeFirestoreDB()
        db_service.db = self.fake_db
        main._post_timestamps.clear()

    def test_v1_legacy_payload_compatibility(self):
        """v1.0 clients omit is_permanent and anchor_surface; defaults must hold."""
        payload = PostCreate(
            latitude=33.9761,
            longitude=-118.4168,
            altitude=0.0,
            post_type="pin",
            caption="cauliflower tacos!!",
            creator_id="client_uid",
            visibility_type="1-to-many",
        )
        self.assertFalse(payload.is_permanent)
        self.assertIsNone(payload.anchor_surface)

        with patch("main._verify_token", return_value="verified_uid"), patch(
            "main.analyze_post_content",
            return_value={"is_safe": True, "cta_text": "View Menu", "cta_action": "directions"},
        ):
            saved = main.api_create_post(payload, authorization="Bearer token")

        self.assertEqual(saved["owner_id"], "verified_uid")
        self.assertEqual(saved["creator_id"], "verified_uid")
        self.assertFalse(saved["is_permanent"])
        self.assertLess(saved["expires_at"], PERMANENT_EXPIRES_AT)

    def test_permanent_post_sets_2099_sentinel_for_v1_query_compatibility(self):
        """Permanent posts must set expires_at = 2099-12-31 so v1.0 expires_at > now still matches."""
        payload = PostCreate(
            latitude=33.9761,
            longitude=-118.4164,
            altitude=1.5,
            post_type="pin",
            caption="ask for Tommy",
            creator_id="dustin_uid",
            visibility_type="1-to-many",
            is_permanent=True,
            anchor_surface="building",
        )
        with patch("main._verify_token", return_value="dustin_uid"), patch(
            "main.analyze_post_content",
            return_value={"is_safe": True, "cta_text": None, "cta_action": "none"},
        ):
            saved = main.api_create_post(payload, authorization="Bearer token")

        self.assertTrue(saved["is_permanent"])
        self.assertEqual(saved["expires_at"], PERMANENT_EXPIRES_AT)
        self.assertEqual(saved["anchor_surface"], "building")

    def test_anonymous_post_claim_upgrades_owner_and_permanence(self):
        """When an anonymous user signs into an existing Google/Apple account, claiming upgrades the post."""
        created = db_service.create_post({
            "latitude": 33.9765,
            "longitude": -118.4171,
            "altitude": 15.0,
            "post_type": "balloon",
            "caption": "hidden playground!",
            "creator_id": "anon_uid_123",
            "owner_id": "anon_uid_123",
            "visibility_type": "1-to-many",
            "is_permanent": False,
        })
        post_id = created["id"]

        with patch("main._verify_token", return_value="google_uid_999"):
            updated = main.api_update_post(
                post_id=post_id,
                payload=PostUpdate(is_permanent=True, claim_from_uid="anon_uid_123"),
                authorization="Bearer token",
            )

        self.assertEqual(updated["owner_id"], "google_uid_999")
        self.assertTrue(updated["is_permanent"])
        self.assertEqual(updated["expires_at"], PERMANENT_EXPIRES_AT)

    def test_unauthorized_update_rejected(self):
        created = db_service.create_post({
            "latitude": 33.9765,
            "longitude": -118.4171,
            "altitude": 1.5,
            "post_type": "pin",
            "caption": "original",
            "creator_id": "owner_a",
            "owner_id": "owner_a",
            "visibility_type": "1-to-many",
        })
        with patch("main._verify_token", return_value="attacker_b"), patch(
            "main.analyze_post_content",
            return_value={"is_safe": True, "cta_text": None, "cta_action": "none"},
        ):
            with self.assertRaises(main.HTTPException) as ctx:
                main.api_update_post(
                    post_id=created["id"],
                    payload=PostUpdate(caption="hijacked"),
                    authorization="Bearer token",
                )
            self.assertEqual(ctx.exception.status_code, 403)

    def test_active_vs_expired_filtering_and_account_delete_cleanup(self):
        now = datetime.now(timezone.utc)
        expired_post = {"expires_at": now - timedelta(hours=1), "is_permanent": False}
        perm_post = {"expires_at": now - timedelta(hours=1), "is_permanent": True}
        live_post = {"expires_at": now + timedelta(hours=5), "is_permanent": False}

        self.assertFalse(db_service._is_post_active(expired_post, now))
        self.assertTrue(db_service._is_post_active(perm_post, now))
        self.assertTrue(db_service._is_post_active(live_post, now))

        db_service.create_post({
            "latitude": 33.97, "longitude": -118.41, "altitude": 0.0,
            "caption": "mine 1", "creator_id": "u1", "owner_id": "u1",
            "visibility_type": "1-to-many",
        })
        db_service.create_post({
            "latitude": 33.97, "longitude": -118.41, "altitude": 0.0,
            "caption": "other", "creator_id": "u2", "owner_id": "u2",
            "visibility_type": "1-to-many",
        })
        with patch("main._verify_token", return_value="u1"):
            res = main.api_delete_my_posts(authorization="Bearer token")
        self.assertEqual(res["count"], 1)
        self.assertEqual(len(self.fake_db.store), 1)

    def test_client_post_id_idempotent_retry(self):
        """Retrying POST /posts with the same client_post_id returns the existing post without duplicating."""
        payload = PostCreate(
            client_post_id="post_1732380000_abcd1234",
            latitude=40.7154,
            longitude=-73.7033,
            altitude=15.0,
            post_type="balloon",
            caption="balloon anchor spot test",
            creator_id="jason_uid",
            visibility_type="1-to-many",
            is_permanent=True,
        )
        with patch("main._verify_token", return_value="jason_uid"), patch(
            "main.analyze_post_content",
            return_value={"is_safe": True, "cta_text": "Walk Here", "cta_action": "directions"},
        ) as mock_ai:
            first = main.api_create_post(payload, authorization="Bearer token")
            second = main.api_create_post(payload, authorization="Bearer token")

        self.assertEqual(first["id"], "post_1732380000_abcd1234")
        self.assertEqual(second["id"], "post_1732380000_abcd1234")
        self.assertEqual(len(self.fake_db.store), 1)
        self.assertEqual(mock_ai.call_count, 1)


if __name__ == "__main__":
    unittest.main()
