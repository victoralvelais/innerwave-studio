"""Download every published Innerwave APK/IPA pair into release/vMAJOR.MINOR.PATCH/."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
from urllib.request import Request, urlopen
from zipfile import ZipFile


PROJECT = Path(__file__).resolve().parents[1]
REPO = "victoralvelais/innerwave-studio"
STABLE_TAG = re.compile(r"v(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}")
DIGEST = re.compile(r"sha256:[a-f0-9]{64}")


def fetch(url):
    return urlopen(Request(url, headers={"User-Agent": "Innerwave-release-delivery"}), timeout=90)


def published():
    page = 1
    while True:
        with fetch(f"https://api.github.com/repos/{REPO}/releases?per_page=100&page={page}") as response:
            items = json.load(response)
        for release in items:
            if not release["draft"] and not release["prerelease"] and STABLE_TAG.fullmatch(release["tag_name"]):
                yield release
        if len(items) < 100:
            return
        page += 1


def matches(path, asset):
    if not path.is_file() or path.stat().st_size != asset["size"]:
        return False
    with path.open("rb") as stream:
        return "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest() == asset["digest"]


def fingerprint(path, asset):
    stat = path.stat()
    return [asset["digest"], stat.st_size, stat.st_mtime_ns]


def receive(root, release, receipt, download=fetch):
    tag = release["tag_name"]
    if not STABLE_TAG.fullmatch(tag):
        raise ValueError(f"Invalid release version {tag!r}")
    folder = root / tag
    apk, ipa = (f"Innerwave-Studio-{tag}.{extension}" for extension in ("apk", "ipa"))
    names = (apk, ipa, "SHA256SUMS.txt")
    assets = {a["name"]: a for a in release["assets"] if a["state"] == "uploaded"}
    if any(name not in assets or not DIGEST.fullmatch(assets[name].get("digest") or "")
           or assets[name]["size"] <= 0 for name in names):
        raise ValueError(f"{tag} is missing a complete, checksummed set of release assets")
    # Repeated checks skip unchanged verified files without re-hashing old releases.
    if all((folder / name).is_file() and receipt.get(name) == fingerprint(folder / name, assets[name])
           for name in names):
        return receipt, False
    if any(name in receipt and receipt[name][0] != assets[name]["digest"] for name in names):
        raise ValueError(f"Published contents changed for previously received {tag}")

    with tempfile.TemporaryDirectory(prefix=f".receiving-{tag}-", dir=root) as tmp:
        stage = Path(tmp)
        files = {}
        for name in names:
            path = folder / name
            if not matches(path, assets[name]):
                path = stage / name
                with download(f"https://github.com/{REPO}/releases/download/{tag}/{name}") as src, path.open("xb") as dst:
                    shutil.copyfileobj(src, dst, 1024 * 1024)
                if not matches(path, assets[name]):
                    raise ValueError(f"Download failed SHA-256 verification for {name}")
            files[name] = path
        expected = {f"{assets[name]['digest'][7:]}  {name}" for name in (apk, ipa)}
        if sorted(files["SHA256SUMS.txt"].read_text(encoding="utf-8").splitlines()) != sorted(expected):
            raise ValueError(f"Published checksum file does not match the two packages in {tag}")
        with ZipFile(files[ipa]) as bundle:
            info = plistlib.loads(bundle.read("Payload/Runner.app/Info.plist"))
            if info["CFBundleShortVersionString"] != tag[1:] or info["CFBundleIdentifier"] != "studio.innerwave.innerwaveStudio":
                raise ValueError(f"iPhone package identity or version does not match {tag}")
        with ZipFile(files[apk]) as bundle:
            if not all(bundle.getinfo(name).file_size for name in ("AndroidManifest.xml", "lib/arm64-v8a/libapp.so")):
                raise ValueError(f"Incomplete Android package in {tag}")
        if not folder.exists():
            try:
                stage.rename(folder)  # New releases become visible as a complete pair.
            except OSError:
                if not folder.is_dir():
                    raise
        for name in names:
            staged = stage / name
            if staged.exists():
                os.replace(staged, folder / name)
    return {name: fingerprint(folder / name, assets[name]) for name in names}, True


def main():
    root = PROJECT / "release"
    root.mkdir(exist_ok=True)
    cache = PROJECT / "build" / "release-receiver"
    cache.mkdir(parents=True, exist_ok=True)
    history = cache / "verified.json"
    try:
        receipts = json.loads(history.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        receipts = {}
    failures = []
    for release in published():
        tag = release["tag_name"]
        try:
            receipts[tag], changed = receive(root, release, receipts.get(tag, {}))
            if changed:
                print(f"Verified {root / tag}")
        except Exception as error:
            failures.append(f"{tag}: {error}")
    with tempfile.NamedTemporaryFile(mode="w", dir=cache, delete=False, encoding="utf-8") as tmp:
        json.dump(receipts, tmp, sort_keys=True)
    os.replace(tmp.name, history)
    if failures:
        raise RuntimeError("\n".join(failures))


if __name__ == "__main__":
    main()
