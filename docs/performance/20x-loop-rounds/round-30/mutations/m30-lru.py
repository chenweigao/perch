p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = 'let ordered = table.sorted { $0.value.lastUse < $1.value.lastUse }'
assert s.count(a) == 1
s = s.replace(a, 'let ordered = table.sorted { $0.value.lastUse > $1.value.lastUse }')
open(p, 'w').write(s)
