from pathlib import Path
import shutil
root=Path(__file__).resolve().parent.parent
out=root/'review-artifacts'
prior=Path('/home/<dev>/.t3/worktrees/perch/t3-35f15e29-4aae08c3e04066aa/review-artifacts/probe-package')
pkg=out/'probe-package'
shutil.copytree(root/'Sources/WorkbenchCore',pkg/'Sources/WorkbenchCore')
shutil.copy(prior/'Package.swift',pkg/'Package.swift')
shutil.copy(prior/'Package.resolved',pkg/'Package.resolved')
shutil.copy(prior/'Sources/WorkbenchCore/Round36ReviewProbe.swift',pkg/'Sources/WorkbenchCore/Round36ReviewProbe.swift')
(pkg/'Sources/ReviewProbe').mkdir(parents=True)
(pkg/'Sources/ReviewProbe/main.swift').write_text('import WorkbenchCore\ntry ConversationPresentationModel.round36ReviewProbe()\n')
source=pkg/'Sources/WorkbenchCore/ConversationPresentation.swift'
s=source.read_text()
s=s.replace('joinedAdoption = adopt\n', 'if adopt { Round36ReviewTrace.hit("capture-fold-\\(priorMemo.foldsProcess)-consumed-\\(match.consumed)") }\n                    joinedAdoption = adopt\n')
s=s.replace('consumedRowCount = consumedValue.rows.count', '''precondition(Array(priorMemo.value.rows.prefix(consumedValue.rows.count)) == consumedValue.rows,
                                         "prior memo prefix/consumed-turn shape mismatch")
                            Round36ReviewTrace.hit("consumed-prefix-verified")
                            consumedRowCount = consumedValue.rows.count''')
s=s.replace('let result = value ?? Presentation(displayed:', '''if !uniqueEntries { Round36ReviewTrace.hit("current-nonunique-fallback") }
            let result = value ?? Presentation(displayed:''')
needle='''            return Presentation(rows: rows, foldParents: parents)
        }

        static func displayed'''
assert needle in s
s=s.replace(needle,'''            let oracle = joined([:], foldsProcess: foldsProcess)!
            precondition(rows == oracle.rows && parents == oracle.foldParents,
                         "actual adopted joined != full joined oracle")
            Round36ReviewTrace.hit("adopt-fold-\\(foldsProcess)-consumedRows-\\(adoption.consumedRowCount)-leading-\\(adoption.leadingNew)")
            return Presentation(rows: rows, foldParents: parents)
        }

        static func displayed''')
source.write_text(s)
trace=pkg/'Sources/WorkbenchCore/Round36ReviewTrace.swift'
trace.write_text('''import Foundation

enum Round36ReviewTrace {
    static var counters: [String: Int] = [:]
    static func hit(_ event: String) { counters[event, default: 0] += 1 }
    static func output() {
        for key in counters.keys.sorted() { print("TRACE: \\(key)=\\(counters[key]!)") }
        precondition(counters.keys.contains { $0.hasPrefix("adopt-fold-true-consumedRows-") })
        precondition(counters.keys.contains { $0.hasPrefix("adopt-fold-false-consumedRows-") })
        precondition(counters["consumed-prefix-verified",default:0] > 0)
    }
}
''')
print('Prepared candidate product source copy + local full-joined/prefix oracle instrumentation; inherited unrun probe copied for continuation, no shared tree modifications')
