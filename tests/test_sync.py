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


if __name__ == "__main__":
    unittest.main()
