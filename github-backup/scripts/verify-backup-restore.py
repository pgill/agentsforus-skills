#!/usr/bin/env python3
"""Verify a restored agent workspace is byte-faithful to its source.

Counts matching is NOT verification -- SQLite column affinity can silently
coerce values (float timestamps truncated into TEXT) while every row count
still lines up perfectly. This compares content digests.

Usage:
    verify-backup-restore.py --source /data/.hermes --restored /tmp/fresh
    verify-backup-restore.py --source /data/.hermes --restored /tmp/fresh --fts

Exit 0 = all message data identical. Exit 1 = mismatch (prints first diffs).
"""
import argparse
import hashlib
import pathlib
import sqlite3
import sys

MSG_COLS = ("session_id", "role", "content", "timestamp")


def find_dbs(root: pathlib.Path):
    return sorted(p for p in root.rglob("*.db") if ".git" not in p.parts)


def digest(db: pathlib.Path):
    """Return (row_count, sha256-prefix) over message content."""
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        tables = {r[0] for r in con.execute(
            "select name from sqlite_master where type='table'")}
        if "messages" not in tables:
            return None
        have = [r[1] for r in con.execute("pragma table_info(messages)")]
        cols = [c for c in MSG_COLS if c in have]
        order = "id" if "id" in have else "rowid"
        rows = con.execute(
            f"select {','.join(cols)} from messages order by {order}").fetchall()
    finally:
        con.close()
    h = hashlib.sha256()
    for r in rows:
        # repr() keeps type information -- a float 1780960253.0324667 and the
        # string '1780960253.03247' MUST hash differently. This is the check.
        h.update(repr(r).encode())
    return len(rows), h.hexdigest()[:16]


def first_diffs(src: pathlib.Path, rst: pathlib.Path, limit=3):
    def rows(db):
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        have = [r[1] for r in con.execute("pragma table_info(messages)")]
        cols = [c for c in MSG_COLS if c in have]
        order = "id" if "id" in have else "rowid"
        out = con.execute(
            f"select {order},{','.join(cols)} from messages order by {order}"
        ).fetchall()
        con.close()
        return cols, out

    cols, a = rows(src)
    _, b = rows(rst)
    shown = 0
    for ra, rb in zip(a, b):
        if ra == rb:
            continue
        shown += 1
        print(f"    --- diff at row id {ra[0]} ---")
        for i, name in enumerate(cols, start=1):
            if ra[i] != rb[i]:
                print(f"      field={name}")
                print(f"        source  ({type(ra[i]).__name__}): {repr(ra[i])[:120]}")
                print(f"        restored({type(rb[i]).__name__}): {repr(rb[i])[:120]}")
        if shown >= limit:
            break


def check_fts(db: pathlib.Path):
    """Confirm search is reconstructable from restored rows (index isn't backed up)."""
    con = sqlite3.connect(db)
    try:
        con.execute("create virtual table if not exists tmp_fts using fts5(content)")
        con.execute("insert into tmp_fts(content) "
                    "select content from messages where content is not null")
        con.commit()
        hits = {}
        for term in ("backup", "error", "the"):
            hits[term] = con.execute(
                "select count(*) from tmp_fts where tmp_fts match ?", (term,)
            ).fetchone()[0]
        con.execute("drop table tmp_fts")
        con.commit()
        return hits
    except sqlite3.Error as e:
        return {"error": str(e)}
    finally:
        con.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="live workspace root")
    ap.add_argument("--restored", required=True, help="restored workspace root")
    ap.add_argument("--fts", action="store_true",
                    help="also rebuild a throwaway FTS index and query it")
    args = ap.parse_args()

    src_root = pathlib.Path(args.source)
    rst_root = pathlib.Path(args.restored)
    for p in (src_root, rst_root):
        if not p.is_dir():
            sys.exit(f"not a directory: {p}")

    dbs = find_dbs(src_root)
    if not dbs:
        sys.exit(f"no *.db found under {src_root}")

    print(f"{'db':<46} {'source':>24}  {'restored':>24}  match")
    ok = True
    missing = []
    for sdb in dbs:
        rel = sdb.relative_to(src_root)
        rdb = rst_root / rel
        d1 = digest(sdb)
        if d1 is None:
            continue
        if not rdb.exists():
            missing.append(str(rel))
            ok = False
            print(f"{str(rel):<46} {d1[0]:>6} {d1[1]}  {'ABSENT':>24}   NO")
            continue
        d2 = digest(rdb)
        good = d1 == d2
        ok &= good
        print(f"{str(rel):<46} {d1[0]:>6} {d1[1]}  {d2[0]:>6} {d2[1]}  "
              f"{'YES' if good else 'NO'}")
        if not good and d1[0] == d2[0]:
            print("    counts match but content differs -> suspect column "
                  "affinity coercion (see SKILL.md fidelity section)")
            first_diffs(sdb, rdb)

    if args.fts:
        target = rst_root / dbs[0].relative_to(src_root)
        if target.exists():
            print(f"\nFTS rebuild check on {target.name}: {check_fts(target)}")

    if missing:
        print(f"\nmissing from restore: {missing}")
    print("\nRESULT:", "ALL MESSAGE DATA IDENTICAL" if ok else "MISMATCH DETECTED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
