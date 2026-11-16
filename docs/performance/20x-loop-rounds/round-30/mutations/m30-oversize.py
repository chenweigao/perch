p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '        guard cost <= byteBudget else { return }'
assert s.count(a) == 1
s = s.replace(a, '        // MUTANT: oversize admitted')
open(p, 'w').write(s)
