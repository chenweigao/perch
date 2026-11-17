#!/usr/bin/env python3
"""Round-36 attribution: deep product-frame walk for ALL string-hashing
leaves (String.hash(into:) INCLUDED as a pass-through, unlike
leaf-consumers-deep.txt's 'string hash' group which stopped at it).

This is the archived derivation of the headline figure: History.joined =
1129 samples = 67.8% of all string-hash leaves = 6.67% of the prepend
phase (1129/16925). Run: python3 leaf-walk-hash-deep.py <xml>
Output: the group table below (archived as leaf-consumers-hash-deep.txt).
"""
import sys
sys.path.insert(0, str(__import__('pathlib').Path(__file__).parent))
sys.argv = [sys.argv[0], sys.argv[1], 'paging']
from analyze_r36 import load, marker
from collections import Counter

rows = load(sys.argv[1])
n = len(rows)
marks = [marker(fr) for _, fr in rows]
nxtJ = [2 * n] * n
nxtP = [2 * n] * n
lj = lp = 2 * n
for i in range(n - 1, -1, -1):
    nxtJ[i], nxtP[i] = lj, lp
    if marks[i] == 'J':
        lj = i
    elif marks[i] == 'P':
        lp = i
sub = []
for i, (_, fr) in enumerate(rows):
    m = marks[i]
    ph = 'warm' if m == 'J' else ('prepend' if m == 'P' else ('prepend' if nxtP[i] < nxtJ[i] else 'warm'))
    if ph == 'prepend':
        sub.append(fr)

# pass-through: every stdlib/runtime frame INCLUDING String.hash itself, so
# the walk lands on the first PRODUCT frame that initiated the hashing.
SKIP = ("swift_", "outlined", "DYLD", "_platform", "Hasher", "_Native", "Dictionary.", "Set.",
        "_HashTable", "__RawDictionary", "protocol witness", "partial apply", "value witness",
        "String.hash", "static String.==", "specialized ", "_String", "libswift", "CF",
        "IndexingIterator", "Array.", "UnsafeMutable", "initializeWithCopy", "destroy for",
        "swift::", "bool ", "memcpy", "malloc", "free", "_xzm", "objc", "dispatch")
LEAVES = ('String.hash(into:)', 'Hasher.combine(bytes:)', 'Hasher._finalize')

consumers = Counter()
total = 0
for fr in sub:
    if any(x in fr[0] for x in LEAVES):
        total += 1
        for p in fr[1:24]:
            if any(x in p for x in SKIP):
                continue
            consumers[p[:95]] += 1
            break
        else:
            consumers['<none in 24>'] += 1
print('prepend samples:', len(sub))
print('string-hash leaves total:', total, '(%.2f%% of prepend)' % (100.0 * total / len(sub)))
for name, c in consumers.most_common(16):
    print('  %6d %6.1f%% of group  %6.2f%% of prepend  %s' % (c, 100.0 * c / total, 100.0 * c / len(sub), name))
