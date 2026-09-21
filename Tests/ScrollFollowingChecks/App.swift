import AppKit
import Foundation

/// Exercise the production observer without SSH, a conversation store or input
/// injection. Geometry changes model the same streaming/scroll ordering as the app.
@main struct ScrollFollowingChecks {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 800, height: 2000))
        scroll.documentView = document
        var following = true
        let observer = ConversationScrollObserver.ObserverView { following = $0 }
        document.addSubview(observer)
        func bottom() -> CGFloat { document.bounds.maxY - scroll.contentView.bounds.height }
        func move(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func growth() {
            document.setFrameSize(NSSize(width: 800, height: document.frame.height + 100))
            // Production onContentSizeChange consults the follow state before scrolling.
            if following { move(bottom()) }
        }
        move(bottom())
        growth()
        precondition(abs(scroll.contentView.bounds.minY - bottom()) < 1)

        // This is the failing sequence: an upward wheel event followed by a new
        // token before enough distance has accumulated to cross the old threshold.
        observer.userScrolled(deltaY: 1)
        precondition(!following, "upward intent must pause synchronously, even at the bottom")
        move(bottom() - 5)
        let readingPosition = scroll.contentView.bounds.minY
        for _ in 0..<20 { growth(); await Task.yield() }
        precondition(!following && scroll.contentView.bounds.minY == readingPosition,
                     "streamed height changes must not pull the reader back to the tail")

        // Moving down while still in history is not a request to follow the tail.
        observer.userScrolled(deltaY: -1)
        await settle()
        precondition(!following)
        move(bottom())
        await settle()
        precondition(!following, "a geometry change alone must not resume following")
        observer.userScrolled(deltaY: -1)
        await settle()
        precondition(following, "an explicit downward wheel event at the tail resumes following")

        // A direction reversal cancels a queued downward-event completion.
        observer.userScrolled(deltaY: -1)
        observer.userScrolled(deltaY: 1)
        await settle()
        precondition(!following)

        // Native scrollbar/trackpad lifecycle: pause on begin, resume only at the tail.
        following = true
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        precondition(!following)
        move(bottom() - 10)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        precondition(!following, "ending within the old 40-point threshold still means reading history")
        move(bottom())
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: NSScrollView())
        precondition(!following, "another scroll view must not change this conversation")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        precondition(following)
        print("PASS: immediate wheel pause, streaming position retention, explicit tail resume, direction reversal and native scroll lifecycle")
    }
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(20)) }
}
private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
