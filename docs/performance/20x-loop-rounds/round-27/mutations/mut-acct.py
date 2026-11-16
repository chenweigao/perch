p = 'Sources/WorkbenchCore/RenderedSourceCache.swift'
s = open(p).read()
a = '            estimatedBytes += cost'
assert s.count(a) == 1
s = s.replace(a, '            estimatedBytes += 0')
open(p, 'w').write(s)
