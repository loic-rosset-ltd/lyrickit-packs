#!/usr/bin/env python3
"""WordNet 3.1 `dict/` -> the complete English payload, one JSON record per line.

    tar xzf wn3.1.dict.tar.gz && python3 wn_complete.py dict/ en_complete.jsonl

Complete means every lemma, every sense, every example and every synset
synonym — no frequency trim (`LyricKit_Spec.md` §7.1: *a pack is complete*).

The record shape is shared with the French side so the two packs are built by
one code path:

    {"w":word,"p":[{"p":pos,"n":[{"g":[gloss],"x":[example],"s":[syn]}]}]}

The headword is lowercased and NFC-normalised because `DictionaryPack.define`
looks a word up by searching the bucket for the literal needle `"w":"<word>"`
after normalising it the same way. A payload that stores `Français` is a payload
whose French entries cannot be found at all.
"""
import json
import sys
import unicodedata
from collections import OrderedDict

# `data.*` lines: everything up to the first ` | ` is the synset, the rest is
# the gloss. A leading run of digits is the byte offset; lines starting with a
# space are the licence header.
POS = {"n": "noun", "v": "verb", "a": "adj", "s": "adj", "r": "adv"}


def split_gloss(text):
    """WordNet's gloss field -> (definitions, examples).

    The field is semicolon-separated, quoted segments being usage examples and
    unquoted ones definitions — and there can be several of each. Splitting on
    the *first* semicolon and calling the rest examples loses every definition
    that contains one ("a small drum; a tambour"), which is a silent truncation
    of the thing the pack exists to carry. Quotes are tracked so a semicolon
    inside an example does not split it either.
    """
    segments, current, quoted = [], [], False
    for char in text:
        if char == '"':
            quoted = not quoted
            current.append(char)
        elif char == ";" and not quoted:
            segments.append("".join(current))
            current = []
        else:
            current.append(char)
    segments.append("".join(current))

    definitions, examples = [], []
    for segment in segments:
        segment = segment.strip()
        if not segment:
            continue
        if segment.startswith('"'):
            examples.append(segment.strip('"').strip())
        else:
            definitions.append(segment)
    return definitions, [e for e in examples if e]


def lemma(raw):
    """`carbon_dioxide` -> `carbon dioxide`; `good(a)` -> `good`."""
    word = raw.split("(")[0].replace("_", " ")
    return unicodedata.normalize("NFC", word).lower()


def parse(path):
    """Yields (word, pos, gloss, examples, synonyms) for every sense."""
    for suffix in ("noun", "verb", "adj", "adv"):
        with open(f"{path}/data.{suffix}", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("  "):
                    continue
                body, _, tail = line.partition(" | ")
                fields = body.split()
                if len(fields) < 4:
                    continue
                pos = POS.get(fields[2], fields[2])
                # w_cnt is hexadecimal, and each word is followed by its lex_id.
                try:
                    count = int(fields[3], 16)
                except ValueError:
                    continue
                words = [fields[4 + 2 * i] for i in range(count)
                         if 4 + 2 * i < len(fields)]
                definitions, examples = split_gloss(tail.strip())
                names = [lemma(w) for w in words]
                for i, word in enumerate(names):
                    if word:
                        yield word, pos, definitions, examples, [
                            n for j, n in enumerate(names) if j != i and n
                        ]


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: wn_complete.py <dict dir> <out.jsonl>")
    src, out = sys.argv[1], sys.argv[2]

    # WordNet is small enough (147k lemmas, 31 MB of glosses) to group in
    # memory. French is not, which is why it takes the sort-on-disk route.
    entries = OrderedDict()
    for word, pos, definitions, examples, synonyms in parse(src):
        parts = entries.setdefault(word, OrderedDict())
        sense = {"g": definitions}
        if examples:
            sense["x"] = examples
        if synonyms:
            sense["s"] = synonyms
        parts.setdefault(pos, []).append(sense)

    with open(out, "w", encoding="utf-8") as fh:
        for word, parts in entries.items():
            record = {"w": word,
                      "p": [{"p": pos, "n": senses} for pos, senses in parts.items()]}
            fh.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
            fh.write("\n")
    print(f"{len(entries)} lemmas -> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
