#!/usr/bin/env python3
"""Sorted `word<TAB>json` rows -> one JSON record per headword.

    LC_ALL=C sort -t$'\\t' -k1,1 -S 2G fr_all.tsv | python3 fr_merge.py fr_complete.jsonl

The sort is what makes this streamable: rows for one headword arrive together,
so only the group in hand is ever in memory. `LC_ALL=C` is not optional — a
locale-aware sort would collate `é` next to `e` and scatter a headword's rows,
and this only ever compares for equality with the previous line, so scattered
rows would silently become several truncated records for the same word.

Output is the shape `PackEntry` decodes, identical to the English side:

    {"w":word,"p":[{"p":pos,"n":[...],"i":[...]}, ...]}
"""
import json
import sys


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: fr_merge.py <out.jsonl>   (reads sorted TSV on stdin)")

    written = 0
    with open(sys.argv[1], "w", encoding="utf-8") as out:
        current = None
        parts = []

        def flush():
            nonlocal written
            if current is None:
                return
            out.write(json.dumps({"w": current, "p": parts},
                                 ensure_ascii=False, separators=(",", ":")))
            out.write("\n")
            written += 1
            if written % 500_000 == 0:
                print(f"  {written} headwords...", file=sys.stderr)

        for line in sys.stdin:
            word, tab, blob = line.rstrip("\n").partition("\t")
            if not tab:
                continue
            try:
                part = json.loads(blob)
            except ValueError:
                continue
            if word != current:
                flush()
                current, parts = word, []
            parts.append(part)
        flush()

    print(f"{written} headwords -> {sys.argv[1]}", file=sys.stderr)


if __name__ == "__main__":
    main()
