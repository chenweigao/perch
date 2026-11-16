p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '''        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.generation += 1
            self.table.removeAll()
            self.estimatedBytes = 0
            self.lock.unlock()
        }'''
assert s.count(a) == 1
s = s.replace(a, '        localeObserver = nil')
open(p, 'w').write(s)
