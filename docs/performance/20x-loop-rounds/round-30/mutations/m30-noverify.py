p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '''        guard KimiMessage.sameSearchableWindow(messages, node.payload.messages[...]) else {
            return nil
        }'''
assert s.count(a) == 1
s = s.replace(a, '        // MUTANT: verification skipped')
open(p, 'w').write(s)
