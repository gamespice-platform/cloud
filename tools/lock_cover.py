#!/usr/bin/env python3
"""Which tracked binaries could be dropped from git because the CDN holds the same bytes?
  lock_cover.py REPO [--lock FILE]
Hashes every tracked binary of REPO (a clean checkout) and looks each up among the object hashes of the manifests FILE pins
(default content.lock.json, or source.lock.json for a source lock). A binary whose sha256 is no pinned object is MISSING:
untracking it would lose the only copy. Runtime locks pin transformed output, so they usually cover nothing; a source lock covers all.
Exit 0 only when nothing is missing."""
import base64, hashlib, json, os, subprocess, sys, urllib.request

BIN = (".bin", ".glb", ".png", ".jpg", ".jpeg", ".webp", ".ogg", ".wav", ".mp3", ".ktx2", ".blend", ".hdr", ".exr", ".bsp")


def get(u):
    return urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "gs-cloud-lock-verify/2"}), timeout=60).read()


def main(argv):
    if not argv or argv[0].startswith("--"): sys.exit(__doc__)
    repo = argv[0]
    lockname = argv[argv.index("--lock") + 1] if "--lock" in argv else "content.lock.json"
    lp = lockname if os.path.isabs(lockname) else os.path.join(repo, lockname)
    lock = json.load(open(lp)) if os.path.exists(lp) else None
    files = [f for f in subprocess.check_output(["git", "-C", repo, "ls-files", "-z"]).decode().split("\0") if f.lower().endswith(BIN)]
    hs = {f: hashlib.sha256(open(os.path.join(repo, f), "rb").read()).hexdigest() for f in files}
    cdn = {}
    for p in (lock or {}).get("packs", []):
        try:
            env = json.loads(get("%s/%s/%s/manifest.json" % (lock["origin"].rstrip("/"), p["id"], p["version"])))
            pl = env["payload"]; m = json.loads(base64.urlsafe_b64decode(pl + "=" * (-len(pl) % 4)))
            for x in m["files"]: cdn[x["sha256"]] = p["id"] + ":" + x["path"]
        except Exception as e:
            print("MANIFEST FAIL", p["id"], p["version"], e)
    miss = [f for f in files if hs[f] not in cdn]
    print(repo, "tracked binaries", len(files), "covered by hash", len(files) - len(miss), "missing", len(miss), "cdn objects", len(cdn))
    for f in miss[:15]: print("  MISSING", f)
    return 1 if miss else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
