import Foundation
import WorkbenchCore

func checkModelSelection() throws {
    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // Shape observed from `omp models --json` on both 17.1.4 and 18.1.16.
    let ompCatalog = try json("""
    [{"provider":"openai-codex","id":"gpt-5.4-mini","selector":"openai-codex/gpt-5.4-mini",
      "name":"GPT-5.4 mini","contextWindow":272000,"reasoning":true,
      "thinking":["low","medium","high","xhigh"],"input":["text","image"]},
     {"provider":"bailian","id":"kimi-k3","selector":"bailian/kimi-k3","name":"Kimi K3",
      "contextWindow":1048576,"thinking":["low","high","max"],"input":["text"]},
     {"provider":"lan","id":"plain","selector":"lan/plain","name":"Plain","contextWindow":8192},
     {"id":"","provider":"broken"}]
    """)
    let ompModels = ModelSelectionCatalog.parseOMP(ompCatalog)
    precondition(ompModels.count == 3)
    // provider and id stay separate: set_model rejects a combined "provider/id".
    let mini = ompModels[0]
    precondition(mini.id == "gpt-5.4-mini" && mini.provider == "openai-codex")
    precondition(!mini.id.contains("/"))
    precondition(mini.contextWindow == 272000)
    precondition(mini.thinking == [.low, .medium, .high, .xhigh])
    // OMP declares no default effort, so none is invented.
    precondition(mini.defaultThinking == nil)
    // A model without a thinking array has no effort control at all.
    let plain = ompModels[2]
    precondition(!plain.supportsThinking && plain.resolve(.high) == nil)
    // Entries missing an id are dropped rather than shown as a blank row.
    precondition(!ompModels.contains { $0.id.isEmpty })

    let combinedCatalog = try json("""
    [{"id":"gpt-6-astra","provider":"codex","name":"GPT-6-Astra",
      "thinking":["low","medium","high","xhigh","max","ultra"],"defaultThinking":"medium"}]
    """)
    let codex = ModelSelectionCatalog.parseOMP(combinedCatalog)[0]
    precondition(codex.provider == "codex" && codex.defaultThinking == .medium)
    precondition(codex.thinking.last == .ultra && ThinkingLevel.parse("ULTRA") == .ultra)

    // Shape observed from Kimi /api/v1/models on the remote host.
    let kimiItems = try json("""
    [{"provider":"bailian","model":"bailian/kimi-k3","display_name":"kimi-k3",
      "max_context_size":1048576,"capabilities":["thinking","tool_use"],
      "support_efforts":["low","high","max"],"default_effort":"max"},
     {"provider":"bailian","model":"bailian/qwen3.8-flash","display_name":"qwen3.8-flash",
      "max_context_size":262144,"capabilities":["tool_use"]},
     {"provider":"demo-anthropic","model":"demo/claude-opus-5","display_name":"",
      "max_context_size":1000000,"support_efforts":["low","medium","high","xhigh","max"],
      "default_effort":"high"}]
    """).array
    let kimiModels = ModelSelectionCatalog.parseKimi(kimiItems)
    precondition(kimiModels.count == 3)
    let k3 = kimiModels[0]
    precondition(k3.id == "bailian/kimi-k3" && k3.contextWindow == 1048576)
    precondition(k3.thinking == [.low, .high, .max] && k3.defaultThinking == .max)
    // No support_efforts means no effort control, not a silent default.
    let flash = kimiModels[1]
    precondition(!flash.supportsThinking && flash.defaultThinking == nil)
    // An empty display_name falls back to the id's last path component.
    precondition(kimiModels[2].name == "claude-opus-5")

    // Both runtimes accept an unrecognised level without erroring, so the client
    // validates before sending: OMP answered success for "not-a-level" and then
    // reported thinkingLevel null, and Kimi returned code 0 for the same input.
    precondition(ThinkingLevel.parse("not-a-level") == nil)
    precondition(ThinkingLevel.parse("HIGH") == .high)
    precondition(ThinkingLevel.parse("") == nil && ThinkingLevel.parse(nil) == nil)
    precondition(k3.accepts(.max) && !k3.accepts(.medium))
    // Switching to a model that lacks the current level falls back to that model's
    // own default instead of sending an effort it will silently drop.
    precondition(k3.resolve(.medium) == .max)
    precondition(k3.resolve(.low) == .low)
    precondition(k3.resolve(nil) == .max)
    // With no default declared, an unsupported choice resolves to nothing.
    precondition(mini.resolve(.max) == nil && mini.resolve(.xhigh) == .xhigh)
    // A default outside the supported list is not trusted.
    let inconsistent = AgentModel(id: "x", provider: "p", name: "X", thinking: [.low], defaultThinking: .max)
    precondition(inconsistent.defaultThinking == nil && inconsistent.resolve(.max) == nil)

    let undeclared = ModelSelectionCatalog.parseKimi(try json("""
    [{"provider":"custom","model":"custom/reasoner","capabilities":["thinking","tool_use"]},
     {"provider":"custom","model":"custom/adjustable","support_efforts":["none","low","high"],"default_effort":"none"}]
    """).array)
    precondition(undeclared[0].hasThinkingCapability == true && !undeclared[0].supportsThinking)
    precondition(undeclared[1].thinking == [.none, .low, .high])
    precondition(undeclared[1].defaultThinking == ThinkingLevel.none)
    precondition(undeclared[1].resolve(ThinkingLevel.none)?.rawValue == "none")

    // Context budget: a runtime that has not reported a window is unknown, never 0%.
    precondition(ContextBudget(used: 0, limit: 0) == nil)
    precondition(ContextBudget(used: 100, limit: nil) == nil)
    precondition(ContextBudget(used: nil, limit: 200000) == nil)
    precondition(ContextBudget(used: -5, limit: 200000) == nil)
    // Values taken from the live local OMP get_state.contextUsage.
    guard let local = ContextBudget(used: 17812, limit: 372000) else { fatalError("budget") }
    precondition(local.remaining == 354188)
    precondition(local.remainingPercent == 95)
    precondition(local.pressure == .comfortable)
    precondition(local.summary == "Context remaining: 95% · 354K / 372K")
    precondition(local.detail.contains("excludes unsent drafts"))
    // Values taken from the live Kimi session snapshot usage.
    guard let kimi = ContextBudget(used: 110527, limit: 983616) else { fatalError("budget") }
    precondition(kimi.remainingPercent == 88 && kimi.pressure == .comfortable)
    precondition(ContextBudget(used: 800_000, limit: 1_000_000)?.pressure == .tight)
    precondition(ContextBudget(used: 960_000, limit: 1_000_000)?.pressure == .critical)
    precondition(ContextBudget(used: 29, limit: 100)?.remainingPercent == 71)
    // Reported usage above the window cannot produce a negative remaining.
    guard let over = ContextBudget(used: 500_000, limit: 272_000) else { fatalError("budget") }
    precondition(over.remaining == 0 && over.remainingPercent == 0 && over.pressure == .critical)
    precondition(ContextBudget.short(1_048_576) == "1.0M" && ContextBudget.short(272_000) == "272K")
    precondition(ContextBudget.short(842) == "842")

    // A live Kimi session snapshot. convertFromSnakeCase renames the decoded
    // properties but not the keys inside an untyped JSONValue, so usage must be read
    // as snake_case or the meter silently reports unknown forever.
    let live = try KimiWire.decoder().decode(KimiSession.self, from: Data("""
    {"id":"session_qa","title":"productB","updated_at":"v1","busy":false,
     "metadata":{"cwd":"/tmp"},"agent_config":{"model":"bailian/kimi-k3"},
     "usage":{"input_tokens":130067,"output_tokens":32752,"context_tokens":110527,"context_limit":983616}}
    """.utf8))
    precondition(live.budget?.used == 110527 && live.budget?.limit == 983616)
    precondition(live.budget?.remainingPercent == 88)
    // A session that has not run yet reports zeros, which must read as unknown.
    let fresh = try KimiWire.decoder().decode(KimiSession.self, from: Data("""
    {"id":"s","title":"","updated_at":"v1","busy":false,"metadata":{},"agent_config":{},
     "usage":{"context_tokens":0,"context_limit":0}}
    """.utf8))
    precondition(fresh.budget == nil)
    // Older servers omit usage entirely.
    let legacy = try KimiWire.decoder().decode(KimiSession.self, from: Data("""
    {"id":"s","title":"","updated_at":"v1","busy":false,"metadata":{},"agent_config":{}}
    """.utf8))
    precondition(legacy.usage == nil && legacy.budget == nil)

    // The bridge forwards OMP usage under its own names, already unwrapped.
    let native = try KimiWire.decoder().decode(NativeAgentSession.self, from: Data("""
    {"id":"omp-qa","provider":"omp","title":"QA","cwd":"/tmp","busy":false,"archived":false,
     "updated":0,"completed":1,"pending":0,"model":"glm-5.2","error":null,"cancelled":false,
     "thinking":"minimal","context":{"tokens":33189,"limit":1048576}}
    """.utf8))
    precondition(native.budget?.used == 33189 && native.budget?.remainingPercent == 96)
    precondition(ThinkingLevel.parse(native.thinking) == .minimal)
    // A runtime that reported no window leaves the meter unknown rather than full.
    let unreported = try KimiWire.decoder().decode(NativeAgentSession.self, from: Data("""
    {"id":"omp-new","provider":"omp","title":"QA","cwd":"/tmp","busy":false,"archived":false,
     "updated":0,"completed":0,"pending":0,"model":"","error":null,"cancelled":false,
     "thinking":null,"context":null}
    """.utf8))
    precondition(unreported.budget == nil && ThinkingLevel.parse(unreported.thinking) == nil)

    // The bridge serves one combined list, so each entry names the runtime that can
    // route it; `provider` is the model's vendor and cannot answer that.
    let tagged = try json("""
    [{"agent":"omp","provider":"openai-codex","id":"gpt-5.4-mini","name":"GPT-5.4 mini","thinking":["low","high"]},
     {"agent":"dsh","provider":"deepseek-official","id":"deepseek-v4-flash","name":"DeepSeek-V4-Flash","thinking":["high"]},
     {"agent":"dsh","provider":"deepseek-official","id":"deepseek-v4-pro","name":"DeepSeek-V4-Pro"}]
    """)
    let taggedModels = ModelSelectionCatalog.parseOMP(tagged)
    precondition(taggedModels.map(\.agent) == [.omp, .dsh, .dsh])
    precondition(ModelSelectionCatalog.forAgent(.omp, in: taggedModels).map(\.id) == ["gpt-5.4-mini"])
    precondition(ModelSelectionCatalog.forAgent(.dsh, in: taggedModels).map(\.id) == ["deepseek-v4-flash", "deepseek-v4-pro"])
    // Qoder's SDK reports no catalog, so it is offered nothing rather than a list
    // belonging to another runtime.
    precondition(ModelSelectionCatalog.forAgent(.qoder, in: taggedModels).isEmpty)
    // An agent this client cannot launch parses as no agent at all, so among tagged
    // entries it is dropped instead of being offered to every runtime.
    let foreign = ModelSelectionCatalog.parseOMP(try json(#"""
    [{"agent":"cursor","provider":"p","id":"x"},{"agent":"omp","provider":"p","id":"y"}]
    """#))
    precondition(foreign.first?.agent == nil)
    precondition(ModelSelectionCatalog.forAgent(.omp, in: foreign).map(\.id) == ["y"])
    // A bridge that predates tagging reports no agent at all. Hiding every model
    // then would leave a working session with an empty menu, so the old ambiguous
    // list is passed through untouched.
    precondition(ompModels.allSatisfy { $0.agent == nil })
    precondition(ModelSelectionCatalog.forAgent(.omp, in: ompModels) == ompModels)
    precondition(ModelSelectionCatalog.forAgent(.dsh, in: ompModels) == ompModels)
    // Starting a session sends only the id, so two vendors sharing one id are a
    // single choice — and a single identity for the picker's list.
    let options = ModelCatalog.options(taggedModels)
    precondition(options.map(\.id) == ["gpt-5.4-mini", "deepseek-v4-flash", "deepseek-v4-pro"])
    precondition(options.allSatisfy { $0.capabilities.isEmpty })
    let collide = ModelCatalog.options([AgentModel(id: "x", provider: "a", name: "X"), AgentModel(id: "x", provider: "b", name: "X")])
    precondition(collide.count == 1 && Set(options.map(\.id)).count == options.count)
    print("PASS: OMP and Kimi model catalogs, provider/id separation, per-runtime catalog split with untagged-bridge fallback, effort validation and fallback, context budget with unknown and over-limit states")
}
