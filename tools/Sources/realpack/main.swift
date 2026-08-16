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

let started = Date()
guard let file = freopen(inPath, "r", stdin) else { fatalError("cannot open \(inPath)") }
_ = file
while let line = readLine(strippingNewline: true) {
    guard let dRange = line.range(of: "\"w\":\""),
          let end = line[dRange.upperBound...].firstIndex(of: "\"") else { continue }
    let word = PackFormat.normalise(String(line[dRange.upperBound..<end]))
    headwords += 1
    definitions[PackFormat.bucket(word, width: width), default: []].append(line)

    let phonemes = Phonetics.phonemes(word, language)
    guard !phonemes.isEmpty else { continue }
    let rank = frequency[word]
    if rank != nil { rankedRows += 1 }
    rhymes[PackFormat.rhymePath(tail: Rhyme.tail(phonemes)), default: []].append(
        PackFormat.rhymeLine(word: word, phonemes: phonemes,
                             syllables: Phonetics.syllables(word, language),
                             rank: rank))
}
let parsed = Date().timeIntervalSince(started)
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
add(PackFormat.metaPath, try JSONEncoder().encode(
    PackMeta(language: args[4], headwords: headwords, bucketWidth: width)))
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
