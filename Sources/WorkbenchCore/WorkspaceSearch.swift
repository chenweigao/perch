import Foundation

public struct HistorySearchWindow {
    public var messages: [KimiMessage]
    public var complete: Bool
    public init(messages: [KimiMessage], complete: Bool) { self.messages = messages; self.complete = complete }
}

public struct ProjectFileSearchResult: Decodable, Sendable {
    public struct Hit: Decodable, Identifiable, Sendable {
        public let path: String
        public let line: Int
        public let excerpt: String
        public var id: String { "\(path):\(line)" }
    }
    public let hits: [Hit]
    public let inspected: Int
    public let skipped: Int
    public let limited: Bool
    public static func command(directory: String, query: String) -> String {
        let script = #"""
        import os, sys, json
        root, query = sys.argv[1], sys.argv[2].casefold()
        if not os.path.isdir(root):
            raise SystemExit('Project directory is unavailable')
        hits, inspected, skipped, total_bytes, limited = [], 0, 0, 0, False
        for base, dirs, files in os.walk(root, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d not in {'.git', '.build', 'node_modules', '.venv', 'build'} and not os.path.islink(os.path.join(base, d)))
            for name in sorted(files):
                if inspected + skipped >= 1000 or total_bytes >= 25 * 1048576 or len(hits) >= 200:
                    limited = True
                    break
                path = os.path.join(base, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    skipped += 1
                    continue
                try:
                    size = os.path.getsize(path)
                    if size > 1048576:
                        skipped += 1
                        continue
                    if total_bytes + size > 25 * 1048576:
                        limited = True
                        break
                    with open(path, 'rb') as f: data = f.read(1048577)
                    total_bytes += len(data)
                    if len(data) > 1048576 or b'\x00' in data:
                        skipped += 1
                        continue
                    text = data.decode('utf-8')
                except (OSError, UnicodeError):
                    skipped += 1
                    continue
                inspected += 1
                matched = 0
                for number, line in enumerate(text.splitlines(), 1):
                    if query in line.casefold():
                        hits.append({'path': path, 'line': number, 'excerpt': line[:300]})
                        matched += 1
                        if matched >= 3 or len(hits) >= 200: break
                if matched == 0 and query in name.casefold():
                    hits.append({'path': path, 'line': 1, 'excerpt': os.path.relpath(path, root)})
            if limited: break
        print(json.dumps({'hits': hits, 'inspected': inspected, 'skipped': skipped, 'limited': limited}))
        """#
        return (["python3", "-c", script, directory, query]).map(SSHCommand.quote).joined(separator: " ")
    }
}
