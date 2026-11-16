"""Reserve a build's version, then publish its verified APK and IPA as a pair."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlencode
from urllib.request import Request, urlopen
import zipfile


SEMVER = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
OWNER = re.compile(r"<!-- innerwave-mobile ([a-f0-9]{40}) build ([1-9][0-9]*)(?: run ([1-9][0-9]*))? -->")
STAGED = re.compile(r"<!-- innerwave-verified (sha256:[a-f0-9]{64}) (sha256:[a-f0-9]{64}) -->")
SUMS = "SHA256SUMS.txt"


def version_tuple(tag):
    match = re.fullmatch("v" + SEMVER, tag)
    return tuple(map(int, match.groups())) if match else ()


def filenames(tag):
    return [f"Innerwave-Studio-{tag}.{ext}" for ext in ("apk", "ipa")]


def pubspec(text):
    match = re.search(r"^version:\s*(" + SEMVER + r")\+([1-9][0-9]*)\s*$", text, re.M)
    if not match:
        raise ValueError("Expected pubspec version X.Y.Z+BUILD.")
    return version_tuple("v" + match[1]), int(match[5])


def owner(release):
    return OWNER.search(release.get("body") or "")


def select(text, releases, tags, sha, run_number, run_id):
    floor, build_floor = pubspec(text)
    owned = [r for r in releases if owner(r) and owner(r)[3] == str(run_id)]
    if len(owned) > 1:
        raise ValueError("Multiple release reservations belong to this workflow run.")
    if owned:
        release = owned[0]
        tag = release["tag_name"]
        if (not version_tuple(tag) or owner(release)[1] != sha or release["target_commitish"] != sha
                or release["prerelease"] or tags.get(tag, sha) != sha):
            raise ValueError(f"Reservation or tag {tag} points to a conflicting build.")
        return tag, int(owner(release)[2]), release
    all_tags = set(tags) | {r["tag_name"] for r in releases}
    latest = max((version_tuple(t) for t in all_tags), default=())
    version = (*latest[:2], latest[2] + 1) if latest >= floor else floor
    used = [int(owner(r)[2]) for r in releases if owner(r)]
    build = max(build_floor, run_number, max(used, default=0) + 1)
    if build > 2100000000:
        raise ValueError("Build number exceeds the Android versionCode limit.")
    return "v" + ".".join(map(str, version)), build, None


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def api(repo, path, *args):
    return json.loads(gh("api", f"repos/{repo}/{path}", *args))


def update_draft(repo, release_path, tag, sha, *fields):
    # GitHub may assign an untagged-* name to a draft when PATCH omits its tag.
    release = api(repo, release_path, "-X", "PATCH", "-f", f"tag_name={tag}",
                  "-f", f"target_commitish={sha}", *fields)
    if release.get("tag_name") != tag or release.get("target_commitish") != sha:
        raise ValueError("GitHub changed the reserved tag or commit while updating the draft.")
    return release


def listing(repo, resource):
    pages = api(repo, resource + "?per_page=100", "--paginate", "--slurp")
    return [item for page in pages for item in page]


def sums_bytes(tag, assets):
    rows = []
    for name in filenames(tag):
        asset = assets[name]
        digest = asset.get("digest") or ""
        if (asset["state"] != "uploaded" or asset["size"] <= 0
                or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
            raise ValueError(f"Incomplete release asset {name}.")
        rows.append(f"{digest[7:]}  {name}\n")
    return "".join(rows).encode()


def check_published(release, tags, sha):
    tag = release["tag_name"]
    assets = {a["name"]: a for a in release["assets"]}
    if tags.get(tag) != sha or set(assets) != {*filenames(tag), SUMS}:
        raise ValueError(f"Published {tag} has a conflicting tag or incomplete asset pair.")
    sums = sums_bytes(tag, assets)
    checksum = assets[SUMS]
    if (checksum["state"] != "uploaded" or checksum["size"] != len(sums)
            or checksum.get("digest") != "sha256:" + hashlib.sha256(sums).hexdigest()):
        raise ValueError(f"Published {tag} has an inconsistent checksum file.")


def local_digest(path):
    with path.open("rb") as handle:
        return "sha256:" + hashlib.file_digest(handle, "sha256").hexdigest()


def upload_asset(repo, release_id, path, expected):
    endpoint = f"https://uploads.github.com/repos/{repo}/releases/{int(release_id)}/assets"
    size = path.stat().st_size
    headers = {"Authorization": "Bearer " + os.environ["GH_TOKEN"],
               "Accept": "application/vnd.github+json", "Content-Type": "application/octet-stream",
               "Content-Length": str(size), "User-Agent": "Innerwave-release-publisher"}
    with path.open("rb") as stream:
        request = Request(endpoint + "?" + urlencode({"name": path.name}), data=stream,
                          method="POST", headers=headers)
        with urlopen(request, timeout=600) as response:
            if response.status != 201:
                raise ValueError(f"Unexpected upload response {response.status} for {path.name}.")
            asset = json.load(response)
    if (asset.get("name") != path.name or asset.get("state") != "uploaded"
            or asset.get("size") != size or asset.get("digest") != expected):
        raise ValueError(f"Remote size, name, state or digest mismatch after upload of {path.name}.")
    return asset


def stage_notes(tag, body, assets, verified):
    names = filenames(tag)
    saved = STAGED.search(body)
    digests = []
    for i, name in enumerate(names):
        local = verified[name]
        previous = assets.get(name)
        if previous and previous["state"] == "uploaded":
            remote = previous.get("digest")
            if remote != local and (saved is None or saved[i + 1] != remote):
                raise ValueError(f"Draft already contains a conflicting {name}.")
            digests.append(remote)
        else:
            digests.append(local)
    marker = "<!-- innerwave-verified " + " ".join(digests) + " -->"
    return STAGED.sub(marker, body) if saved else body + "\n\n" + marker


def main():
    command = sys.argv[1]
    repo, sha = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"]
    releases = listing(repo, "releases")
    tags = {t["name"]: t["commit"]["sha"] for t in listing(repo, "tags")}
    run_id = int(os.environ["GITHUB_RUN_ID"])
    tag, build, release = select(Path("pubspec.yaml").read_text(), releases, tags,
                                 sha, int(os.environ["GITHUB_RUN_NUMBER"]), run_id)
    if command == "reserve":
        if release is None:
            notes = (f"Android APK and unsigned iPhone IPA for commit `{sha}`. "
                     f"Build {build}. The iPhone package requires compatible signing or sideloading.\n\n"
                     f"<!-- innerwave-mobile {sha} build {build} run {run_id} -->")
            release = api(repo, "releases", "-X", "POST", "-f", f"tag_name={tag}",
                          "-f", f"target_commitish={sha}", "-f", f"name=Innerwave Studio {tag}",
                          "-f", f"body={notes}", "-F", "draft=true")
        if not release["draft"]:
            check_published(release, tags, sha)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as out:
            out.write(f"version={tag[1:]}\nbuild={build}\npublished={str(not release['draft']).lower()}\n")
        print(f"{tag} (build {build})")
        return
    if command != "publish" or tag != "v" + os.environ["VERSION"] or build != int(os.environ["BUILD"]):
        raise ValueError("Selected build differs from the reserved version.")
    if release is None:
        raise ValueError("Release reservation disappeared.")
    if not release["draft"]:
        check_published(release, tags, sha)
        return
    folder = Path(sys.argv[2])
    names = filenames(tag)
    present = {p.name for p in folder.iterdir()}
    if present - {SUMS} != set(names):
        raise ValueError("Both versioned packages must be present before release.")
    for name in names:
        with zipfile.ZipFile(folder / name) as archive:
            required = "AndroidManifest.xml" if name.endswith(".apk") else "Payload/Runner.app/Info.plist"
            if required not in archive.namelist() or archive.testzip() is not None:
                raise ValueError(f"Invalid package archive {name}.")
    release_path = f"releases/{release['id']}"
    assets = {a["name"]: a for a in release["assets"]}
    if set(assets) - {*names, SUMS}:
        raise ValueError("Unexpected files in this draft.")
    verified = {name: local_digest(folder / name) for name in names}
    body = stage_notes(tag, release["body"], assets, verified)
    if body != release["body"]:
        update_draft(repo, release_path, tag, sha, "-f", f"body={body}")
    for name in [*names, SUMS]:
        path = folder / name
        if name == SUMS:
            path.write_bytes(sums_bytes(tag, assets))
        existing = assets.get(name)
        if existing and existing["state"] == "starter" and existing["size"] == 0:
            # GitHub can leave an empty starter object after a failed upload.
            gh("api", "-X", "DELETE", f"repos/{repo}/releases/assets/{existing['id']}")
            existing = None
        if existing:
            if name == SUMS and existing.get("digest") != local_digest(path):
                raise ValueError("Existing draft checksums conflict with the package pair.")
            # Finished packages already landed in this exact commit/build's draft
            # after both test jobs passed. Preserve those bytes across rebuilds.
            continue
        expected = verified[name] if name in verified else local_digest(path)
        assets[name] = upload_asset(repo, release["id"], path, expected)
    # Recheck both the remote draft and tag immediately before publication.
    draft = api(repo, release_path)
    now = {t["name"]: t["commit"]["sha"] for t in listing(repo, "tags")}
    if (not draft["draft"] or draft["tag_name"] != tag or draft["target_commitish"] != sha
            or draft["body"] != body or now.get(tag, sha) != sha):
        raise ValueError("Draft or tag changed while staging.")
    check_published(draft, {tag: sha}, sha)
    latest = max((version_tuple(r["tag_name"]) for r in releases
                  if not r["draft"] and not r["prerelease"]), default=())
    update_draft(repo, release_path, tag, sha, "-F", "draft=false",
                 "-f", f"make_latest={str(version_tuple(tag) >= latest).lower()}")
    published = api(repo, release_path)
    now = {t["name"]: t["commit"]["sha"] for t in listing(repo, "tags")}
    if published["draft"]:
        raise ValueError("Release is still a draft.")
    check_published(published, now, sha)
    print(published["html_url"])


if __name__ == "__main__":
    main()
