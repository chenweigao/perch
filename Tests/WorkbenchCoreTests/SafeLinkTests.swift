import Foundation
import WorkbenchCore

func checkSafeLink() {
    let allowed = ["https://example.com/x", "http://example.com", "mailto:a@b.c", "perch-file://open?path=/a"]
    for value in allowed {
        precondition(SafeLink.allowed(URL(string: value)!), "must allow \(value)")
    }
    let blocked = ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,<b>", "vbscript:x",
                   "ftp://example.com", "FILE:///Users/x"]
    for value in blocked {
        precondition(!SafeLink.allowed(URL(string: value)!), "must block \(value)")
    }
    precondition(!SafeLink.allowed(URL(string: "./relative/path")!), "schemeless stays text")
    print("PASS: safe link allowlist — http/https/mailto/perch-file, scheme and case rejection")
}
