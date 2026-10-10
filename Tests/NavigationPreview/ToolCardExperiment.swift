import AppKit
import SwiftUI
import QuartzCore
import WorkbenchCore

extension NavigationRunner {
    /// Mount the production card; no synthetic seven-read model or layout oracle.
    func toolCardContracts() async throws -> [String: Any] {
        ConversationDisclosureFixture.enabled = true
        // AppKit builds the accessibility subtree lazily and only once the process
        // opts in; CI runners have no assistive client attached, so without this the
        // label walk below sees an empty tree there (local runs already materialize it).
        NSApp.setAccessibilityEnhancedUserInterface(true)
        defer {
            ConversationDisclosureFixture.enabled = false
            ConversationDisclosureFixture.bindings.removeAll()
            ConversationDisclosureFixture.fullBindings.removeAll()
            ConversationReadingMemory.shared.remove("tool-card-contract")
        }
        func settle(_ host: NSView) async {
            for _ in 0..<8 {
                await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
            }
        }
        func texts(_ view: NSView) -> [ReplyTextView] {
            (view as? ReplyTextView).map { [$0] } ?? view.subviews.flatMap(texts)
        }
        func labels(_ root: Any) -> [String] {
            var visited = Set<ObjectIdentifier>()
            func walk(_ value: Any) -> [String] {
                guard let node = value as? NSObject,
                      visited.insert(ObjectIdentifier(node)).inserted else { return [] }
                // SwiftUI's virtual AX nodes expose the standard selectors without
                // necessarily declaring the complete NSAccessibility protocol.
                func attribute(_ name: String) -> Any? {
                    let selector = NSSelectorFromString(name)
                    return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
                }
                let own = [attribute("accessibilityLabel") as? String,
                           attribute("accessibilityValue") as? String].compactMap { $0 }
                return own + (attribute("accessibilityChildren") as? [Any] ?? []).flatMap(walk)
            }
            return walk(root)
        }
        func structured(_ marker: String, code: Int?) -> JSONValue {
            var fields: [String: JSONValue] = [
                "a_marker": .string(marker + " 中文 👩🏽‍💻 é"),
                "stdout": .array((0..<1600).map { .string("line \($0) 中文 mixed output") })
            ]
            if let code { fields["stderr"] = .string("Command failed with exit code: \(code)") }
            return .object(fields)
        }
        let cases: [(String, JSONValue?, VisibleTool.Status, Bool, String, Bool, Bool)] = [
            ("structured-exit", structured("OriginalMarker", code: 1), .failed, true, "Exit code 1", true, true),
            ("structured-no-marker", structured("NoExitMarker", code: nil), .failed, true, "Failed", true, true),
            ("string-exit", .string("Command failed with exit code: 2"), .failed, true, "Exit code 2", true, false),
            ("failed-no-output", nil, .failed, true, "Failed", false, false),
            ("running", structured("RunningMarker", code: nil), .running, true, "Running", false, false),
            ("missing-call", nil, .missingResult, false, "Result not received · Call record missing", false, false)
        ]
        var samples: [[String: Any]] = []
        for dark in [false, true] {
            let width: CGFloat = dark ? 340 : 700
            let scope = "tool-card-contract:\(dark)"
            let bindingKey = scope + ":expanded"
            func root(_ tool: VisibleTool) -> AnyView {
                AnyView(KimiToolCard(tool: tool)
                    .environment(\.conversationMemoryKey, scope)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: width, alignment: .topLeading))
            }
            func tool(_ output: JSONValue?, _ status: VisibleTool.Status = .failed, _ hasCall: Bool = true) -> VisibleTool {
                VisibleTool(id: "same-tool", name: "Bash", input: .object(["command": .string("echo fixture")]),
                            output: output, status: status, hasCall: hasCall)
            }
            let host = NSHostingView(rootView: root(tool(nil)))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 650),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            await settle(host)
            for (name, output, status, hasCall, expected, displays, encodes) in cases {
                NavigationRenderMetrics.counters.removeAll()
                NavigationRenderMetrics.stages.removeAll()
                host.rootView = root(tool(output, status, hasCall))
                await settle(host)
                let counts = NavigationRenderMetrics.counters
                let bodies = counts["tool_card_body", default: 0]
                guard bodies > 0, counts["tool_card_exit_report_read"] == bodies,
                      counts["tool_card_exit_report_output_display", default: 0] == (displays ? bodies : 0),
                      counts["tool_card_exit_report_json_encode", default: 0] == (encodes ? bodies : 0) else {
                    throw NavigationError("Tool card read/encoding counters differ for \(name): \(counts)")
                }
                let accessibility = labels(host)
                guard accessibility.contains(where: { $0.contains(expected) }),
                      !texts(host).contains(where: { $0.string.contains("OriginalMarker") }) else {
                    throw NavigationError("Tool card collapsed label/content incorrect for \(name): \(accessibility)")
                }
                samples.append(["case": name, "dark": dark, "width": width,
                                "counters": counts, "stages": NavigationRenderMetrics.report,
                                "accessibility": accessibility, "collapsed": true])
            }
            host.rootView = root(tool(structured("OriginalMarker", code: 1)))
            await settle(host)
            guard let expand = ConversationDisclosureFixture.bindings[bindingKey] else {
                throw NavigationError("Tool card disclosure binding missing")
            }
            expand.wrappedValue = true
            await settle(host)
            guard let text = texts(host).first(where: { $0.string.contains("OriginalMarker") }) else {
                throw NavigationError("Expanded structured tool output missing")
            }
            window.makeFirstResponder(text)
            text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            guard let type = text.writablePasteboardTypes.first(where: { $0 == .string || $0.rawValue == "NSStringPboardType" }),
                  text.writeSelection(to: board, types: [type]), board.string(forType: type) == text.string else {
                throw NavigationError("Structured tool output Unicode copy failed")
            }
            host.rootView = root(tool(structured("ReplacementMarker", code: 2)))
            await settle(host)
            guard texts(host).contains(where: { $0.string.contains("ReplacementMarker") }),
                  !texts(host).contains(where: { $0.string.contains("OriginalMarker") }),
                  labels(host).contains(where: { $0.contains("Exit code 2") }) else {
                throw NavigationError("Same-ID tool replacement retained stale content or status")
            }
            // Recreate the hosting controller while retaining the reading-memory key.
            let remounted = NSHostingView(rootView: root(tool(structured("ReplacementMarker", code: 2))))
            window.contentView = remounted
            await settle(remounted)
            guard texts(remounted).contains(where: { $0.string.contains("ReplacementMarker") }),
                  let collapse = ConversationDisclosureFixture.bindings[bindingKey] else {
                throw NavigationError("Tool expansion was lost on remount")
            }
            collapse.wrappedValue = false
            await settle(remounted)
            guard !texts(remounted).contains(where: { $0.string.contains("ReplacementMarker") }) else {
                throw NavigationError("Collapsed tool retained expanded output")
            }
        }
        return ["tool_card_cases": samples, "same_id_replacement": true, "unicode_copy": true,
                "disclosure_remount": true, "boundary": "production tool-card native behavior; not FPS or scrolling latency"]
    }
}
