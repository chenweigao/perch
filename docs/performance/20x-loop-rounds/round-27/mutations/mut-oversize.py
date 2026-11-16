p = 'Sources/WorkbenchCore/RenderedSourceCache.swift'
s = open(p).read()
a = '        if cost <= byteBudget {'
assert s.count(a) == 1
s = s.replace(a, '        if true {')
open(p, 'w').write(s)
