import Foundation
import WorkbenchCore

func checkRunControl() throws {
    let host = UUID(), other = UUID()
    let session = SessionReference(hostID: host, terminalID: "productB-omp", kind: .omp)
    let sameIDElsewhere = SessionReference(hostID: other, terminalID: "productB-omp", kind: .omp)
    let neighbour = SessionReference(hostID: host, terminalID: "productB-kimi", kind: .kimi)

    // Capabilities are granted by probing. An unknown runtime offers nothing.
    precondition(AgentCapabilities.unknown.steer == .unsupported)
    precondition(AgentCapabilities.unknown.modes(isStreaming: true).isEmpty)
    // omp 17.1.4: steer exists but its effect on a live turn was never observed here.
    let localOMP = AgentCapabilities(nativeConversation: true, stop: true,
                                     steer: .commandPresentEffectUnverified, queueWhileBusy: true, resume: true)
    precondition(localOMP.modes(isStreaming: true) == [.steer, .nextTurn])
    precondition(localOMP.modes(isStreaming: false) == [.now])
    precondition(localOMP.steer.label.contains("未实机验证"))
    // An adapter that rejects prompts while busy may only advertise queueing.
    let bridged = AgentCapabilities(nativeConversation: true, stop: true, steer: .unsupported, queueWhileBusy: true)
    precondition(bridged.modes(isStreaming: true) == [.nextTurn])
    precondition(bridged.steer.label == "下一轮发送")
    // A terminal entry point is not a structured native conversation.
    let terminalOnly = AgentCapabilities(terminal: true)
    precondition(!terminalOnly.nativeConversation && terminalOnly.modes(isStreaming: true).isEmpty)

    // Stop is a state machine: acceptance is not termination.
    var stop = StopController()
    precondition(stop.phase(for: session) == .idle)
    guard let first = stop.request(session, turn: "turn-1") else { fatalError("first request must be sent") }
    precondition(stop.phase(for: session) == .requested)
    precondition(!stop.phase(for: session).isSettled)
    // Repeated clicks must not produce a second abort.
    precondition(stop.request(session, turn: "turn-1") == nil)
    stop.acknowledge(first.requestID)
    precondition(stop.phase(for: session) == .stopping)
    precondition(stop.phase(for: session).label == "正在停止…")
    // Switching sessions must not stop the newly selected one.
    precondition(stop.phase(for: neighbour) == .idle)
    precondition(stop.phase(for: sameIDElsewhere) == .idle)
    // A terminal event from another turn says nothing about the turn we stopped.
    stop.resolve(session, turn: "turn-2", evidence: .runtimeAborted)
    precondition(stop.phase(for: session) == .stopping)
    stop.resolve(session, turn: "turn-1", evidence: .runtimeAborted)
    precondition(stop.phase(for: session) == .stopped)
    precondition(!stop.phase(for: session).canRetry)

    // No terminal evidence must never look like idle or completed.
    var pending = StopController()
    guard let attempt = pending.request(session, turn: "t") else { fatalError("request") }
    pending.acknowledge(attempt.requestID)
    pending.timedOut(attempt.requestID)
    if case .unknown = pending.phase(for: session) {} else { fatalError("timeout must be unknown") }
    precondition(pending.phase(for: session).canRetry)
    precondition(pending.phase(for: session) != .idle)
    pending.resolve(session, turn: "different", evidence: .runtimeAborted)
    if case .unknown = pending.phase(for: session) {} else { fatalError("wrong turn") }
    pending.resolve(session, turn: "t", evidence: .runtimeAborted)
    precondition(pending.phase(for: session) == .stopped)
    // After settling, a retry click is allowed again.
    precondition(pending.request(session, turn: "t") != nil)

    // A rejected abort is visible and retryable.
    var failing = StopController()
    guard let rejected = failing.request(session) else { fatalError("request") }
    failing.fail(rejected.requestID, "远端进程已退出")
    precondition(failing.phase(for: session).canRetry)
    precondition(failing.phase(for: session).label.contains("远端进程已退出"))
    // Side effects already performed are not claimed to be undone.
    var gone = StopController()
    guard let lost = gone.request(session) else { fatalError("request") }
    gone.acknowledge(lost.requestID)
    gone.resolve(session, evidence: .processGone)
    precondition(gone.phase(for: session).label.contains("副作用可能已发生"))
    // A turn that finished on its own is not reported as stopped.
    var raced = StopController()
    guard let late = raced.request(session) else { fatalError("request") }
    raced.acknowledge(late.requestID)
    raced.resolve(session, evidence: .completedBeforeStop)
    precondition(raced.phase(for: session) == .completedBeforeStop)

    // Queue ownership is host + session, so switching cannot cross sessions.
    var queue = OutboundQueue()
    precondition(queue.enqueue("   ", for: session, mode: .nextTurn) == nil)
    guard let a = queue.enqueue("第一条：先读配置", for: session, mode: .nextTurn, id: "m-a"),
          queue.enqueue("第二条：再改代码", for: session, mode: .nextTurn, id: "m-b") != nil,
          let elsewhere = queue.enqueue("别的主机同名会话", for: sameIDElsewhere, mode: .nextTurn, id: "m-x")
    else { fatalError("enqueue") }
    precondition(queue.items(for: session).map(\.id) == ["m-a", "m-b"])
    precondition(queue.items(for: sameIDElsewhere).map(\.id) == ["m-x"])
    precondition(queue.items(for: neighbour).isEmpty)
    precondition(a.state == .draftQueued && elsewhere.state == .draftQueued)

    // Not-yet-accepted items stay editable and removable, in order.
    precondition(queue.edit("m-b", text: "第二条：改成写测试"))
    precondition(queue.message("m-b")?.text == "第二条：改成写测试")
    guard let c = queue.enqueue("第三条", for: session, mode: .nextTurn, id: "m-c") else { fatalError("enqueue") }
    precondition(c.id == "m-c")
    precondition(queue.remove("m-c"))
    precondition(queue.items(for: session).map(\.id) == ["m-a", "m-b"])

    // While streaming, only a steer message may be delivered.
    precondition(queue.nextDelivery(for: session, isStreaming: true) == nil)
    guard let steerMessage = queue.enqueue("运行中补充：文件末尾加一行", for: session, mode: .steer, id: "m-s") else { fatalError("enqueue") }
    precondition(steerMessage.mode == .steer)
    guard let delivering = queue.nextDelivery(for: session, isStreaming: true) else { fatalError("steer must deliver") }
    precondition(delivering.id == "m-s" && delivering.state == .submitting)
    // Submitting is not accepted; an unconfirmed message is not editable.
    precondition(!queue.edit("m-s", text: "改不动"))
    precondition(!queue.remove("m-s"))
    queue.markAccepted("m-s")
    precondition(queue.message("m-s")?.state == .accepted)
    queue.markRunning("m-s")
    precondition(queue.message("m-s")?.state == .running)
    queue.markDelivered("m-s")
    precondition(queue.message("m-s") == nil)

    // A dropped connection after acceptance is unknown, never blindly replayed.
    guard let risky = queue.nextDelivery(for: session, isStreaming: false) else { fatalError("deliver") }
    precondition(risky.id == "m-a")
    queue.markAccepted("m-a")
    queue.markUnknown("m-a", "断线，未确认是否已执行")
    precondition(queue.message("m-a")?.state.label.contains("结果未知") == true)
    // Retry reuses the id so the runtime can reject a duplicate.
    guard let retried = queue.retry("m-a") else { fatalError("retry") }
    precondition(retried.id == "m-a" && retried.state == .draftQueued)
    precondition(queue.retry("m-b") == nil)
    queue.markFailed("m-b", "远端拒绝")
    precondition(queue.retry("m-b")?.id == "m-b")

    // Stopping pauses the queue: the stopped turn is not followed by a new one.
    queue.pauseForStop(session)
    precondition(queue.isPaused(session))
    precondition(queue.nextDelivery(for: session, isStreaming: false) == nil)
    precondition(queue.items(for: session).allSatisfy { $0.state == .stoppedBeforeDelivery })
    // Drafts are preserved, not cleared.
    precondition(queue.message("m-a")?.text == "第一条：先读配置")
    precondition(queue.message("m-b")?.text == "第二条：改成写测试")
    // Another session's queue is untouched by this stop.
    precondition(queue.edit("m-b", text: "暂停时也能编辑"))
    precondition(!queue.edit("m-b", text: "  "))
    precondition(!queue.isPaused(sameIDElsewhere))
    precondition(queue.nextDelivery(for: sameIDElsewhere, isStreaming: false)?.id == "m-x")
    queue.resume(session)
    precondition(!queue.isPaused(session))
    precondition(queue.nextDelivery(for: session, isStreaming: false)?.id == "m-a")

    // The queue is process-local, so quitting must warn rather than silently drop.
    precondition(queue.unsentWarning(for: session)?.contains("退出后不会保留") == true)
    precondition(queue.unsentWarning(for: neighbour) == nil)
    print("PASS: verified-capability delivery modes, stop state machine with turn binding and unknown results, queue ownership, idempotent retry and stop-paused drafts")
}
