import copy
import hashlib
import io
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

from sync_releases import receive


def archive(entries):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as bundle:
        for name, payload in entries.items():
            bundle.writestr(name, payload)
    return data.getvalue()


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.tag = "v1.2.3"
        self.folder = self.root / self.tag
        self.apk = "Innerwave-Studio-v1.2.3.apk"
        self.ipa = "Innerwave-Studio-v1.2.3.ipa"
        info = {"CFBundleShortVersionString": "1.2.3", "CFBundleIdentifier": "studio.innerwave.innerwaveStudio"}
        self.files = {
            self.apk: archive({"AndroidManifest.xml": b"manifest", "lib/arm64-v8a/libapp.so": b"arm64"}),
            self.ipa: archive({"Payload/Runner.app/Info.plist": plistlib.dumps(info)}),
        }
        self.files["SHA256SUMS.txt"] = "".join(
            f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in self.files.items()
        ).encode()
        self.release = {"tag_name": self.tag, "assets": [
            {"name": name, "size": len(data), "state": "uploaded", "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
            for name, data in self.files.items()
        ]}
        self.requests = []

    def download(self, url):
        name = url.rsplit("/", 1)[1]
        self.requests.append(name)
        return io.BytesIO(self.files[name])

    def test_new_pair_appears_together_and_unchanged_rerun_uses_no_downloads(self):
        def first_download(url):
            self.assertFalse(self.folder.exists())
            return self.download(url)

        receipt, changed = receive(self.root, self.release, {}, first_download)
        self.assertTrue(changed)
        self.assertCountEqual(self.requests, self.files)
        self.assertEqual({p.name: p.read_bytes() for p in self.folder.iterdir()}, self.files)
        self.requests.clear()
        self.assertEqual(receive(self.root, self.release, receipt, self.download), (receipt, False))
        self.assertEqual(self.requests, [])

    def test_interrupted_download_cleans_staging_without_publishing_partial_pair(self):
        def interrupted(url):
            if url.endswith(self.ipa):
                raise ConnectionError("injected midway through pair")
            return self.download(url)

        with self.assertRaises(ConnectionError):
            receive(self.root, self.release, {}, interrupted)
        self.assertEqual(list(self.root.iterdir()), [])
        _, changed = receive(self.root, self.release, {}, self.download)
        self.assertTrue(changed)

    def test_corrupt_download_rejected_and_corrupt_local_package_repaired(self):
        def damaged(url):
            return io.BytesIO(b"corrupt") if url.endswith(self.apk) else self.download(url)

        with self.assertRaisesRegex(ValueError, "SHA-256"):
            receive(self.root, self.release, {}, damaged)
        self.assertEqual(list(self.root.iterdir()), [])
        receipt, _ = receive(self.root, self.release, {}, self.download)
        (self.folder / self.apk).write_bytes(b"corrupt existing file")
        self.requests.clear()
        new_receipt, changed = receive(self.root, self.release, receipt, self.download)
        self.assertTrue(changed)
        self.assertEqual(self.requests, [self.apk])
        self.assertEqual((self.folder / self.apk).read_bytes(), self.files[self.apk])
        self.assertEqual(new_receipt[self.ipa], receipt[self.ipa])

    def test_changed_remote_digest_preserves_the_delivered_pair(self):
        receipt, _ = receive(self.root, self.release, {}, self.download)
        changed_release = copy.deepcopy(self.release)
        changed_release["assets"][0]["digest"] = "sha256:" + "1" * 64
        self.requests.clear()
        with self.assertRaisesRegex(ValueError, "Published contents changed"):
            receive(self.root, changed_release, receipt, self.download)
        self.assertEqual(self.requests, [])
        self.assertEqual({p.name: p.read_bytes() for p in self.folder.iterdir()}, self.files)
