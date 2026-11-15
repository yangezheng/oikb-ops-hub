"""Unit tests for the decision logic of the sync job (app/oikb_sync.py).

The rule under test: a run only counts as a success when the knowledge base
equals the repository, not when oikb merely exited 0.
"""

import importlib.util
import os
import unittest
from pathlib import Path

os.environ.setdefault("OPEN_WEBUI_URL", "http://example.invalid")
os.environ.setdefault("ADMIN_EMAIL", "admin@example.com")
os.environ.setdefault("ADMIN_PASSWORD", "x")

_spec = importlib.util.spec_from_file_location("oikb_sync", Path(__file__).parents[1] / "app" / "oikb_sync.py")
sync = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sync)


class PendingChanges(unittest.TestCase):
    def test_in_sync(self):
        self.assertFalse(sync.pending_changes("76 unchanged"))
        self.assertFalse(sync.pending_changes("nothing to do"))
        self.assertFalse(sync.pending_changes("76 unchanged, 5 dirs created"))

    def test_uploads_accepted_but_not_in_knowledge_base(self):
        # What oikb's diff says after Open WebUI failed to embed the uploads.
        self.assertTrue(sync.pending_changes("76 added"))

    def test_partial_drift(self):
        self.assertTrue(sync.pending_changes("2 modified, 74 unchanged"))
        self.assertTrue(sync.pending_changes("1 deleted, 75 unchanged"))

    def test_empty_summary_is_not_drift(self):
        # No summary at all is caught by the exit code, not by this function.
        self.assertFalse(sync.pending_changes(""))


class Helpers(unittest.TestCase):
    def test_last_line_skips_blank_lines(self):
        self.assertEqual(sync.last_line("  + a.py\n\n76 added\n\n"), "76 added")
        self.assertEqual(sync.last_line(""), "")
        self.assertEqual(sync.last_line(None), "")

    def test_find_knowledge_base_in_both_response_shapes(self):
        items = [{"id": "a", "name": "other"}, {"id": "b", "name": "oikb repository"}]
        self.assertEqual(sync.find_knowledge_base(items, "oikb repository"), "b")
        self.assertEqual(sync.find_knowledge_base({"items": items}, "oikb repository"), "b")

    def test_find_knowledge_base_missing(self):
        self.assertIsNone(sync.find_knowledge_base({"items": []}, "oikb repository"))
        self.assertIsNone(sync.find_knowledge_base(None, "oikb repository"))

    def test_marker_cannot_match_a_longer_instance_name(self):
        # monitoring.tf searches for 'OIKB_SYNC_OK instance=<id> ' with the
        # trailing space, so opco1 must not match opco10.
        line = "[sync] OIKB_SYNC_OK instance=aihub-opco10 source=x"
        self.assertNotIn("OIKB_SYNC_OK instance=aihub-opco1 ", line)


class GitHubCredentials(unittest.TestCase):
    def setUp(self):
        self._env = dict(os.environ)
        for key in ("GITHUB_APP_ID", "GITHUB_APP_INSTALLATION_ID", "GITHUB_APP_PRIVATE_KEY", "GITHUB_TOKEN"):
            os.environ.pop(key, None)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)

    def test_placeholder_none_counts_as_unset(self):
        # Key Vault cannot hold an empty secret, so Terraform writes "none".
        os.environ.update(GITHUB_TOKEN="none", GITHUB_APP_PRIVATE_KEY="none", GITHUB_APP_ID="1", GITHUB_APP_INSTALLATION_ID="2")
        self.assertEqual(sync.github_credentials(), (None, "anonymous"))

    def test_pat_when_no_app(self):
        os.environ.update(GITHUB_TOKEN="github_pat_x", GITHUB_APP_PRIVATE_KEY="none")
        self.assertEqual(sync.github_credentials(), ("github_pat_x", "pat"))

    def test_app_wins_over_pat(self):
        os.environ.update(GITHUB_TOKEN="github_pat_x", GITHUB_APP_ID="1", GITHUB_APP_INSTALLATION_ID="2", GITHUB_APP_PRIVATE_KEY="pem")
        original = sync.github_app_token
        sync.github_app_token = lambda app_id, inst, key: f"ghs_{app_id}_{inst}"
        try:
            self.assertEqual(sync.github_credentials(), ("ghs_1_2", "github-app"))
        finally:
            sync.github_app_token = original


try:
    import jwt  # noqa: F401
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    HAVE_JWT = True
except ImportError:  # the oikb image has both; a bare laptop may not
    HAVE_JWT = False


@unittest.skipUnless(HAVE_JWT, "PyJWT and cryptography not installed")
class GitHubAppJwt(unittest.TestCase):
    def test_jwt_is_rs256_and_within_github_limits(self):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        pem = key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
        ).decode()
        token = sync.github_app_jwt("123", pem, now=1_000_000)
        claims = jwt.decode(token, key.public_key(), algorithms=["RS256"], options={"verify_exp": False})
        self.assertEqual(claims["iss"], "123")
        self.assertLessEqual(claims["exp"] - claims["iat"], 600)  # GitHub rejects more than 10 minutes
        self.assertLess(claims["iat"], 1_000_000)  # back-dated against clock skew


class RuntimeTfvars(unittest.TestCase):
    """app/runtime_setup.py keeps values between runs through its tfvars file."""

    def test_round_trip_keeps_existing_values(self):
        import tempfile

        os.environ.setdefault("OPEN_WEBUI_URL", "http://example.invalid")
        spec = importlib.util.spec_from_file_location("runtime_setup", Path(__file__).parents[1] / "app" / "runtime_setup.py")
        setup = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(setup)

        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "opco1.runtime.tfvars")
            self.assertEqual(setup.read_tfvars(path), {})
            setup.write_tfvars(path, {"eval_user_id": "abc", "github_mcp_oauth_client_info": "gAAAA=="})
            self.assertEqual(setup.read_tfvars(path), {"eval_user_id": "abc", "github_mcp_oauth_client_info": "gAAAA=="})
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
