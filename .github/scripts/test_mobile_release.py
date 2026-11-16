import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from mobile_release import SUMS, check_published, filenames, pubspec, select, stage_notes, sums_bytes, update_draft, upload_asset


SHA = "1" * 40
OTHER = "a" * 40
SPEC = "name: studio\nversion: 0.1.0+4\n"


def reserved(tag, sha, build, run_id=100):
    return {"tag_name": tag, "target_commitish": sha, "draft": True, "prerelease": False,
            "body": f"<!-- innerwave-mobile {sha} build {build} run {run_id} -->", "assets": []}


def asset(name, data):
    return {"name": name, "state": "uploaded", "size": len(data),
            "digest": "sha256:" + hashlib.sha256(data).hexdigest()}


class ReleaseTests(unittest.TestCase):
    def test_draft_note_update_and_publication_preserve_reserved_tag_and_commit(self):
        tag = "v0.1.2"
        for fields in [("-f", "body=verified"), ("-F", "draft=false", "-f", "make_latest=true")]:
            with self.subTest(fields=fields):
                with patch("mobile_release.api", return_value={"tag_name": tag, "target_commitish": SHA}) as api:
                    update_draft("owner/repo", "releases/941", tag, SHA, *fields)
                    api.assert_called_once_with("owner/repo", "releases/941", "-X", "PATCH",
                        "-f", f"tag_name={tag}", "-f", f"target_commitish={SHA}", *fields)
        with patch("mobile_release.api", return_value={"tag_name": "untagged-deadbeef", "target_commitish": SHA}):
            with self.assertRaisesRegex(ValueError, "changed the reserved tag"):
                update_draft("owner/repo", "releases/941", tag, SHA, "-f", "body=verified")

    def test_draft_upload_streams_to_release_id_and_checks_returned_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Innerwave-Studio-v0.1.2.apk"
            data = b"already verified apk"
            path.write_bytes(data)
            result = asset(path.name, data)

            def accept(request, timeout):
                self.assertEqual(request.full_url,
                    "https://uploads.github.com/repos/owner/repo/releases/941/assets?name=" + path.name)
                self.assertEqual(request.get_method(), "POST")
                self.assertEqual(request.get_header("Content-length"), str(len(data)))
                self.assertEqual(request.get_header("Authorization"), "Bearer fixture-token")
                self.assertEqual(request.data.read(), data)
                response = io.BytesIO(json.dumps(result).encode())
                response.status = 201
                return response

            with patch.dict("os.environ", {"GH_TOKEN": "fixture-token"}), patch("mobile_release.urlopen", accept):
                self.assertEqual(upload_asset("owner/repo", 941, path, result["digest"]), result)
                with self.assertRaisesRegex(ValueError, "digest mismatch"):
                    upload_asset("owner/repo", 941, path, "sha256:" + "0" * 64)

    def test_floor_and_patch_after_all_reserved_or_tagged_versions(self):
        self.assertEqual(select(SPEC, [], {}, SHA, 2, 101), ("v0.1.0", 4, None))
        other = reserved("v0.1.2", OTHER, 20)
        self.assertEqual(select(SPEC, [other], {"v0.1.3": OTHER}, SHA, 5, 101), ("v0.1.4", 21, None))
        self.assertEqual(select("version: 1.0.0+1", [other], {}, SHA, 40, 101), ("v1.0.0", 40, None))
        with self.assertRaises(ValueError):
            pubspec("version: 0.01.0+1")

    def test_an_old_retry_reuses_both_numbers_and_rejects_a_changed_tag(self):
        draft = reserved("v0.1.1", SHA, 9)
        later = reserved("v0.1.2", OTHER, 10, run_id=101)
        self.assertEqual(select(SPEC, [later, draft], {}, SHA, 99, 100), ("v0.1.1", 9, draft))
        with self.assertRaises(ValueError):
            select(SPEC, [draft], {"v0.1.1": OTHER}, SHA, 99, 100)

    def test_new_workflow_dispatch_on_same_commit_gets_new_version(self):
        old = reserved("v0.1.0", SHA, 9, run_id=731)
        new_tag, new_build, reservation = select(SPEC, [old], {}, SHA, 10, 732)
        self.assertEqual((new_tag, new_build, reservation), ("v0.1.1", 10, None))
        new = reserved(new_tag, SHA, new_build, run_id=732)
        for run_id, release in [(731, old), (732, new)]:
            self.assertIs(select(SPEC, [old, new], {}, SHA, 99, run_id)[2], release)
        with self.assertRaises(ValueError):
            select(SPEC, [old], {}, OTHER, 99, 731)

    def test_published_release_requires_exact_verified_pair_checksum_and_commit(self):
        tag = "v1.2.3"
        apk, ipa = filenames(tag)
        a = {apk: asset(apk, b"apk"), ipa: asset(ipa, b"ipa")}
        sums = sums_bytes(tag, a)
        self.assertEqual(sums.decode().splitlines(),
                         [f"{a[name]['digest'][7:]}  {name}" for name in [apk, ipa]])
        a[SUMS] = asset(SUMS, sums)
        release = {**reserved(tag, SHA, 4), "draft": False, "assets": list(a.values())}
        check_published(release, {tag: SHA}, SHA)
        with self.assertRaises(ValueError):
            check_published(release, {tag: OTHER}, SHA)
        a[ipa]["digest"] = "sha256:" + "0" * 64
        with self.assertRaises(ValueError):
            check_published(release, {tag: SHA}, SHA)
        release["assets"] = [a[apk]]
        with self.assertRaises(ValueError):
            check_published(release, {tag: SHA}, SHA)

    def test_interrupted_upload_reuses_only_previously_verified_draft_bytes(self):
        tag = "v1.2.3"
        apk, ipa = filenames(tag)
        first = {apk: asset(apk, b"verified apk")["digest"], ipa: asset(ipa, b"verified ipa")["digest"]}
        body = stage_notes(tag, "notes", {}, first)
        partial = {apk: asset(apk, b"verified apk")}
        rebuilt = {apk: asset(apk, b"second verified apk")["digest"],
                   ipa: asset(ipa, b"second verified ipa")["digest"]}
        resumed = stage_notes(tag, body, partial, rebuilt)
        self.assertIn(first[apk], resumed)
        self.assertIn(rebuilt[ipa], resumed)
        self.assertNotIn(rebuilt[apk], resumed)
        with self.assertRaises(ValueError):
            stage_notes(tag, body, {apk: asset(apk, b"unexpected")}, rebuilt)
