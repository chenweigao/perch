#!/usr/bin/env python3
"""Build r34-attr.job from the r33 job skeleton (single source of truth).

Round-34 shapes: PAGING (bench-exact older_page triples on a warm handle) and
STREAMING CHAIN (bench-exact per-update chain incl. find-bar query_update).
Fidelity fixes over the naive first draft (dry-run measured 7x-inflated
prepends before these):
  - the fixture includes the bench's -5..<0 history pre-loop + earlierRaw
    capture, so prepended pages carry DISTINCT message ids (duplicated ids
    changed the projection path and inflated prepend cost ~7x);
  - 3 prepends per cycle (bench-exact page count);
  - the paging window is the post-delta displayMessages (bench-exact);
  - streaming keeps ONE findBar across cycles (bench query_update shape =
    warm same-instance re-search; a per-cycle cold build would dominate).
"""
job = open('.local/round33/r33-attr.job').read()

# ---- header
job = job.replace('''# Round-33 attribution: post-round-32 composition of the two find-bar
# shapes on Mac — (1) COLD: fresh ConversationSearch + fresh ALL THREE
# caches per iteration (render + match + per-entry store + prefix-node
# store walk); (2) REOPEN: shared caches warmed, fresh ConversationSearch
# per iteration — the round-32 shape: one window verification + immutable
# node reference adoption + suffix per-entry path (expected ~0.1ms; the
# profile dissects what remains). Time Profiler, attribution only (never
# A/B). Temporary loop-harness bench modes, reverted after. set -u without
# set -e: every failure path reverts the tree before exiting (r31b lesson).''',
'''# Round-34 attribution: the two never-profiled shapes — (1) PAGING: the
# older_page triple (presentation update + presented rows + activity) per
# 100-message prepend, bench-exact (warm handle after cold projection + 35
# delta updates; 20 distinct-id pages per cycle (extended from the bench's 3 to dominate the re-warm; mechanism identical, disclosed)); (2) STREAMING CHAIN: the
# full per-update chain (apply + displayMessages + presentation + presented
# + memory keys + activity + find-bar query_update on ONE warm findBar),
# restarting from the pre-decoded snapshot every 205 updates. Time Profiler,
# attribution only (never A/B). Disclosed approximations: the paging re-warm
# (cold projection + 35 updates) is region-indistinguishable from measured
# prepends and dominates cycle wall time — region SHARES of the prepend
# samples (isolated by the analyst via per-cycle time structure), not raw
# whole-trace shares, are the deliverable; streaming restarts are ~3% of
# cycle wall time. set -u without set -e: every failure path reverts the
# tree before exiting (r31b lesson).''')

# ---- mode/name renames
job = job.replace('r33-cold-profile', 'r34-paging-profile').replace('r33-reopen-profile', 'r34-stream-profile')
job = job.replace('R33_PROFILE_SECONDS', 'R34_PROFILE_SECONDS')
job = job.replace('r33_profile', 'r34_profile')
job = job.replace('round33-profile', 'round34-profile').replace('round33', 'round34')
job = job.replace('/tmp/r33-record', '/tmp/r34-record')
job = job.replace('git checkout --detach 4c184e5', 'git checkout --detach 146d4fd')
job = job.replace('try benchR33Profile(shared: false)', 'try benchR34PagingProfile()')
job = job.replace('try benchR33Profile(shared: true)', 'try benchR34StreamProfile()')
job = job.replace('cold.trace', 'paging.trace').replace('cold-time-profile.xml', 'paging-time-profile.xml')
job = job.replace('reopen.trace', 'streaming.trace').replace('reopen-time-profile.xml', 'streaming-time-profile.xml')
job = job.replace('=== record cold', '=== record paging').replace('=== record reopen', '=== record streaming')
job = job.replace('record_cold_exit', 'record_paging_exit').replace('record_reopen_exit', 'record_streaming_exit')
job = job.replace('export_cold_failed', 'export_paging_failed').replace('export_reopen_failed', 'export_streaming_failed')
job = job.replace('/tmp/r34-record-cold.log', '/tmp/r34-record-paging.log').replace('/tmp/r34-record-reopen.log', '/tmp/r34-record-streaming.log')
job = job.replace('cold_timing_no_output', 'paging_timing_no_output').replace('reopen_timing_no_output', 'streaming_timing_no_output')

# ---- rebuild the harness functions
start = job.index('func benchR33Profile(shared: Bool) throws {')
end = job.index('\nSWIFTEOF')
fixture_src = job[start:end]
cut = 'let messages = conversation.displayMessages'
fixture = fixture_src[:fixture_src.index(cut) + len(cut)]
fixture = fixture.replace('func benchR33Profile(shared: Bool) throws {', '')
fixture = fixture.replace('    let seconds = Double(ProcessInfo.processInfo.environment["R34_PROFILE_SECONDS"] ?? "") ?? 20\n', '')
# bench-exact history pre-loop for the paging pool
fixture = fixture.replace(
    '    for index in 0...completedTurns { turn(index, running: index == completedTurns) }',
    '''    // Earlier turns of the same shape, read later as 100-message history
    // pages (bench uses 5 turns/3 pages; the profile harness extends to 30
    // turns/20 pages so measured prepends dominate the per-cycle re-warm —
    // each prepend is mechanically identical, window grows 16k->18k, both
    // disclosed).
    for index in -30..<0 { turn(index, running: false) }
    let earlierRaw = raw
    raw = []
    for index in 0...completedTurns { turn(index, running: index == completedTurns) }''')
# conversation must be mutable for warm deltas
fixture = fixture.replace('    let conversation = KimiConversation(', '    var conversation = KimiConversation(')

HEADER = '''/// Round-34 attribution-only harness (never committed). Fixture identical to
/// benchStreamingDelta INCLUDING the -5..<0 history pre-loop (earlierRaw), so
/// prepended pages carry distinct message ids exactly like the bench.
'''

paging = HEADER + '''func benchR34PagingProfile() throws {
    let seconds = Double(ProcessInfo.processInfo.environment["R34_PROFILE_SECONDS"] ?? "") ?? 20
''' + fixture + '''

    let decoder = KimiWire.decoder()
    let earlier = try decoder.decode([KimiMessage].self,
        from: JSONSerialization.data(withJSONObject: earlierRaw))
    func ms(_ t: Double) -> Double { (benchNow() - t) * 1000 }
    let key = "host:kimi:s"
    var samples: [Double] = []
    var warmSamples: [Double] = []
    var cycles = 0
    let deadline = Date().timeIntervalSince1970 + seconds
    while Date().timeIntervalSince1970 < deadline {
        cycles += 1
        let handle = ConversationPresentationHandle()
        let cache = ConversationPresentationCache()
        // re-warm: cold projection + 35 delta updates (bench streaming phase)
        let tWarm = benchNow()
        _ = handle.update(key: key, input: .init(messages: messages, live: [], running: [], isRunning: true,
                                                 online: true, epoch: "bench", language: "zh"), cache: cache)
        for u in 0..<35 {
            let ev = try decoder.decode(KimiEvent.self, from: JSONSerialization.data(withJSONObject: [
                "type": "thinking.delta", "session_id": "s", "epoch": "bench", "volatile": true,
                "offset": conversation.live?.thinkingText.utf16.count ?? 0,
                "payload": ["agentId": "main", "turnId": 1, "delta": "继续推理第 \\(u) 段。"]] as [String: Any]))
            _ = conversation.apply(ev)
            _ = handle.update(key: key,
                              input: .init(messages: conversation.displayMessages, live: [], running: [], isRunning: true,
                                           online: true, epoch: "bench", language: "zh"), cache: cache)
        }
        warmSamples.append(ms(tWarm))
        // measured block: 20 page prepends (the older_page triple each)
        var window = conversation.displayMessages
        for page in 0..<20 {
            let start = earlier.count - 100 * (page + 1)
            window = Array(earlier[start..<(start + 100)]) + window
            let input = ConversationPresentationModel.Input(messages: window, live: [], running: [], isRunning: true,
                                                            online: true, epoch: "bench", language: "zh")
            let t = benchNow()
            let snapshot = handle.update(key: key, input: input, cache: cache)
            let presentation = ms(t)
            let t2 = benchNow()
            let presented = snapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
            let presentedMs = ms(t2)
            let t3 = benchNow()
            _ = ConversationActivity(messages: window, isRunning: true, isThinking: true)
            samples.append(presentation + presentedMs + ms(t3))
            _ = presented
        }
    }
    samples.sort(); warmSamples.sort()
    print("r34_profile shape=paging cycles=\\(cycles) prepends=\\(samples.count)")
    print(String(format: "r34_paging_triple_median_ms=%.3f min_ms=%.3f max_ms=%.3f warm_median_ms=%.2f",
                 samples[samples.count / 2], samples[0], samples[samples.count - 1],
                 warmSamples[warmSamples.count / 2]))
}

'''

streaming = HEADER + '''func benchR34StreamProfile() throws {
    let seconds = Double(ProcessInfo.processInfo.environment["R34_PROFILE_SECONDS"] ?? "") ?? 20
''' + fixture + '''

    let decoder = KimiWire.decoder()
    func ms(_ t: Double) -> Double { (benchNow() - t) * 1000 }
    let key = "host:kimi:s"
    let updatesPerCycle = 205
    var samples: [Double] = []
    var findSamples: [Double] = []
    var cycles = 0
    let deadline = Date().timeIntervalSince1970 + seconds
    // ONE find bar across all cycles: the bench query_update shape is a warm
    // same-instance re-search (a per-cycle fresh instance would make the
    // ~630ms cold build dominate every restart).
    let findBar = ConversationSearch(renderedCache: RenderedSourceCache(),
                                     entryCache: ConversationEntryCache(),
                                     prefixCache: ConversationPrefixCache())
    while Date().timeIntervalSince1970 < deadline {
        cycles += 1
        var conv = KimiConversation(try decoder.decode(KimiSnapshot.self, from: snapshotData))
        let handle = ConversationPresentationHandle()
        let cache = ConversationPresentationCache()
        let model = ConversationPresentationModel(key: key)
        _ = model.update(.init(messages: conv.displayMessages, isRunning: true, epoch: "bench", language: "zh"))
        for update in 0..<updatesPerCycle {
            let event = try decoder.decode(KimiEvent.self, from: JSONSerialization.data(withJSONObject: [
                "type": "thinking.delta", "session_id": "s", "epoch": "bench", "volatile": true,
                "offset": conv.live?.thinkingText.utf16.count ?? 0,
                "payload": ["agentId": "main", "turnId": 1, "delta": "继续推理第 \\(update) 段。"]] as [String: Any]))
            let tAll = benchNow()
            _ = conv.apply(event)
            let timelineMessages = conv.displayMessages
            let input = ConversationPresentationModel.Input(messages: timelineMessages, live: [], running: [], isRunning: true,
                                                            online: true, epoch: "bench", language: "zh")
            let snapshot = handle.update(key: key, input: input, cache: cache)
            _ = model.update(input)
            let presented = snapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
            let memoryKeys = presented.rows.map { key + ":" + $0.entry.id }
            _ = ConversationActivity(messages: timelineMessages, isRunning: true, liveTools: [], online: true,
                                     isThinking: true, isResponding: true)
            let tFind = benchNow()
            let found = findBar.hits(in: timelineMessages, query: "已经处理", running: true)
            findSamples.append(ms(tFind))
            precondition(found.hits.count >= completedTurns)
            _ = memoryKeys
            samples.append(ms(tAll))
        }
    }
    samples.sort(); findSamples.sort()
    print("r34_profile shape=streaming cycles=\\(cycles) updates=\\(samples.count)")
    print(String(format: "r34_chain_median_ms=%.3f min_ms=%.3f max_ms=%.3f find_median_ms=%.3f",
                 samples[samples.count / 2], samples[0], samples[samples.count - 1],
                 findSamples[findSamples.count / 2]))
}'''

job = job[:start] + paging + streaming + job[end:]
open('.local/round34/r34-attr.job', 'w').write(job)
print('r34-attr.job written,', len(job), 'chars')
