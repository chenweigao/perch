p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '''    private struct Key: Hashable {
        let bytes: [UInt8]
        func hash(into hasher: inout Hasher) {
            bytes.withUnsafeBufferPointer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
        static func == (lhs: Key, rhs: Key) -> Bool { lhs.bytes == rhs.bytes }
    }'''
assert s.count(a) == 1
s = s.replace(a, '''    private struct Key: Hashable {
        let bytes: [UInt8]
        private var canonical: String { String(decoding: bytes, as: UTF8.self) }
        func hash(into hasher: inout Hasher) { hasher.combine(canonical) }
        static func == (lhs: Key, rhs: Key) -> Bool { lhs.canonical == rhs.canonical }
    }''')
open(p, 'w').write(s)
