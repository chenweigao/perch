p = 'Sources/WorkbenchCore/RenderedSourceCache.swift'
s = open(p).read()
a = 'private var table: [[UInt8]: Node] = [:]'
assert s.count(a) == 1
s = s.replace(a, 'private var table: [String: Node] = [:]')
b = '        let key = Array(source.utf8)'
assert s.count(b) == 1
s = s.replace(b, '        let key = source')
c = 'let cost = produced.utf16.count * 2 + key.count'
assert s.count(c) == 1
s = s.replace(c, 'let cost = produced.utf16.count * 2 + key.utf8.count')
open(p, 'w').write(s)
