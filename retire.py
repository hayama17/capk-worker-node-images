#!/usr/bin/env python3
"""List the package versions of $1 that the retention policy retires. --delete removes them."""
import datetime as dt, json, os, re, subprocess, sys, urllib.request

KEEP_ACTIVE, KEEP_ARCHIVED = 3, 1


def plan(versions, active, children, now):
    """Return the versions to remove. children(digest) lists the manifests inside an index."""
    by_tag = {t: v for v in versions for t in v["tags"]}
    moving = {t for t in by_tag if re.fullmatch(r"v\d+\.\d+\.\d+", t)}
    if missing := set(active) - moving:
        raise SystemExit(f"active versions without a tag, refusing to continue: {sorted(missing)}")
    keep = {by_tag[t]["digest"] for t in moving}
    builds = {}
    for tag, v in by_tag.items():
        # Up to 9 digits: older builds carry a 12-digit time instead of a number
        if m := re.fullmatch(r"(v\d+\.\d+\.\d+)-(\d{1,9})", tag):
            builds.setdefault(m[1], []).append((int(m[2]), v["digest"]))
    for version, found in builds.items():
        n = KEEP_ACTIVE if version in active else KEEP_ARCHIVED
        keep |= {digest for _, digest in sorted(found)[-n:]}
    # Attestations are untagged manifests listed in an index tagged sha256-<digest of the image>
    for digest in list(keep):
        if index := by_tag.get(digest.replace(":", "-")):
            keep |= {index["digest"], *children(index["digest"])}
    # A running publish may still be about to use something new
    old = now - dt.timedelta(days=1)
    return [v for v in versions if v["digest"] not in keep and v["updated"] < old]


def selftest():
    now = dt.datetime(2026, 1, 10, tzinfo=dt.timezone.utc)
    def v(digest, *tags, days=5):
        return {"id": digest, "digest": digest, "tags": list(tags), "updated": now - dt.timedelta(days=days)}
    versions = [
        v("sha256:a5", "v1.2.3", "v1.2.3-5"), v("sha256:a4", "v1.2.3-4"), v("sha256:a3", "v1.2.3-3"),
        v("sha256:a2", "v1.2.3-2"), v("sha256:a0", "v1.2.3-202601010000"),
        v("sha256:b2", "v1.2.2", "v1.2.2-2"), v("sha256:b1", "v1.2.2-1"),
        v("sha256:ia5", "sha256-a5"), v("sha256:att", ), v("sha256:ia2", "sha256-a2"), v("sha256:att2"),
        v("sha256:new", days=0),
    ]
    inside = {"sha256:ia5": ["sha256:att"], "sha256:ia2": ["sha256:att2"]}
    gone = {x["digest"][7:] for x in plan(versions, ["v1.2.3"], inside.__getitem__, now)}
    assert gone == {"a2", "a0", "b1", "ia2", "att2"}, gone
    # A rollback points the moving tag at an old build, which then has to stay
    versions[0]["tags"].remove("v1.2.3"); versions[3]["tags"].append("v1.2.3")
    gone = {x["digest"][7:] for x in plan(versions, ["v1.2.3"], inside.__getitem__, now)}
    assert gone == {"a0", "b1"}, gone
    try:
        plan(versions, ["v9.9.9"], inside.__getitem__, now)
    except SystemExit:
        return
    raise AssertionError("a missing active version must stop the run")


def main(os_name, delete):
    owner, repo = os.environ["GITHUB_REPOSITORY"].lower().split("/")
    api = f"/users/{owner}/packages/container/{repo}%2F{os_name}/versions"
    out = subprocess.check_output(["gh", "api", "--paginate", "--slurp", api + "?per_page=100"])
    versions = [{"id": x["id"], "digest": x["name"], "tags": x["metadata"]["container"]["tags"],
                 "updated": dt.datetime.fromisoformat(x["updated_at"].replace("Z", "+00:00"))}
                for page in json.loads(out) for x in page]
    name = f"{owner}/{repo}/{os_name}"
    with urllib.request.urlopen(f"https://ghcr.io/token?scope=repository:{name}:pull") as r:
        token = json.load(r)["token"]

    def children(digest):
        req = urllib.request.Request(f"https://ghcr.io/v2/{name}/manifests/{digest}", headers={
            "Authorization": "Bearer " + token, "Accept": "application/vnd.oci.image.index.v1+json"})
        with urllib.request.urlopen(req) as r:
            return [m["digest"] for m in json.load(r)["manifests"]]

    with open(".github/workflows/build.yml") as f:
        active = re.findall(r"^ +- (v\d+\.\d+\.\d+)$", f.read(), re.M)
    remove = plan(versions, active, children, dt.datetime.now(dt.timezone.utc))
    print(f"{len(versions)} versions, {len(remove)} to remove")
    for v in remove:
        print(v["digest"], " ".join(v["tags"]) or "(untagged)", v["updated"].date())
        if delete:
            subprocess.check_call(["gh", "api", "--silent", "-X", "DELETE", f"{api}/{v['id']}"])


if __name__ == "__main__":
    selftest()
    main(sys.argv[1], "--delete" in sys.argv[2:])
