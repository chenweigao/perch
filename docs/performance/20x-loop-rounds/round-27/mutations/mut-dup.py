p = 'Sources/WorkbenchCore/ConversationSearch.swift'
s = open(p).read()
a = '    private var entries: [String: Entry] = [:]'
assert s.count(a) == 1
s = s.replace(a, a + '\n    private var seenSourceBytes: Set<[UInt8]> = []')
b = '        guard !query.isEmpty else { return .empty }'
assert s.count(b) == 1
s = s.replace(b, b + '\n        seenSourceBytes.removeAll()')
c = '''                let rendered = sources.map { source in
                    renderedCache.rendered(source) { Self.renderedText(ReplyDocument.parse(source)) }
                }'''
assert s.count(c) == 1
s = s.replace(c, '''                let rendered = sources.map { source -> String in
                    guard seenSourceBytes.insert(Array(source.utf8)).inserted else { return "" }
                    return renderedCache.rendered(source) { Self.renderedText(ReplyDocument.parse(source)) }
                }''')
open(p, 'w').write(s)
