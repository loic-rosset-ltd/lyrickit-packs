# LyricKit dictionary packs

Downloadable dictionary packs for LyricKit. Each pack is a complete dictionary —
every headword and every sense, not a trimmed subset — in the DMA container
format, published as a release asset and resolved through [`manifest.json`](manifest.json).

| pack | source | headwords | size | licence |
| --- | --- | --- | --- | --- |
| [`en-2.dma`](https://github.com/loic-rosset-ltd/lyrickit-packs/releases/download/v2/en-2.dma) | WordNet 3.1 | 147,478 | 9,497,278 B (9.1 MB) | [WordNet 3.1](LICENSE-WordNet-3.1.txt) |
| [`fr-2.dma`](https://github.com/loic-rosset-ltd/lyrickit-packs/releases/download/v2/fr-2.dma) | French Wiktionary (Wiktionnaire), via [kaikki.org](https://kaikki.org/) | 1,931,709 | 97,174,119 B (92.7 MB) | [CC BY-SA 3.0](LICENSE-CC-BY-SA-3.0.txt) |

```
SHA-256  42e27b7a423d20cb47f5f0bff540f215983081b5c6beb443247ea49a96f5ee69  en-2.dma
SHA-256  7099135ec72d2615efc31ad4d207deb3574b0d4fca2c06d92218416318891876  fr-2.dma
```

## What changed in revision 2

The dictionaries did not. Same headwords, same senses, same phonetics, same
frequency ranks — **every rhyme bucket is simply written in rank order now**, and
`/meta.json` says so with `"rhymeOrder": "rank"`.

That declaration is worth a revision because of what a reader can do with it. A
rhyme query wants the best ninety of a bucket that can hold 206,164 words, and the
ranked words are exactly the ones a writer will be offered — so a reader given the
promise can decode a thousand lines and stop, instead of decoding all of them to
build an array. Measured on the French pack, the **first** query on a common
ending falls from ~480 ms to ~135 ms, and what remains is the lzma inflate of the
block, which is a floor no ordering can move.

Two properties this revision was checked against, rather than reasoned into:

- **The answers are identical.** The on-disk order is the same ordering a reader
  has always applied to an unsorted bucket. Thirty words across both languages
  return the same candidate set, the same ranked hits and the same definitions
  from revision 1 and revision 2.
- **Older apps keep working.** `rhymeOrder` is a new optional field and not a
  layout change — the line format, the paths and the bucketing are untouched, so
  `layoutVersion` is still `1`. A build that has never heard of the field ignores
  it and sorts the bucket as it always did; run against the previously shipping
  reader over 58 words, hits and definitions were identical throughout. A pack
  and an app can be updated in either order.

Revision 1 remains downloadable at [its release](https://github.com/loic-rosset-ltd/lyrickit-packs/releases/tag/v1).

## The decryption seed is published, deliberately

Both packs are encrypted with DMA cipher `0x02` (`aesGCMSeed`), and the seed is
published right here:

```
lyrickit-pack-seed-v1-published-with-the-licence
```

This is not an oversight and it is not obfuscation. CC BY-SA 3.0 §4(a) forbids
imposing *effective technological measures* that restrict a recipient's exercise
of the rights the licence grants. A decryption key printed beside the download
restricts nothing, provably — anyone can open these files. The cipher is there
because DMA's block volume, which is what makes a 92 MB dictionary answer a
lookup in milliseconds without inflating the whole archive, runs over an
encrypted container; the per-block AES-GCM tag is a useful side effect, since a
corrupted download fails loudly instead of quietly missing words.

The seed also travels in the manifest, so a re-keyed pack needs no app update.

## Attribution

**French** — derived from the French Wiktionary (Wiktionnaire),
<https://fr.wiktionary.org>, © its contributors, licensed
[CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/). Extracted via
[kaikki.org](https://kaikki.org/frwiktionary/). **Changes were made:** entries
were reduced to headword, part of speech, glosses, examples, synonyms, antonyms
and IPA; headwords were folded to lowercase NFC; the result was reorganised into
the pack format described below. This pack is offered under the same licence.

**English** — WordNet 3.1, Copyright 2011 by Princeton University, all rights
reserved. The full licence is in [`LICENSE-WordNet-3.1.txt`](LICENSE-WordNet-3.1.txt)
and, as that licence requires, accompanies every copy of this data. **Changes
were made:** the same reduction and reorganisation as above.

Frequency ranks come from [`hermitdave/FrequencyWords`](https://github.com/hermitdave/FrequencyWords)
(`content/2018/{en,fr}/*_50k.txt`). They are a **sort key only** — nothing is
filtered out of a pack by them.

## What is in a pack

A DMA volume with three regions:

```
/meta.json              language, revision, bucket width, rhyme order
/define/<n letters>.jsonl   one JSON record per headword
/rhyme/<tail>.txt           word ⇥ phonemes ⇥ syllables ⇥ rank
```

`rank` is optional per line and absent far more often than not — a 50k frequency
list cannot name a two-million-headword dictionary's inflected forms, and a line
without one reads as "unknown" and sorts last. `rhymeOrder` in `/meta.json` says
whether the lines in a `/rhyme/` file are already ordered by it (`rank`) or say
nothing (`unspecified`, which is what every revision 1 pack is, and what an absent
field means). A reader must treat an order it does not recognise as
`unspecified`: an order you cannot name is an order you cannot rely on.

Definitions are bucketed by the first *n* letters of the normalised headword,
where *n* is `bucketWidth` in `/meta.json` — **2 for English, 3 for French**.
Because DMA compresses per file rather than solid, a bucket is the unit that
gets inflated to answer a lookup, so the width is a direct latency/size trade:
French at width 2 puts 45 MB behind a single common prefix, and at width 4 it
costs 19 MB more for an improvement nobody can perceive.

The rhyme index is bucketed by rhyme tail — the phonemes from a word's last
vowel onward — which is **exact rather than approximate**: a tail always starts
at the last vowel, so it holds exactly one vowel and holds it first; any word
ending with the target's tail therefore has that same tail itself. "Words in the
bucket" and "words that rhyme" are the same set, so a rhyme query is one read
instead of a scan of two million headwords.

Each record:

```json
{"w": word, "p": [{"p": pos, "n": [{"g": [gloss], "x": [example], "s": [syn], "a": [ant]}], "i": [ipa]}]}
```

## Rebuilding a pack

`tools/` holds everything that made these files. The generators are plain
Python 3 with no dependencies; the rig is a SwiftPM package that needs a
checkout of LyricKit and DragonArchive beside it, so it builds inside that
workspace and not on its own.

French — **streamed, never downloaded**, which is why 3.17 GB of source never
occupies 3.17 GB of disk:

```sh
curl -s --compressed https://kaikki.org/frwiktionary/Français/kaikki.org-dictionary-Français.jsonl \
  | python3 tools/fr_complete.py fr_all.tsv
LC_ALL=C sort -t$'\t' -k1,1 -S 2G fr_all.tsv | python3 tools/fr_merge.py fr_complete.jsonl
realpack build fr_complete.jsonl fr-3.dma fr 3 fr_50k.txt
```

`LC_ALL=C` is not decoration: `fr_merge.py` groups only *adjacent* rows, so a
locale-aware sort that collates `é` beside `e` would scatter a headword's rows
and silently emit several truncated records for it. Use the **frwiktionary**
extract above, whose glosses are in French — `kaikki.org/dictionary/French` is
the *English* Wiktionary's French entries and defines `gratis` as "free, without
charge".

English is small enough to group in memory, so it is one step:

```sh
curl -sL -O https://wordnetcode.princeton.edu/wn3.1.dict.tar.gz && tar xzf wn3.1.dict.tar.gz
python3 tools/wn_complete.py dict en_complete.jsonl
realpack build en_complete.jsonl en-3.dma en 2 en_50k.txt
```

A French build takes about eight minutes and peaks around 2.3 GB RSS, because
`DMAVolume.create` assembles the whole archive in memory before writing it
atomically.

## A revision that only reorders needs no source data

Revision 2 was produced from revision 1, not rebuilt from Wiktionary:

```sh
realpack resort fr-1.dma fr-2.dma
```

A `.dma` already carries every field the rank order is computed from, so
re-cutting is a transformation of the pack rather than a re-run of the 3.17 GB
pipeline above — twenty seconds of sorting and four minutes of writing the
archive, against eight minutes and a download. `resort` re-emits every block
unchanged except the `/rhyme/` files, which it stably sorts by rank, and
`/meta.json`, which it decodes through the pack's own type so the new file cannot
claim a headword count the old one did not.

Prove a reordering revision before publishing it, with both packs in hand:

```sh
realpack compare fr-1.dma fr-2.dma fr jamais chanter aimer toi nuit amour temps
realpack first   fr-2.dma fr jamais chanter toi          # what the change bought
```

`compare` asks two packs the same questions and checks the candidate set, the
ranked hits *and* the definitions, because those fail for different reasons: the
first catches a lost or duplicated line, the second an ordering that is subtly not
stable, the third a block that did not survive the pass-through.

## Publishing a new revision

1. Build or resort the pack and record its **exact byte count**. A consumer checks
   the size before opening the archive, so a truncated download is caught as a
   truncation rather than surfacing later as a word that mysteriously has no
   definition.
2. Upload it as a release asset named `<lang>-<revision>.dma`. **Do this before
   step 3** — the manifest is fetched continuously and must never name an asset
   that is not there yet.
3. Bump `revision` in `manifest.json` and update `url`, `bytes` and `headwords`.
   A new revision installs alongside the old one rather than overwriting it
   mid-write; the consumer deletes the superseded file once the new one opens.

The manifest is the only URL a consumer compiles in, which is what keeps hosting
movable: publish a new manifest and the packs can live anywhere.
