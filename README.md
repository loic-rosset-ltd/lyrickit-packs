# LyricKit dictionary packs

Downloadable dictionary packs for LyricKit. Each pack is a complete dictionary —
every headword and every sense, not a trimmed subset — in the DMA container
format, published as a release asset and resolved through [`manifest.json`](manifest.json).

| pack | source | headwords | size | licence |
| --- | --- | --- | --- | --- |
| [`en-1.dma`](https://github.com/loic-rosset-ltd/lyrickit-packs/releases/download/v1/en-1.dma) | WordNet 3.1 | 147,478 | 9,505,682 B (9.1 MB) | [WordNet 3.1](LICENSE-WordNet-3.1.txt) |
| [`fr-1.dma`](https://github.com/loic-rosset-ltd/lyrickit-packs/releases/download/v1/fr-1.dma) | French Wiktionary (Wiktionnaire), via [kaikki.org](https://kaikki.org/) | 1,931,709 | 97,116,387 B (92.6 MB) | [CC BY-SA 3.0](LICENSE-CC-BY-SA-3.0.txt) |

```
SHA-256  75bc2fd45243d1b2a9b1d48e44c677f5497bb44e0103be7ddd9e829a14ee6c37  en-1.dma
SHA-256  9233424b55cfef9d07e476ce888da75c33797154583a53eaf91f11c0e840c7a7  fr-1.dma
```

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
/meta.json              language, revision, bucket width
/define/<n letters>.jsonl   one JSON record per headword
/rhyme/<tail>.txt           word ⇥ phonemes ⇥ syllables ⇥ rank
```

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
realpack build fr_complete.jsonl fr-2.dma fr 3 fr_50k.txt
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
realpack build en_complete.jsonl en-2.dma en 2 en_50k.txt
```

A French build takes about eight minutes and peaks around 2.3 GB RSS, because
`DMAVolume.create` assembles the whole archive in memory before writing it
atomically.

## Publishing a new revision

1. Build the pack and record its **exact byte count**. A consumer checks the
   size before opening the archive, so a truncated download is caught as a
   truncation rather than surfacing later as a word that mysteriously has no
   definition.
2. Upload it as a release asset named `<lang>-<revision>.dma`.
3. Bump `revision` in `manifest.json` and update `url`, `bytes` and `headwords`.
   A new revision installs alongside the old one rather than overwriting it
   mid-write.

The manifest is the only URL a consumer compiles in, which is what keeps hosting
movable: publish a new manifest and the packs can live anywhere.
