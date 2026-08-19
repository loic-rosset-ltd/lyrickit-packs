import Foundation
import LyricKit
import LyricKitData
import DragonArchive

// realpack build   <in.jsonl> <out.dma> <en|fr> [bucketWidth]
// realpack measure <pack.dma>           <en|fr>
//
// Builds a pack in the real PackFormat layout — definitions bucketed per
// `bucketWidth` letters PLUS the rhyme index — and measures it *through the
// shipping DictionaryPack*, so the numbers are the ones a user would feel.
//
// `measure` exists so an already-built pack can be re-timed with the same code
// as a new one: the French pack takes ~7 minutes to build and comparing p2 with
// p3 across two different rigs would compare the rigs as much as the packs.

let SEED = "lyrickit-pack-seed-v1-published-with-the-licence"
func mib(_ n: Int) -> String { String(format: "%.2f MB", Double(n) / 1_048_576) }

let args = CommandLine.arguments
guard args.count >= 3 else {
    fatalError("usage: realpack build <in.jsonl> <out.dma> <en|fr> [width] | realpack measure <pack.dma> <en|fr>")
}
let mode = args[1]

// MARK: - Timing, shared by both modes

/// Words chosen two ways: the eight the earlier sessions timed, so the numbers
/// stay comparable, and eight more that land in the *largest* buckets, because
/// the median hides what a French writer actually hits. `re`, `dé` and `au` are
/// the three buckets that made per-2 untenable for French.
let probeWords: [Language: (typical: [String], worst: [String])] = [
    .french: (["aimer", "bonjour", "chanson", "danser", "etoile", "fleur", "guitare", "hiver"],
              ["reprendre", "revenir", "regarder", "décider", "désirer", "déchirer",
               "autoriser", "automne"]),
    .english: (["light", "moon", "heart", "stone", "river", "shadow", "winter", "golden"],
               ["stand", "start", "state", "storm", "string", "prove", "press", "print"])
]

func coldDefine(_ path: String, _ language: Language, _ words: [String], _ label: String) throws {
    // A fresh open per word: no cache, no shared warmup, nothing to hide behind.
    var times: [Double] = []
    var misses: [String] = []
    for w in words {
        let fresh = try DictionaryPack(url: URL(fileURLWithPath: path),
                                       language: PackLanguage(language), seed: SEED)
        let s = Date()
        let hit = fresh.define(w)
        times.append(Date().timeIntervalSince(s) * 1000)
        if hit == nil { misses.append(w) }
    }
    let sorted = times.sorted()
    print(String(format: "  cold define [%@] median %.1fms  min %.1fms  max %.1fms%@",
                 label, sorted[sorted.count / 2], sorted.first!, sorted.last!,
                 misses.isEmpty ? "" : "   (MISS: \(misses.joined(separator: ",")))"))
    print("    " + zip(words, times).map { "\($0)=\(String(format: "%.0f", $1))ms" }
            .joined(separator: " "))
}

func measure(_ path: String, _ language: Language) throws {
    let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    let pack = try DictionaryPack(url: URL(fileURLWithPath: path),
                                  language: PackLanguage(language), seed: SEED)
    print("PACK \(path)  \(mib(size))  (\(size) bytes)")
    print("  headwords \(pack.headwordCount)  bucketWidth \(pack.bucketWidth)")

    let probes = probeWords[language]!
    try coldDefine(path, language, probes.typical, "typical")
    try coldDefine(path, language, probes.worst, "worst buckets")

    // Warm: what a writer feels after the first lookup in a neighbourhood.
    for w in probes.typical + probes.worst { _ = pack.define(w) }
    var warm: [Double] = []
    for w in probes.typical {
        let s = Date()
        _ = pack.define(w)
        warm.append(Date().timeIntervalSince(s) * 1000)
    }
    print(String(format: "  warm define (memoised) median %.4fms", warm.sorted()[warm.count / 2]))

    // Rhyme search end to end — unaffected by define bucketing, measured so a
    // change to one is never mistaken for a change to the other.
    for probe in (language == .french ? ["aimer", "fleur", "nuit"] : ["light", "heart", "moon"]) {
        let tail = Rhyme.tail(Phonetics.phonemes(probe, language))
        let t = Date()
        let cands = pack.rhymeCandidates(tail: tail)
        let readMs = Date().timeIntervalSince(t) * 1000
        var q = RhymeQuery()
        q.source = PackCandidates(packs: [language: pack])
        q.limit = 50
        let s = Date()
        let hits = RhymeSearch.find(probe, language, q)
        print(String(format: "  rhyme %@: %d candidates read in %.0fms, find -> %d hits in %.0fms",
                     probe, cands.count, readMs, hits.count,
                     Date().timeIntervalSince(s) * 1000))
    }
}

// MARK: - resort
//
// realpack resort <in.dma> <out.dma>
//
// Reads a pack and writes the same pack with every rhyme bucket already in rank
// order, declaring it in `/meta.json` as `rhymeOrder: rank`. That declaration is
// what lets the reader decode a bucket a chunk at a time and stop, instead of
// decoding 206,164 lines to answer with ninety.
//
// ⚠️ **It does not need the source payload.** A v1 `.dma` carries every field the
// rank order is computed from, so re-cutting is a transformation of the pack
// rather than a rebuild from the 3.17 GB Wiktionary dump — which is the whole
// reason a revision like this is affordable at all.
//
// The sort is *exactly* the one `DictionaryPack` applies to an unsorted bucket:
// rank ascending, unranked last, ties in the order the lines were already in.
// Reproducing it rather than inventing a better one is the point — a v2 pack must
// answer identically to the v1 it came from, or the revision is a behaviour change
// wearing a performance change's clothes.

if mode == "resort" {
    guard args.count >= 4 else { fatalError("usage: realpack resort <in.dma> <out.dma>") }
    let inURL = URL(fileURLWithPath: args[2]), outURL = URL(fileURLWithPath: args[3])
    let source = try DMAVolume.open(url: inURL,
                                    keyProvider: EmbeddedSecretKeyProvider(secret: SEED))
    let inSize = (try FileManager.default.attributesOfItem(atPath: args[2])[.size] as? Int) ?? 0
    print("SOURCE \(args[2])  \(mib(inSize))  \(source.items.count) entries")

    let newline = UInt8(ascii: "\n")
    var entries: [DMAEntry] = []
    var rhymeBuckets = 0, rhymeLines = 0, movedLines = 0
    let started = Date()

    for item in source.items {
        let path = item.originalPath
        let body = try source.read(path: path).data

        var payload = body
        if path == PackFormat.metaPath {
            // Decoded and re-encoded through `PackMeta`, so the new pack cannot
            // claim a headword count or a bucket width the old one did not.
            var meta = try JSONDecoder().decode(PackMeta.self, from: body)
            meta.rhymeOrder = .rank
            payload = try JSONEncoder().encode(meta)
            print("  meta: language \(meta.language) headwords \(meta.headwords) "
                  + "width \(meta.bucketWidth) → rhymeOrder \(meta.rhymeOrder.rawValue)")
        } else if path.hasPrefix("/rhyme/") {
            let bytes = [UInt8](body)
            // Kept as byte ranges rather than `String`s: the biggest French
            // bucket is six megabytes, and the whole index is a hundred.
            var lines: [(rank: Int, order: Int, range: Range<Int>)] = []
            var i = bytes.startIndex
            while i < bytes.endIndex {
                let end = bytes[i...].firstIndex(of: newline) ?? bytes.endIndex
                if end > i {
                    let rank = PackFormat.parseRhymeLine(bytes[i..<end])?.rank ?? Int.max
                    lines.append((rank, lines.count, i..<end))
                }
                i = end < bytes.endIndex ? bytes.index(after: end) : bytes.endIndex
            }
            lines.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.order < $1.order }
            var out = [UInt8](); out.reserveCapacity(bytes.count)
            for (n, line) in lines.enumerated() {
                if n > 0 { out.append(newline) }
                out.append(contentsOf: bytes[line.range])
                if line.order != n { movedLines += 1 }
            }
            // A bucket must not change size: same lines, same separators, only
            // the order. If this ever trips, the walk above lost a line.
            guard out.count == bytes.count else {
                fatalError("\(path): re-emitted \(out.count) bytes from \(bytes.count)")
            }
            payload = Data(out)
            rhymeBuckets += 1
            rhymeLines += lines.count
        }
        entries.append(DMAEntry(originalPath: path, type: item.type, mode: item.mode,
                                owner: item.owner, group: item.group,
                                crc32: CRC32.checksum(payload), data: payload))
    }
    print(String(format: "  sorted %d rhyme buckets, %d lines, %d moved (%.1f%%) in %.1fs",
                 rhymeBuckets, rhymeLines, movedLines,
                 100 * Double(movedLines) / Double(max(rhymeLines, 1)),
                 Date().timeIntervalSince(started)))

    try? FileManager.default.removeItem(at: outURL)
    let buildStart = Date()
    _ = try DMAVolume.create(url: outURL,
                             keyProvider: EmbeddedSecretKeyProvider(secret: SEED),
                             motd: source.motd,
                             readme: "Dictionary pack.",
                             metadata: source.metadata,
                             entries: entries, compression: .lzma)
    let outSize = (try FileManager.default.attributesOfItem(atPath: args[3])[.size] as? Int) ?? 0
    print(String(format: "wrote %@  %@  (%d bytes) in %.1fs",
                 args[3], mib(outSize), outSize, Date().timeIntervalSince(buildStart)))
    exit(0)
}

// MARK: - conform
//
// realpack conform <pack.dma> <en|fr>
//
// ⚠️ Named `conform`, not `verify`, because `verify` was already taken — by the
// mode that proves the rank-order short-circuit returns the same words as an
// exhaustive run. A second `mode == "verify"` earlier in this file does not
// conflict at compile time; it silently makes the first one unreachable, and the
// only symptom is a tool that used to work quietly answering a different
// question. `conform` is also the right word: this is the conformance check for a
// pack, the way the fixtures are one for the port.
//
// Asks the one question a published pack cannot answer about itself: **does this
// pack still agree with the engine that reads it?**
//
// A pack keys its rhyme buckets on the tail computed at *build* time, so a fix
// to the transcriber puts the two out of step silently — the editor colours
// `grey` and `say` as a family while the lookup panel beside it offers neither
// for the other. Nothing in either test suite can see that: the pack is data and
// the suites test code.
//
// It needs no source payload. Every rhyme row carries its own headword, so the
// tail, the count and the phonemes can all be recomputed and compared in place.

if mode == "conform" {
    guard args.count >= 4 else { fatalError("usage: realpack conform <pack.dma> <en|fr>") }
    let language: Language = args[3] == "fr" ? .french : .english
    let v = try DMAVolume.open(url: URL(fileURLWithPath: args[2]),
                               keyProvider: EmbeddedSecretKeyProvider(secret: SEED))
    var rows = 0, movedBucket = 0, wrongSyllables = 0, wrongPhonemes = 0, nowSilent = 0
    var examples: [String] = []
    let started = Date()
    for item in v.items where item.originalPath.hasPrefix("/rhyme/") {
        let path = item.originalPath
        let bucket = String(path.dropFirst("/rhyme/".count).dropLast(".txt".count))
        for line in String(decoding: try v.read(path: path).data, as: UTF8.self).split(separator: "\n") {
            guard let row = PackFormat.parseRhymeLine(ArraySlice(Array(line.utf8))) else { continue }
            rows += 1
            let now = Phonetics.phonemes(row.word, language)
            if now.isEmpty { nowSilent += 1; continue }
            let wantBucket = String(PackFormat.rhymePath(tail: Rhyme.tail(now))
                .dropFirst("/rhyme/".count).dropLast(".txt".count))
            let wantSyllables = Phonetics.syllables(row.word, language)
            if wantBucket != bucket {
                movedBucket += 1
                if examples.count < 30 { examples.append("\(row.word): /\(bucket)/ -> /\(wantBucket)/") }
            }
            if wantSyllables != row.syllables { wrongSyllables += 1 }
            if now != row.phonemes { wrongPhonemes += 1 }
        }
    }
    print("PACK \(args[2])  \(rows) rhyme rows  checked in "
          + String(format: "%.1fs", Date().timeIntervalSince(started)))
    print("  rows whose bucket the reader would no longer ask for: \(movedBucket)")
    print("  rows carrying a syllable count the reader disagrees with: \(wrongSyllables)")
    print("  rows whose phonemes the reader would transcribe differently: \(wrongPhonemes)")
    print("  rows the reader now transcribes to nothing at all: \(nowSilent)")
    for e in examples { print("    \(e)") }
    print(movedBucket == 0 && wrongSyllables == 0 && wrongPhonemes == 0 && nowSilent == 0
          ? "\nPACK AGREES WITH THIS READER" : "\nPACK IS OUT OF STEP WITH THIS READER")
    exit(movedBucket == 0 && wrongSyllables == 0 && wrongPhonemes == 0 && nowSilent == 0 ? 0 : 1)
}

// MARK: - diff
//
// realpack diff <a.dma> <b.dma>
//
// Compares two packs block for block, and the rhyme index row for row.
//
// `compare` asks two packs the same *questions*; this asks whether they hold the
// same *bytes*. Both are needed and neither implies the other: a revision can
// answer twenty probes identically while having quietly lost a bucket, and it can
// differ in every byte of a block whose answers never changed.
//
// The rhyme index is diffed structurally rather than by bytes, because "this
// block differs" is not a finding — the finding is which words moved bucket and
// which kept a syllable count that is no longer true.

if mode == "diff" {
    guard args.count >= 4 else { fatalError("usage: realpack diff <a.dma> <b.dma>") }
    let a = try DMAVolume.open(url: URL(fileURLWithPath: args[2]),
                               keyProvider: EmbeddedSecretKeyProvider(secret: SEED))
    let b = try DMAVolume.open(url: URL(fileURLWithPath: args[3]),
                               keyProvider: EmbeddedSecretKeyProvider(secret: SEED))
    print("A \(args[2])  \(a.items.count) blocks")
    print("B \(args[3])  \(b.items.count) blocks")

    let pathsA = Set(a.items.map(\.originalPath)), pathsB = Set(b.items.map(\.originalPath))
    let onlyA = pathsA.subtracting(pathsB).sorted(), onlyB = pathsB.subtracting(pathsA).sorted()
    print("blocks only in A: \(onlyA.count)\(onlyA.isEmpty ? "" : "  " + onlyA.prefix(12).joined(separator: " "))")
    print("blocks only in B: \(onlyB.count)\(onlyB.isEmpty ? "" : "  " + onlyB.prefix(12).joined(separator: " "))")

    /// word -> (bucket, syllables, phonemes, rank), read from every `/rhyme/` block.
    func rhymeRows(_ v: DMAVolume, _ paths: Set<String>) throws
        -> [String: (bucket: String, syllables: Int, phonemes: String, rank: Int?)] {
        var rows: [String: (bucket: String, syllables: Int, phonemes: String, rank: Int?)] = [:]
        for path in paths.sorted() where path.hasPrefix("/rhyme/") {
            let body = try v.read(path: path).data
            let bucket = String(path.dropFirst("/rhyme/".count).dropLast(".txt".count))
            for line in String(decoding: body, as: UTF8.self).split(separator: "\n") {
                guard let row = PackFormat.parseRhymeLine(ArraySlice(Array(line.utf8))) else { continue }
                rows[row.word] = (bucket, row.syllables, row.phonemes.joined(separator: " "), row.rank)
            }
        }
        return rows
    }
    let ra = try rhymeRows(a, pathsA), rb = try rhymeRows(b, pathsB)
    print("rhyme rows: A \(ra.count)  B \(rb.count)")

    let gone = Set(ra.keys).subtracting(rb.keys).sorted()
    let fresh = Set(rb.keys).subtracting(ra.keys).sorted()
    print("words only in A: \(gone.count)\(gone.isEmpty ? "" : "  " + gone.prefix(20).joined(separator: " "))")
    print("words only in B: \(fresh.count)\(fresh.isEmpty ? "" : "  " + fresh.prefix(20).joined(separator: " "))")

    var movedBucket: [(String, String, String)] = []
    var changedSyllables: [(String, Int, Int)] = []
    var changedPhonemesOnly: [(String, String, String)] = []
    var changedRank = 0
    for (word, rowA) in ra {
        guard let rowB = rb[word] else { continue }
        if rowA.bucket != rowB.bucket { movedBucket.append((word, rowA.bucket, rowB.bucket)) }
        if rowA.syllables != rowB.syllables { changedSyllables.append((word, rowA.syllables, rowB.syllables)) }
        if rowA.phonemes != rowB.phonemes, rowA.bucket == rowB.bucket, rowA.syllables == rowB.syllables {
            changedPhonemesOnly.append((word, rowA.phonemes, rowB.phonemes))
        }
        if rowA.rank != rowB.rank { changedRank += 1 }
    }
    movedBucket.sort { $0.0 < $1.0 }
    changedSyllables.sort { $0.0 < $1.0 }
    changedPhonemesOnly.sort { $0.0 < $1.0 }
    print("moved bucket:        \(movedBucket.count)")
    let cap = args.contains("--full") ? Int.max : 40
    for (w, x, y) in movedBucket.prefix(cap) { print("    \(w): /\(x)/ -> /\(y)/") }
    if movedBucket.count > cap { print("    … and \(movedBucket.count - cap) more") }
    print("changed syllables:   \(changedSyllables.count)")
    for (w, x, y) in changedSyllables.prefix(cap) { print("    \(w): \(x) -> \(y)") }
    if changedSyllables.count > cap { print("    … and \(changedSyllables.count - cap) more") }
    print("changed phonemes only (same bucket, same count): \(changedPhonemesOnly.count)")
    for (w, x, y) in changedPhonemesOnly.prefix(20) { print("    \(w): \(x) -> \(y)") }
    print("changed rank:        \(changedRank)")

    // Every non-rhyme block compared by bytes. `/define/` is the raw payload and
    // must be identical across a content revision that only re-transcribes.
    var differingBlocks: [String] = []
    for path in pathsA.intersection(pathsB).sorted() where !path.hasPrefix("/rhyme/") {
        if try a.read(path: path).data != b.read(path: path).data {
            differingBlocks.append(path)
            if path == PackFormat.metaPath {
                print("    A meta: " + String(decoding: try a.read(path: path).data, as: UTF8.self))
                print("    B meta: " + String(decoding: try b.read(path: path).data, as: UTF8.self))
            }
        }
    }
    print("non-rhyme blocks differing: \(differingBlocks.count)"
          + (differingBlocks.isEmpty ? "" : "  " + differingBlocks.prefix(10).joined(separator: " ")))
    // And the rhyme blocks, by bytes, so the structural diff above cannot hide a
    // pure reordering.
    var differingRhyme = 0
    for path in pathsA.intersection(pathsB).sorted() where path.hasPrefix("/rhyme/") {
        if try a.read(path: path).data != b.read(path: path).data { differingRhyme += 1 }
    }
    print("rhyme blocks differing by bytes: \(differingRhyme) of \(pathsA.intersection(pathsB).filter { $0.hasPrefix("/rhyme/") }.count)")
    exit(0)
}

// MARK: - compare
//
// realpack compare <a.dma> <b.dma> <en|fr> <word> [word…]
//
// Asks two packs the same questions and compares the answers word for word.
//
// A pack revision that reorders anything has to prove it did not *change*
// anything, and the reasoning that says it cannot — the on-disk sort is the same
// ordering the reader applies to an unsorted bucket — is an argument. This is the
// measurement. It compares the full candidate list as well as the ranked answer,
// because the two can differ for different reasons: the first catches a lost or
// duplicated line, the second catches an ordering that is subtly not stable.

if mode == "compare" {
    guard args.count >= 6 else {
        fatalError("usage: realpack compare <a.dma> <b.dma> <en|fr> <word> [word…]")
    }
    let language: Language = args[4] == "fr" ? .french : .english
    let a = try DictionaryPack(url: URL(fileURLWithPath: args[2]),
                               language: PackLanguage(language), seed: SEED)
    let b = try DictionaryPack(url: URL(fileURLWithPath: args[3]),
                               language: PackLanguage(language), seed: SEED)
    print("A \(args[2])  headwords \(a.headwordCount)  width \(a.bucketWidth)")
    print("B \(args[3])  headwords \(b.headwordCount)  width \(b.bucketWidth)")

    var failures = 0
    for probe in args[5...] {
        let tail = Rhyme.tail(Phonetics.phonemes(probe, language))
        let ca = a.rhymeCandidates(tail: tail).map(\.word)
        let cb = b.rhymeCandidates(tail: tail).map(\.word)
        let sameBucket = ca == cb

        var qa = RhymeQuery(); qa.source = PackCandidates(packs: [language: a]); qa.limit = 90
        var qb = RhymeQuery(); qb.source = PackCandidates(packs: [language: b]); qb.limit = 90
        let ha = RhymeSearch.find(probe, language, qa)
        let hb = RhymeSearch.find(probe, language, qb)
        let sameHits = ha == hb

        // And the same definition, since resorting rewrites every block in the
        // archive and a pass-through that quietly dropped one would look fine
        // from the rhyme side alone.
        let sameDefinition = a.define(probe)?.allGlosses == b.define(probe)?.allGlosses

        if !(sameBucket && sameHits && sameDefinition) { failures += 1 }
        print(String(format: "%-12@ bucket %@ (%d)   hits %@ (%d)   define %@",
                     probe as NSString,
                     sameBucket ? "SAME" : "*** DIFFERS ***", ca.count,
                     sameHits ? "SAME" : "*** DIFFERS ***", ha.count,
                     sameDefinition ? "SAME" : "*** DIFFERS ***"))
        if !sameHits {
            print("      A: " + ha.prefix(12).map(\.word).joined(separator: " "))
            print("      B: " + hb.prefix(12).map(\.word).joined(separator: " "))
        }
        if !sameBucket, let i = zip(ca, cb).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
            print("      first divergence at \(i.offset): A=\(i.element.0) B=\(i.element.1)")
        }
    }
    print(failures == 0 ? "\nALL IDENTICAL" : "\n\(failures) DIFFER")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - first
//
// realpack first <pack.dma> <en|fr> <word> [word…]
//
// The cost a writer actually waits for: the **first** query on a rhyme ending, on
// a pack nobody has touched. `panel` cannot report this — it reads the bucket to
// count candidates before it times the search, so its "cold" number is warm. Here
// every probe gets a freshly opened pack and `RhymeSearch.find` is the first thing
// asked of it.
//
// The block read is timed separately, on another fresh pack, because it is the
// floor: it is the lzma inflate of the bucket and no ordering can remove it. The
// gap between the two columns is the decode, and the decode is what a pre-sorted
// pack lets the reader skip.

if mode == "first" {
    guard args.count >= 5 else { fatalError("usage: realpack first <pack.dma> <en|fr> <word> [word…]") }
    let language: Language = args[3] == "fr" ? .french : .english
    let url = URL(fileURLWithPath: args[2])

    func ms(_ body: () -> Void) -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000
    }

    print("word           find(cold)   blockRead   decode    candidates  hits")
    for probe in args[4...] {
        let tail = Rhyme.tail(Phonetics.phonemes(probe, language))

        let a = try DictionaryPack(url: url, language: PackLanguage(language), seed: SEED)
        var q = RhymeQuery(); q.source = PackCandidates(packs: [language: a]); q.limit = 90
        var hits = 0
        let find = ms { hits = RhymeSearch.find(probe, language, q).count }

        // A second untouched pack, so the read is not measured against a cache
        // the search above has already filled.
        let volume = try DMAVolume.open(url: url,
                                        keyProvider: EmbeddedSecretKeyProvider(secret: SEED))
        var readBytes = 0
        let read = ms { readBytes = ((try? volume.read(path: PackFormat.rhymePath(tail: tail)))?.data.count) ?? 0 }

        let c = try DictionaryPack(url: url, language: PackLanguage(language), seed: SEED)
        let candidates = c.rhymeCandidates(tail: tail).count
        print(String(format: "%-12@ %10.1f  %10.1f  %7.1f   %10d  %4d   (%@ bucket)",
                     probe as NSString, find, read, max(find - read, 0), candidates, hits,
                     mib(readBytes)))
    }
    exit(0)
}

// MARK: - panel
//
// realpack panel <pack.dma> <en|fr> <word> [word…]
//
// Times exactly what the lookup panel does per caret move — `define`, then
// `RhymeSearch.find` at the panel's limit — and splits the rhyme cost into the
// bucket read and the rank, because they are different problems with different
// fixes. Cold and warm are both reported: over a writing session the second
// question about a bucket is the common case, not the first.

// realpack verify <pack.dma> <en|fr> <word> [word…]
//
// Runs each query twice over the *same* pack — once with the rank-order
// short-circuit and once forced exhaustive — and compares the answers word for
// word. The short-circuit is an argument about a sort key, and an argument is
// not a measurement: this is the measurement.
struct Exhaustive: RhymeCandidateSource {
    let inner: PackCandidates
    func candidates(tail: [String], language: Language) -> [RhymeCandidate] {
        inner.candidates(tail: tail, language: language)
    }
    /// The whole point: same words, same order, promise withheld.
    var isRankOrdered: Bool { false }
}

if mode == "verify" {
    guard args.count >= 5 else { fatalError("usage: realpack verify <pack.dma> <en|fr> <word> [word…]") }
    let language: Language = args[3] == "fr" ? .french : .english
    let pack = try DictionaryPack(url: URL(fileURLWithPath: args[2]),
                                  language: PackLanguage(language), seed: SEED)
    let fast = PackCandidates(packs: [language: pack])
    let slow = Exhaustive(inner: fast)

    func ms(_ body: () -> Void) -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000
    }

    var failures = 0
    for probe in args[4...] {
        var a: [RhymeHit] = [], b: [RhymeHit] = []
        var qa = RhymeQuery(); qa.source = fast; qa.limit = 90
        var qb = RhymeQuery(); qb.source = slow; qb.limit = 90
        // Warm the bucket first so neither run pays the parse, and time the
        // second call of each — the panel's common case.
        _ = RhymeSearch.find(probe, language, qb)
        let tb = ms { b = RhymeSearch.find(probe, language, qb) }
        let ta = ms { a = RhymeSearch.find(probe, language, qa) }
        let same = a.map(\.word) == b.map(\.word)
        if !same { failures += 1 }
        print(String(format: "%-12@ %@  short-circuit %6.1f ms   exhaustive %7.1f ms   %4.1f× ",
                     probe as NSString, same ? "IDENTICAL" : "*** DIFFERS ***", ta, tb,
                     tb / max(ta, 0.001)) + "(\(a.count) hits)")
        if !same {
            print("      fast: " + a.prefix(12).map(\.word).joined(separator: " "))
            print("      slow: " + b.prefix(12).map(\.word).joined(separator: " "))
        }
    }
    print(failures == 0 ? "\nALL IDENTICAL" : "\n\(failures) DIFFER")
    exit(failures == 0 ? 0 : 1)
}

if mode == "panel" {
    guard args.count >= 5 else { fatalError("usage: realpack panel <pack.dma> <en|fr> <word> [word…]") }
    let language: Language = args[3] == "fr" ? .french : .english
    let probes = Array(args[4...])
    let pack = try DictionaryPack(url: URL(fileURLWithPath: args[2]),
                                  language: PackLanguage(language), seed: SEED)
    let source = PackCandidates(packs: [language: pack])

    func ms(_ body: () -> Void) -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000
    }

    print("word          define   rhymeCold  (bucket)   rhymeWarm   candidates  hits")
    for probe in probes {
        var entry: PackEntry?
        let d = ms { entry = pack.define(probe) }
        let tail = Rhyme.tail(Phonetics.phonemes(probe, language))
        var candidates = 0
        let bucket = ms { candidates = pack.rhymeCandidates(tail: tail).count }
        var q = RhymeQuery(); q.source = source; q.limit = 90
        var hits = 0
        let cold = ms { hits = RhymeSearch.find(probe, language, q).count }
        let warm = ms { _ = RhymeSearch.find(probe, language, q) }
        print(String(format: "%-12@ %7.1f   %8.1f  %8.1f   %9.1f   %10d  %4d",
                     probe as NSString, d, cold, bucket, warm, candidates, hits)
              + (entry == nil ? "  [no def]" : ""))
    }
    exit(0)
}

// MARK: - rhymes
//
// Prints what a query *returns*, not how fast it returns it — the open product
// question is whether "the best 50 of 185,809" is a useful answer, and that
// cannot be read off a latency table.

if mode == "rhymes" {
    guard args.count >= 5 else { fatalError("usage: realpack rhymes <pack.dma> <en|fr> <word>") }
    let language: Language = args[3] == "fr" ? .french : .english
    let probe = args[4]
    let pack = try DictionaryPack(url: URL(fileURLWithPath: args[2]),
                                  language: PackLanguage(language), seed: SEED)
    let tail = Rhyme.tail(Phonetics.phonemes(probe, language))
    let cands = pack.rhymeCandidates(tail: tail)
    print("PROBE \(probe)  tail \(tail.joined())  \(cands.count) candidates in the bucket")

    var q = RhymeQuery()
    q.source = PackCandidates(packs: [language: pack])
    q.limit = 50
    let hits = RhymeSearch.find(probe, language, q)
    print("\n  top \(hits.count) (sort: best) —")
    for row in stride(from: 0, to: hits.count, by: 5) {
        print("    " + hits[row..<min(row + 5, hits.count)]
                .map { "\($0.word)(\($0.syllables))" }.joined(separator: "  "))
    }

    // A *proxy* for the lemma, good enough to size the problem and no more:
    // real lemmatisation needs the part of speech, which lives in the
    // definitions half of the pack and not in the rhyme index.
    func stem(_ w: String) -> String {
        var s = w.lowercased()
        if language == .french {
            if s.hasSuffix("s") { s.removeLast() }
            if s.hasSuffix("ée") { s.removeLast() }
            if s.hasSuffix("é") { s.removeLast(); s += "er" }
            else if s.hasSuffix("e") { s.removeLast() }
        } else if s.hasSuffix("s") {
            s.removeLast()
        }
        return s
    }
    let multiword = hits.filter { $0.word.contains(" ") || $0.word.contains("-") }
    print("\n  of those \(hits.count) rows: \(Set(hits.map { stem($0.word) }).count) distinct stems, "
          + "\(multiword.count) multi-word or hyphenated")

    // What the same query returns if each stem may only take one row. The point
    // is not that this collapse is the right rule — it is that the rows it frees
    // are the whole question.
    var kept: [RhymeHit] = [], seenStem = Set<String>()
    var q2 = q; q2.limit = 200_000
    for h in RhymeSearch.find(probe, language, q2)
    where seenStem.insert(stem(h.word)).inserted {
        kept.append(h)
        if kept.count == 50 { break }
    }
    print("\n  top 50 with one row per stem —")
    for row in stride(from: 0, to: kept.count, by: 5) {
        print("    " + kept[row..<min(row + 5, kept.count)]
                .map { "\($0.word)(\($0.syllables))" }.joined(separator: "  "))
    }

    // Where do the words a writer would actually reach for come out? Any word
    // named after the probe is looked up in the full ranking. This is the number
    // that says whether the ranking is answering the right question.
    if args.count > 5 {
        let full = RhymeSearch.find(probe, language, q2)
        print("\n  where an obvious rhyme actually ranks —")
        for want in args[5...] {
            if let i = full.firstIndex(where: { $0.word == want }) {
                print(String(format: "    %-12@ rank %5d of %d   (%d shared)",
                             want, i + 1, full.count, full[i].shared))
            } else {
                print("    \(want) — not in the first \(full.count)")
            }
        }
    }

    // The claim to check: most of these are inflected forms of a handful of
    // verbs. A cheap proxy for "same lemma" — the spelling minus its ending.
    var bySuffix: [String: Int] = [:]
    for c in cands where c.word.count >= 3 {
        bySuffix[String(c.word.suffix(2)), default: 0] += 1
    }
    print("\n  the whole bucket by spelling ending —")
    for (s, n) in bySuffix.sorted(by: { $0.value > $1.value }).prefix(10) {
        print(String(format: "    -%@  %6d  (%.1f%%)", s, n,
                     100 * Double(n) / Double(cands.count)))
    }

    // And how much of the bucket the top 50 was chosen from at each `shared`
    // level: if every candidate ties, the ranking is doing nothing.
    let pt = Phonetics.phonemes(probe, language)
    var byShared: [Int: Int] = [:]
    for c in cands {
        let p = c.phonemes ?? Phonetics.phonemes(c.word, language)
        guard !p.isEmpty else { continue }
        byShared[Rhyme.sharedTail(pt, p), default: 0] += 1
    }
    print("\n  candidates by shared phonemes (the primary sort key) —")
    for (s, n) in byShared.sorted(by: { $0.key > $1.key }).prefix(8) {
        print(String(format: "    %2d shared  %6d", s, n))
    }
    exit(0)
}

// MARK: - measure

if mode == "measure" {
    guard args.count >= 4 else { fatalError("usage: realpack measure <pack.dma> <en|fr>") }
    try measure(args[2], args[3] == "fr" ? .french : .english)
    exit(0)
}

// MARK: - build

guard args.count >= 5 else {
    fatalError("usage: realpack build <in.jsonl> <out.dma> <en|fr> [width] [freq_50k.txt]")
}
let inPath = args[2], outPath = args[3]
let language: Language = args[4] == "fr" ? .french : .english
let width = args.count >= 6 ? (Int(args[5]) ?? PackFormat.defaultBucketWidth)
                            : PackFormat.defaultBucketWidth

/// Word -> frequency rank, 1 being the commonest, read from a
/// `hermitdave/FrequencyWords` `<lang>_50k.txt` (`word count` per line, already
/// ordered). This is a **sort key written into the rhyme index, never a
/// filter** — the pack still carries every headword (§7.1). The list was once
/// used to *trim* packs and that design is dead; what survives is the ranking,
/// which is the difference between `aimer` answering `chanter` and answering
/// `zemmer`.
var frequency: [String: Int] = [:]
if args.count >= 7 {
    let text = try String(contentsOfFile: args[6], encoding: .utf8)
    for (i, line) in text.split(separator: "\n").enumerated() {
        let word = PackFormat.normalise(String(line.prefix(while: { $0 != " " })))
        // Keep the *best* rank if a normalised form repeats.
        if !word.isEmpty, frequency[word] == nil { frequency[word] = i + 1 }
    }
    print("frequency list: \(frequency.count) ranked words from \(args[6])")
}

// Stream the JSONL: holding 516 MB of French as Strings is how the first rig ran
// the machine to 2.3 GB RSS.
var definitions: [String: [String]] = [:]
var rhymes: [String: [String]] = [:]
var headwords = 0
var defBytes = 0, rhymeBytes = 0
var rankedRows = 0

/// Streams a file line by line through `getline`, which grows its own buffer, so
/// a 516 MB payload is never held as a `String`.
///
/// This replaces `freopen(inPath, "r", stdin)` + `readLine()`, which worked but
/// reached the file by redirecting the process's own standard input. Opening the
/// path directly is the same streaming without the global side effect — and it
/// makes the `guard` below the only thing standing between a misread input and a
/// pack of nothing, rather than one of two.
func forEachLine(of path: String, _ body: (String) -> Void) {
    guard let file = fopen(path, "r") else { fatalError("cannot open \(path)") }
    defer { fclose(file) }
    var buffer: UnsafeMutablePointer<CChar>?
    var capacity = 0
    defer { free(buffer) }
    while true {
        let read = getline(&buffer, &capacity, file)
        guard read > 0, let buffer else { break }
        var length = Int(read)
        while length > 0, buffer[length - 1] == 0x0A || buffer[length - 1] == 0x0D { length -= 1 }
        body(String(decoding: UnsafeRawBufferPointer(start: buffer, count: length), as: UTF8.self))
    }
}

let started = Date()
forEachLine(of: inPath) { line in
    guard let dRange = line.range(of: "\"w\":\""),
          let end = line[dRange.upperBound...].firstIndex(of: "\"") else { return }
    let word = PackFormat.normalise(String(line[dRange.upperBound..<end]))
    headwords += 1
    definitions[PackFormat.bucket(word, width: width), default: []].append(line)

    let phonemes = Phonetics.phonemes(word, language)
    guard !phonemes.isEmpty else { return }
    let rank = frequency[word]
    if rank != nil { rankedRows += 1 }
    rhymes[PackFormat.rhymePath(tail: Rhyme.tail(phonemes)), default: []].append(
        PackFormat.rhymeLine(word: word, phonemes: phonemes,
                             syllables: Phonetics.syllables(word, language),
                             rank: rank))
}
let parsed = Date().timeIntervalSince(started)
// ⚠️ An empty pack builds perfectly and reports success in 0.0s, which is how a
// silently unread input file looks from here. Nothing downstream would notice
// until an app found the dictionary answering nothing.
guard headwords > 0 else { fatalError("read 0 headwords from \(inPath) — nothing to build") }
print("parsed \(headwords) headwords in \(String(format: "%.1f", parsed))s at width \(width) — \(definitions.count) define buckets, \(rhymes.count) rhyme buckets, \(definitions.count + rhymes.count + 1) blocks")
if !frequency.isEmpty {
    // How much of the index a writer's own vocabulary actually covers. A low
    // percentage is expected and is not a fault: most French headwords are
    // inflected forms no 50k list carries, and an unranked word still appears —
    // just behind the ones somebody has heard of.
    //
    // Counted while building rather than by re-splitting two million `String`s
    // afterwards, which is the mistake this codebase keeps making.
    let total = rhymes.values.reduce(0) { $0 + $1.count }
    print(String(format: "ranked %d of %d rhyme rows (%.1f%%)", rankedRows, total,
                 100 * Double(rankedRows) / Double(max(total, 1))))
}

var archive: [DMAEntry] = []
func add(_ path: String, _ body: Data) {
    archive.append(DMAEntry(originalPath: path, type: .file, mode: 0o644,
                            owner: "lyrickit", group: "lyrickit",
                            crc32: CRC32.checksum(body), data: body))
}
// ⚠️ A pack built from source must be sorted here, or a rebuild silently
// publishes a revision that has lost the pre-sorting and says nothing about it —
// the reader would simply go back to decoding whole buckets. The order is the one
// `resort` produces and the one `DictionaryPack` applies to an unsorted bucket:
// rank ascending, unranked last, ties where the builder emitted them.
for (path, lines) in rhymes {
    rhymes[path] = lines.enumerated()
        .sorted { a, b in
            let ra = PackFormat.parseRhymeLine(ArraySlice(Array(a.element.utf8)))?.rank ?? Int.max
            let rb = PackFormat.parseRhymeLine(ArraySlice(Array(b.element.utf8)))?.rank ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }
        .map(\.element)
}

add(PackFormat.metaPath, try JSONEncoder().encode(
    PackMeta(language: args[4], headwords: headwords, bucketWidth: width,
             rhymeOrder: .rank)))
for (b, lines) in definitions.sorted(by: { $0.key < $1.key }) {
    let body = Data(lines.joined(separator: "\n").utf8)
    defBytes += body.count
    add("/define/\(b).jsonl", body)
}
for (p, words) in rhymes.sorted(by: { $0.key < $1.key }) {
    let body = Data(words.joined(separator: "\n").utf8)
    rhymeBytes += body.count
    add(p, body)
}
print("plaintext: definitions \(mib(defBytes)) + rhyme index \(mib(rhymeBytes)) = \(mib(defBytes + rhymeBytes))")

// The cold-define cost tracks bucket size, not pack size, so the tail of this
// distribution is what a user feels.
let defSizes = definitions.map { ($0.key, $0.value.joined(separator: "\n").utf8.count) }
    .sorted { $0.1 > $1.1 }
print("largest define buckets: " + defSizes.prefix(6).map { "\($0.0)=\(mib($0.1))" }
        .joined(separator: " "))

try? FileManager.default.removeItem(atPath: outPath)
let buildStart = Date()
_ = try DMAVolume.create(url: URL(fileURLWithPath: outPath),
                         keyProvider: EmbeddedSecretKeyProvider(secret: SEED),
                         motd: "LyricKit dictionary pack. Seed published with the licence text.",
                         readme: "Dictionary pack.",
                         metadata: DMAMetadata(app: "LyricKit", version: "1", machine: "local",
                                               timestamp: "2026-08-16T00:00:00Z",
                                               user: "lyrickit", language: args[4]),
                         entries: archive, compression: .lzma)
print(String(format: "built in %.1fs", Date().timeIntervalSince(buildStart)))

// Free the builder's copy before opening the pack, so the read numbers are not
// measured against a process already holding half a gigabyte.
definitions.removeAll(keepingCapacity: false)
rhymes.removeAll(keepingCapacity: false)
archive.removeAll(keepingCapacity: false)

try measure(outPath, language)
