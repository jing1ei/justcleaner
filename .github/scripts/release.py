"""Verify and publish one immutable JustCleaner GitHub release.

Triggered by the GitHub Actions workflow after the macOS build and test job
has produced verified packages in `dist`. It:

* requires every package named in .github/release.json to be present, nonempty,
  and to match the checksums built by release.sh;
* publishes a GitHub release named after the app version (tag `v<version>`);
* never force-moves or overwrites an already published release, so a version is
  immutable once released - ship a new version instead.

The workflow passes the version, target commit and event ref through the
environment so the package version can never drift from the published tag.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD_CHECKSUMS = "SHA256SUMS.txt"
PUBLISHED_CHECKSUMS = "SHA256SUMS.txt"


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def asset_names(project, version):
    """The exact, version-driven set of files a release must contain."""
    return [
        f"{project}-{version}-source.zip",
        f"{project}-{version}-macOS-arm64.dmg",
        f"{project}-{version}-macOS-x64.dmg",
    ]


def prepare(source, output, config, version):
    """Copy every required package into a clean output dir after verification.

    Missing or corrupted inputs stop publication before any GitHub call is made.
    """
    source = Path(source)
    expected = asset_names(config["project"], version)
    # Trust only the checksum manifest emitted by the local build (release.sh),
    # never an attacker-controllable file uploaded with the packages.
    manifest = source / BUILD_CHECKSUMS
    if not manifest.is_file():
        raise ValueError(f"missing {BUILD_CHECKSUMS} from the build")
    known = {}
    for line in manifest.read_text().splitlines():
        if not line.strip():
            continue
        checksum, name = line.split("  ", 1)
        known[Path(name).name] = checksum
    selected = {}
    for name in expected:
        path = source / name
        if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
            raise ValueError(f"expected one nonempty package: {name}")
        if known.get(name) != digest(path):
            raise ValueError(f"input checksum mismatch: {name}")
        selected[name] = path
    if output.exists():
        raise FileExistsError(f"output directory already exists: {output}")
    output.mkdir(parents=True)
    for name, path in selected.items():
        shutil.copyfile(path, output / name)
    files = sorted(output.iterdir())
    (output / PUBLISHED_CHECKSUMS).write_text(
        "".join(f"{digest(p)}  {p.name}\n" for p in files))
    return output


def gh(*args, payload=None):
    result = subprocess.run(
        ["gh", *args],
        input=json.dumps(payload) if payload is not None else None,
        text=True, capture_output=True, check=True)
    return result.stdout


def api(endpoint, method="GET", payload=None):
    args = ["api", endpoint, "--method", method]
    if payload is not None:
        args += ["--input", "-"]
    text = gh(*args, payload=payload)
    return json.loads(text) if text.strip() else None


def pages(endpoint):
    return [item for page in json.loads(
        gh("api", endpoint, "--paginate", "--slurp")) for item in page]


def gh_bytes(endpoint):
    """Download one release asset's raw bytes through the GitHub API redirect."""
    return subprocess.run(
        ["gh", "api", "-H", "Accept: application/octet-stream", endpoint],
        capture_output=True, check=True).stdout


def publish(directory, config, version, sha, repo):
    tag = "v" + version
    prefix = f"repos/{repo}"

    expected = {}
    for line in (directory / PUBLISHED_CHECKSUMS).read_text().splitlines():
        checksum, name = line.split("  ", 1)
        if Path(name).name != name or digest(directory / name) != checksum:
            raise ValueError(f"invalid local checksum: {name}")
        expected[name] = checksum
    expected[PUBLISHED_CHECKSUMS] = digest(directory / PUBLISHED_CHECKSUMS)
    if {p.name for p in directory.iterdir()} != set(expected):
        raise ValueError("unexpected files outside the checksum manifest")

    releases = [r for r in pages(prefix + "/releases?per_page=100")
                if r["tag_name"] == tag]
    if len(releases) > 1:
        raise ValueError(f"multiple releases use {tag}")

    if releases and not releases[0]["draft"]:
        # A released version is immutable. A rerun for the exact same commit is
        # an idempotent no-op; any other commit must use a new version.
        if releases[0]["target_commitish"] == sha:
            print(f"{tag} already published at {sha}; nothing to do")
            return False
        raise ValueError(
            f"{tag} is already published at {releases[0]['target_commitish']}; "
            "bump the version for a new release")

    notes = config.get("notes", "").strip()
    body = notes + f"\n\nBuilt from `{sha}`.\n"
    metadata = dict(name=version, body=body, prerelease=False,
                    target_commitish=sha)

    if releases:
        release = api(prefix + f"/releases/{releases[0]['id']}", "PATCH",
                      dict(metadata, draft=True))
    else:
        release = api(prefix + "/releases", "POST",
                      dict(metadata, draft=True, tag_name=tag))

    gh("release", "upload", tag, "--repo", repo, "--clobber",
       *(str(directory / name) for name in sorted(expected)))

    # Re-download and verify what GitHub stored (including resumed uploads)
    # before making the release public. Assets are fetched through the REST API
    # with the octet-stream accept header, which also works while the release
    # is still a draft.
    assets = pages(prefix + f"/releases/{release['id']}/assets?per_page=100")
    by_name = {a["name"]: a for a in assets}
    if set(by_name) != set(expected):
        raise ValueError(
            f"uploaded asset set mismatch: {sorted(by_name)} != {sorted(expected)}")
    with tempfile.TemporaryDirectory() as temporary:
        for name, checksum in expected.items():
            target = Path(temporary) / name
            target.write_bytes(gh_bytes(
                f"{prefix}/releases/assets/{by_name[name]['id']}"))
            if digest(target) != checksum:
                raise ValueError(f"uploaded checksum mismatch: {name}")

    # A pushed tag must keep its existing commit. For a main-branch publish
    # without a tag yet, create the tag at the verified commit. Never force a
    # tag to move.
    refs = api(prefix + "/git/matching-refs/tags/" + tag)
    existing = next((r for r in refs if r["ref"] == "refs/tags/" + tag), None)
    if existing is None:
        api(prefix + "/git/refs", "POST",
            {"ref": "refs/tags/" + tag, "sha": sha})
    elif existing["object"]["sha"] != sha:
        raise ValueError(f"{tag} points at {existing['object']['sha']}, "
                         f"not the built commit {sha}; bump the version")

    # Remove assets that are not part of this verified release, then publish.
    for asset in pages(prefix + f"/releases/{release['id']}/assets?per_page=100"):
        if asset["name"] not in expected:
            api(prefix + f"/releases/assets/{asset['id']}", "DELETE")
    api(prefix + f"/releases/{release['id']}", "PATCH",
        dict(metadata, draft=False, make_latest="true"))
    print(f"https://github.com/{repo}/releases/tag/{tag}")
    return True


def environment():
    """Validate the publication context supplied by the workflow."""
    sha = os.environ["GITHUB_SHA"]
    repo = os.environ["GITHUB_REPOSITORY"]
    ref = os.environ["GITHUB_REF"]
    event = os.environ["GITHUB_EVENT_NAME"]
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                     text=True).strip()
    if actual != sha:
        raise ValueError("GITHUB_SHA does not match the checked-out commit")
    if event == "pull_request":
        raise ValueError("pull requests never publish")
    if ref.startswith("refs/tags/"):
        if ref != "refs/tags/v" + os.environ["JC_VERSION"]:
            raise ValueError("pushed tag does not match the app version")
    elif ref != "refs/heads/main":
        raise ValueError("only main-branch pushes or a matching tag publish")
    return sha, repo


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?",
                        help="directory containing the built dist packages")
    parser.add_argument("--version", default=os.environ.get("JC_VERSION"))
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()

    version = args.version
    if not version:
        raise SystemExit("a version is required (--version or JC_VERSION)")
    config = json.loads((ROOT / ".github/release.json").read_text())

    if args.prepare_only:
        if args.directory is None:
            raise SystemExit("--prepare-only needs a packages directory")
        prepare(args.directory, args.directory.parent / "release-ready",
                config, version)
        return

    if args.directory is None:
        raise SystemExit("a packages directory is required to publish")
    sha, repo = environment()
    output = prepare(args.directory, args.directory.parent / "release-ready",
                     config, version)
    publish(output, config, version, sha, repo)


if __name__ == "__main__":
    main()
