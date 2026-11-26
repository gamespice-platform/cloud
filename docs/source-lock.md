Source lock: pin the tracked bytes, not the published output.

A normal pack lock (content.lock.json) pins the transformed store output: imported form, rewritten res:// paths, no import sources, no .import/.md files. Those bytes differ from the files tracked in git, so a lock alone cannot replace a tracked binary (`git rm --cached` would delete the only copy). A source lock fixes that.

## Publish

    GS_CLI_TOKEN=... tools/publish_pack.sh --source DIR --id my-pack-source \
        --bump patch --source-lock source.lock.json

`--source-lock FILE` publishes DIR with `--raw` (no import, no path rewrite, no exclusions, import sources kept) as `kind: store`, and checks the built manifest against the tree first (`tools/source_lock.py check`), so upload never happens if a byte would differ. After upload `source_lock.py record` writes FILE: the normal lock entry plus a top-level `source_files: {id: {path: sha256}}` map. The content lock is not touched. `--dry-run` only runs the check. Hidden dotfiles are not packed (GSPaths skips them); the check warns about tracked files left out.

## Verify and restore

    tools/lock_verify.sh --lock source.lock.json --tree DIR     # tree bytes == lock
    tools/lock_verify.sh --lock source.lock.json --fetch DIR    # restore from the CDN by hash

lock_verify also requires manifest paths and hashes to equal `source_files`.

## Coverage

    python3 tools/lock_cover.py REPO [--lock FILE]

Hashes the tracked binaries of REPO and looks each up among the object hashes of the pinned manifests. Exit 1 means some binary is only in git and must not be untracked yet.

Order of work for a repo: publish source pack, `--fetch` into a scratch dir, compare with the tree byte for byte, run lock_cover, only then untrack.
