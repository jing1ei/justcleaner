"""Offline regression tests for version-driven, immutable publication."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

sys_path = __import__("sys")
sys_path.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location(
    "release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

VERSION = "1.2.3"
PROJECT = "Fixture"


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = {"project": PROJECT, "notes": "Fixture release"}
        self.source = self.root / "dist"
        self.source.mkdir()
        self.names = release.asset_names(PROJECT, VERSION)
        for name in self.names:
            (self.source / name).write_bytes(name.encode())
        (self.source / "SHA256SUMS.txt").write_text("".join(
            f"{hashlib.sha256(name.encode()).hexdigest()}  {name}\n"
            for name in self.names))
        self.calls = []
        # GitHub state
        self.existing = False
        self.published = False
        self.same_commit = True
        self.tag_exists = False
        self.uploaded = set()
        # Stable, collision-free asset ids for every possible upload.
        self.asset_ids = {}

    def _id_for(self, name):
        if name not in self.asset_ids:
            self.asset_ids[name] = 1000 + len(self.asset_ids)
        return self.asset_ids[name]

    def ready(self):
        return release.prepare(self.source, self.root / "release-ready",
                               self.config, VERSION)

    # ---- helpers modelling gh ----
    def api(self, endpoint, method="GET", payload=None):
        self.calls.append(("api", method, endpoint, payload))
        if endpoint.endswith("/releases?per_page=100"):
            if not self.existing:
                return []
            return [{"id": 7, "tag_name": "v" + VERSION, "draft": not self.published,
                     "target_commitish": "built" if self.same_commit else "other"}]
        if "/matching-refs/tags/" in endpoint:
            return [{"ref": "refs/tags/v" + VERSION,
                     "object": {"sha": "built" if self.same_commit else "older"}}] \
                if self.tag_exists else []
        if "/assets?" in endpoint:
            return [{"name": n, "id": self._id_for(n)} for n in self.uploaded]
        return {"id": 9, "draft": True}

    def gh(self, *args):
        self.calls.append(("gh",) + args)
        if args[:2] == ("release", "upload"):
            # tuple: gh release upload <tag> --repo r --clobber <paths...>
            self.uploaded = {Path(a).name for a in args[6:]}
        return ""

    def gh_bytes(self, endpoint):
        asset_id = int(endpoint.rsplit("/", 1)[1])
        for name in self.names + ["SHA256SUMS.txt"]:
            if self._id_for(name) == asset_id:
                return (self.root / "release-ready" / name).read_bytes()
        raise AssertionError(f"unexpected asset download {endpoint}")

    def publish(self, corrupt=False):
        directory = self.ready()
        def fake_bytes(endpoint):
            return b"corrupt-bytes" if corrupt else self.gh_bytes(endpoint)
        with patch.object(release, "api", self.api), \
             patch.object(release, "pages", lambda e: self.api(e)), \
             patch.object(release, "gh", self.gh), \
             patch.object(release, "gh_bytes", fake_bytes):
            release.publish(directory, self.config, VERSION, "built", "owner/repo")

    # ---- prepare ----
    def test_required_names_are_version_driven(self):
        self.assertEqual(self.names, [
            f"{PROJECT}-{VERSION}-source.zip",
            f"{PROJECT}-{VERSION}-macOS-arm64.dmg",
            f"{PROJECT}-{VERSION}-macOS-x64.dmg"])

    def test_prepare_copies_and_checksums(self):
        directory = self.ready()
        got = {p.name for p in directory.iterdir()}
        self.assertEqual(got, set(self.names) | {"SHA256SUMS.txt"})
        for name in self.names:
            line = next(l for l in (directory / "SHA256SUMS.txt").read_text().splitlines()
                        if l.endswith(name))
            self.assertEqual(line.split("  ")[0],
                             hashlib.sha256(name.encode()).hexdigest())

    def test_missing_package_stops_prepare(self):
        (self.source / self.names[0]).unlink()
        with self.assertRaises(ValueError):
            self.ready()
        self.assertFalse((self.root / "release-ready").exists())

    def test_checksum_mismatch_stops_prepare(self):
        (self.source / self.names[0]).write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            self.ready()

    def test_missing_build_manifest_stops_prepare(self):
        (self.source / "SHA256SUMS.txt").unlink()
        with self.assertRaises(ValueError):
            self.ready()

    def test_empty_package_rejected(self):
        (self.source / self.names[1]).write_bytes(b"")
        with self.assertRaises(ValueError):
            self.ready()

    # ---- publish ----
    def test_creates_release_as_draft_then_publishes_and_tags(self):
        self.publish()
        methods = [(c[1], c[2], c[3]) for c in self.calls
                   if c and c[0] == "api"]
        create = next(p for m, e, p in methods
                      if m == "POST" and e.endswith("/releases"))
        self.assertTrue(create["draft"])
        self.assertEqual(create["tag_name"], "v" + VERSION)
        self.assertEqual(create["target_commitish"], "built")
        self.assertTrue(any(m == "POST" and e.endswith("/git/refs")
                            and p["sha"] == "built" for m, e, p in methods))
        final = next(p for m, e, p in methods
                     if m == "PATCH" and "/releases/9" in e)
        self.assertFalse(final["draft"])
        self.assertEqual(final["make_latest"], "true")

    def test_assets_uploaded_are_exactly_expected(self):
        self.publish()
        upload = next(a for a in self.calls if a[:2] == ("gh", "release"))
        wanted = set(self.names + ["SHA256SUMS.txt"])
        sent = sorted(Path(x).name for x in upload if Path(x).name in wanted)
        self.assertEqual(sent, sorted(wanted))

    def test_tag_force_move_never_happens(self):
        self.tag_exists = True
        self.same_commit = True
        self.existing = True
        self.published = True
        # idempotent: already published at the same commit -> no writes at all
        self.calls.clear()
        self.publish()
        self.assertFalse(any(c[0] == "api" and c[1] in ("POST", "PATCH")
                             for c in self.calls))

    def test_published_tag_at_other_commit_is_refused(self):
        self.existing = True
        self.published = True
        self.same_commit = False
        with self.assertRaisesRegex(ValueError, "bump the version"):
            self.publish()

    def test_draft_tag_mismatch_refuses_to_move_tag(self):
        self.existing = True
        self.published = False   # a stale draft
        self.tag_exists = True
        self.same_commit = False
        with self.assertRaisesRegex(ValueError, "bump the version"):
            self.publish()

    def test_uploaded_checksum_mismatch_never_publishes(self):
        with self.assertRaises(ValueError):
            self.publish(corrupt=True)
        methods = [(m, e, p) for c in self.calls
                   if len(c) == 4 and c[0] == "api"
                   for m, e, p in [(c[1], c[2], c[3])]]
        # No tag is created and the release is never moved out of draft.
        self.assertFalse(any(m == "POST" and e.endswith("/git/refs")
                             for m, e, p in methods))
        self.assertFalse(any(m == "PATCH" and e.endswith("/releases/9")
                             and p.get("draft") is False
                             for m, e, p in methods))

    # ---- environment gating ----
    def env(self, **over):
        base = {"GITHUB_SHA": "built", "GITHUB_REPOSITORY": "o/r",
                "GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "push",
                "JC_VERSION": VERSION}
        base.update(over)
        return base

    def test_environment_allows_main_and_matching_tag(self):
        with patch.object(release.subprocess, "check_output",
                          return_value="built\n"):
            with patch.dict(os.environ, self.env(), clear=True):
                self.assertEqual(release.environment(), ("built", "o/r"))
            with patch.dict(os.environ,
                            self.env(GITHUB_REF="refs/tags/v" + VERSION),
                            clear=True):
                self.assertEqual(release.environment(), ("built", "o/r"))

    def test_environment_rejects_pr_tag_mismatch_and_other_branch(self):
        with patch.object(release.subprocess, "check_output",
                          return_value="built\n"):
            with patch.dict(os.environ,
                            self.env(GITHUB_EVENT_NAME="pull_request"), clear=True):
                with self.assertRaises(ValueError):
                    release.environment()
            with patch.dict(os.environ,
                            self.env(GITHUB_REF="refs/tags/v9.9.9"), clear=True):
                with self.assertRaises(ValueError):
                    release.environment()
            with patch.dict(os.environ,
                            self.env(GITHUB_REF="refs/heads/feature"), clear=True):
                with self.assertRaises(ValueError):
                    release.environment()

    def test_environment_rejects_sha_mismatch(self):
        with patch.dict(os.environ, self.env(), clear=True), \
             patch.object(release.subprocess, "check_output",
                          return_value="different\n"):
            with self.assertRaises(ValueError):
                release.environment()

    # ---- repository contract ----
    def test_repository_contract_has_no_pinned_version_or_platforms(self):
        config = json.loads((release.ROOT / ".github/release.json").read_text())
        self.assertNotIn("assets", config)
        self.assertEqual(config["project"], "JustCleaner")


if __name__ == "__main__":
    unittest.main()
