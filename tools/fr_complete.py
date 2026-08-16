#!/usr/bin/env python3
"""frwiktionary (kaikki JSONL) -> `word<TAB>json` TSV, one row per part of speech.

    curl -s --compressed <the frwiktionary extract> | python3 fr_complete.py fr_all.tsv

**Streamed, and it has to be.** The source is 3.17 GB and holding the French
Wiktionary in a dict costs several GB of RSS, so this writes one flat row per
entry and lets `sort(1)` do the grouping on disk — `fr_merge.py` then folds the
sorted rows into one record per headword. Nothing here ever holds more than a
single line.

No trim: every headword and every sense (`LyricKit_Spec.md` §7.1). That is why
the pack has 2.03 million headwords against English's 147 thousand — in French
every inflected form is its own Wiktionary entry, and for a lyric app that is a
feature, because a writer looks up the conjugated word they actually wrote.

The emitted JSON is one part-of-speech blob:

    {"p":pos,"n":[{"g":[gloss],"x":[example],"s":[syn],"a":[ant]}],"i":[ipa]}

`json.dumps` escapes tabs and newlines inside strings, so the TSV framing
survives glosses containing either.
"""
import json
import sys
import unicodedata

""" — and nothing is capped. An earlier draft kept only three examples per sense,
which is defensible as a size trade and is still the wrong call to make here:
§7.1 says a pack is complete, and quietly trading completeness for megabytes is
exactly the decision that rule exists to prevent. It cost 55 MB of payload."""


def ipa(entry):
    """`\\a.kœj\\` -> `a.kœj`, de-duplicated, keeping the source's order."""
    out = []
    for sound in entry.get("sounds", []):
        raw = sound.get("ipa")
        if not raw:
            continue
        text = raw.strip().strip("\\").strip()
        if text and text not in out:
            out.append(text)
    return out


def senses(entry):
    out = []
    for sense in entry.get("senses", []):
        glosses = [g for g in sense.get("glosses", []) if g]
        examples = [e.get("text", "") for e in sense.get("examples", []) if e.get("text")]
        if not glosses and not examples:
            continue
        record = {"g": glosses}
        if examples:
            record["x"] = examples
        out.append(record)
    return out


def words(entry, key):
    """Synonyms/antonyms are `[{"word": ...}]` at the entry level, not the sense
    level, in this extract — so they attach to every sense or to none. They go on
    the part of speech's first sense, which is where a reader looks."""
    out = []
    for item in entry.get(key, []):
        word = item.get("word")
        if word and word not in out:
            out.append(word)
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: fr_complete.py <out.tsv>   (reads the extract on stdin)")

    written = skipped = 0
    # Kept only to explain the headword count against the number on record.
    # Folding `Paris`/`paris` and precomposed/decomposed `é` together is required
    # — `define` searches for a normalised needle — but it *reduces* the headword
    # count, so the two numbers have to be reported side by side or the pack
    # looks like it lost words.
    raw_words, folded_words = set(), set()
    with open(sys.argv[1], "w", encoding="utf-8") as out:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                skipped += 1
                continue
            raw = entry.get("word") or ""
            word = raw
            # The headword is lowercased and NFC-normalised here and nowhere
            # else, because `DictionaryPack.define` finds a record by searching
            # its bucket for the literal needle `"w":"<normalised word>"`. A
            # payload storing `Français` or a decomposed `é` is a payload whose
            # entries cannot be found at all.
            word = unicodedata.normalize("NFC", word).lower().strip()
            if not word or "\t" in word or "\n" in word:
                skipped += 1
                continue

            body = senses(entry)
            if not body:
                skipped += 1
                continue
            synonyms, antonyms = words(entry, "synonyms"), words(entry, "antonyms")
            if synonyms:
                body[0]["s"] = synonyms
            if antonyms:
                body[0]["a"] = antonyms

            blob = {"p": entry.get("pos") or "", "n": body}
            sounds = ipa(entry)
            if sounds:
                blob["i"] = sounds
            raw_words.add(raw)
            folded_words.add(word)
            out.write(word)
            out.write("\t")
            out.write(json.dumps(blob, ensure_ascii=False, separators=(",", ":")))
            out.write("\n")
            written += 1
            if written % 500_000 == 0:
                print(f"  {written} rows...", file=sys.stderr)

    print(f"{written} rows -> {sys.argv[1]} ({skipped} skipped)", file=sys.stderr)
    print(f"distinct headwords: {len(raw_words)} raw, {len(folded_words)} after "
          f"lowercase+NFC folding ({len(raw_words) - len(folded_words)} merged)",
          file=sys.stderr)


if __name__ == "__main__":
    main()
