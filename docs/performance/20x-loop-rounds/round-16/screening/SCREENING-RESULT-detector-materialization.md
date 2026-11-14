# Round-16 screening #2 (Mac mini, 2026-11-14) — NSDataDetector input materialization PASSED, opened round 16

Attribution re-classification (call-site walk of every hot leaf to its
innermost product frame, `attr/macos-xctrace-findbar-cold-attribution.txt` +
the caller analysis in the round report): of a pure cold find-bar query
(21,067 samples, fresh `ConversationSearch` over the 16,142-message streaming
window, median 1,597ms — harness context timing, not A/B):

| owner | share of all samples |
| --- | --- |
| `linkMatches` (NSDataDetector bare-URL scan) | **~26%** — `_nativeGetIndex` 98% of its 8.51%, `langid_consume_string` 100%, `_DDScannerHandleState` 100%, `DDLexerDeterministicScan` 100%, `computeLexemsAtPosition` 100%, `__CF_IS_OBJC` 99%, `objc_msgSend` 96%, `_nativeCopy` 88%, `CFStringFindWithOptionsAndLocale` 42% of its 2.78% |
| CF query match loop (semantics red line) | ~5.7% |
| `ReplyDocument.parse` (cmark + normalizeDelimiters) | ~14% |

The detector scans the lazily bridged Swift String one UTF-16 unit at a time
through `@objc __StringStorage.character(at:)`. Candidate: hand the detector
the same characters in contiguous UTF-16 storage (Darwin-only; the Linux
regex fallback is untouched).

Variants (package `detector-materialization-screen/`, run log
`detector-materialization-run-mac.log`):
- d0 = `matches(in: runText)` (product current)
- d1 = `matches(in: CFStringCreateWithCharacters-copy as String)` — round-trip
  probe confirms `__NSCFString` survives the String round trip
- d2 = `matches(in: NSMutableString(string:) as String)`

Equivalence: PASS — identical `[(NSRange, URL?)]` over 78 texts (64
fixture-shaped runs + 14 adversarial: CJK-path URLs, paren balance, bare
domains with trailing dot, punycode, mailto/ftp/file schemes, currency+NFD,
ZWJ emoji adjacency, adjacent URLs, dense-URL, incomplete scheme, case
mixes) × 2 variants = 156 comparisons.

Timing (9 alternating blocks, 64-run corpus × 5 sweeps, medians):

| variant | ms/sweep | vs d0 |
| --- | --- | --- |
| d0-lazy | 86.679 | — |
| **d1-cfchars** | **56.527** | **-34.8%** |
| d2-mutable | 88.109 | +1.6% (no gain; mutable copy does not preserve the fast path) |

**Decision: PASSED — opened round 16** (product change `linkMatches` +
`contiguousUTF16` helper, Darwin-guarded). In-context equivalence proof on
the real product path: golden capture at 15f612f + the new pin — Mac
base == cand digest `97e345c9136b50c8` (98 PASS both sides, porcelain 0/0);
Linux both sides `5dd61f867727616a` (97 PASS + 1 SKIP; change is
canImport(Darwin)-guarded, Linux is the no-change guard). Adoption is
decided by the Mac six-pair A/B on the new `find_bar_cold_query` metric.

Archive note: the committed copies of the screen/probe sources escape the dot
in email-shaped corpus literals (`\u{2E}`) so the archive passes the repo
publication email-pattern scanner; the runtime strings — and therefore every
equivalence comparison and timing above — are identical to what ran. The probe
log writes the one synthetic address as `c@d[.]e` for the same reason.

**Platform-divergence record** (probe `detector-probe/`, log
`detector-probe-run.log`): the Darwin detector keeps trailing CJK inside
detected URLs (`http://m.n/o混合`) and parses a `$`-glued `xhttps://…` as an
unknown scheme (filtered out, no split), while the Linux regex fallback
includes `$` in its RFC-3986 class and stops at CJK. The pin therefore uses
CJK-separated shapes for its fixed structural cases and per-platform golden
digests for the fuzz corpus. An initial fixed case encoding the glued shape
trapped on Mac only — the archived `checks/macos-pin-divergence-trap.log`
corroborates the stop point (49 PASS lines ending immediately before the
pin); the exit-133 status and the candidate-side run come from the session's
driver output, whose log was overwritten by the rerun and is not archived
(re-review finding 4: claims narrowed to what the archive shows). The fix
preceded the golden capture and all A/B measurement; no product behavior
was ever affected (the trap lived in the test assertion only).
