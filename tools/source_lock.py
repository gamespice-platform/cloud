#!/usr/bin/env python3
"""Source locks: tie a source store pack (publish_pack.sh --source-lock) to the tree it was built from.
  source_lock.py check  MANIFEST SRC            every file the manifest lists must exist under SRC with the listed sha256 and size
  source_lock.py record MANIFEST SRC LOCK ID    check, then write the sha256 of every file into LOCK's "source_files"[ID]
MANIFEST is the signed envelope (manifest.json); its payload is read, the signature is not judged here (lock_verify pins the whole
manifest by sha256). Tracked files of SRC that the pack does not list (hidden entries, ignored dirs) are warned about, not failed."""
import base64, hashlib, json, os, subprocess, sys


def files_of(manifest_path):
    env = json.load(open(manifest_path))
    pl = env.get("payload")
    m = json.loads(base64.urlsafe_b64decode(pl + "=" * (-len(pl) % 4))) if pl else env  # unsigned manifests are the bare dictionary
    return {f["path"]: (f["sha256"], f["size"]) for f in m["files"]}


def check(manifest, src):
    want = files_of(manifest)
    bad = 0
    for path, (sha, size) in sorted(want.items()):
        p = os.path.join(src, path)
        data = open(p, "rb").read() if os.path.isfile(p) else None
        if data is None:
            print("source_lock: %s is in the pack but not in %s" % (path, src), file=sys.stderr); bad += 1
        elif hashlib.sha256(data).hexdigest() != sha or len(data) != size:
            print("source_lock: %s differs from the pack's bytes" % path, file=sys.stderr); bad += 1
    try:
        tracked = subprocess.check_output(["git", "-C", src, "ls-files", "-z"], stderr=subprocess.DEVNULL).decode().split("\0")
        left = [t for t in tracked if t and t not in want]
        if left:
            print("source_lock: warning: %d tracked file(s) are not in the source pack (first: %s)" % (len(left), left[0]), file=sys.stderr)
    except (subprocess.CalledProcessError, OSError):
        pass
    if bad:
        return 1
    print("source_lock: %d file(s) in the pack are byte-identical to %s" % (len(want), src))
    return 0


def record(manifest, src, lock, pid):
    if check(manifest, src):
        return 1
    doc = json.load(open(lock)) if os.path.exists(lock) else {}
    # the site prefixes the owner (gamemann/zz-medieval-weapons): key source_files by the lock entry's own id, as lock_verify reads it
    ent = [p["id"] for p in doc.get("packs", []) if p.get("id") == pid or str(p.get("id")).endswith("/" + pid)]
    if len(ent) != 1:
        print("source_lock: %s has no entry for %s (a held upload writes none; run relock, then record again)" % (lock, pid), file=sys.stderr)
        return 1
    pid = ent[0]
    doc.setdefault("source_files", {})[pid] = {p: s for p, (s, _) in sorted(files_of(manifest).items())}
    doc["source"] = True
    with open(lock, "w") as f:
        json.dump(doc, f, indent="\t", sort_keys=True); f.write("\n")
    print("source_lock: %s records %d file hash(es) for %s" % (lock, len(doc["source_files"][pid]), pid))
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == "check": sys.exit(check(a[1], a[2]))
    if len(a) == 5 and a[0] == "record": sys.exit(record(*a[1:]))
    sys.exit(__doc__)
