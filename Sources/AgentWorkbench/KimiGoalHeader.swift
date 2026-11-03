import SwiftUI
import WorkbenchCore

/// This small boundary observes goal changes independently from the transcript.
struct KimiGoalHeader: View {
    let connection: KimiConnection
    let sessionID: String

    var body: some View {
        if let goal = connection.goal {
            GoalHeaderBar(goal: goal,
                          // The status line's and the sidebar's facts, so the header never shows
                          // the running sun while the turn waits for the reader.
                          turn: connection.conversation.map { SessionTurn(kimi: $0.snapshot).state } ?? .idle,
                          isStale: !connection.online || connection.goalIsStale,
                          controlsEnabled: connection.online && connection.snapshotReady && !connection.loading && !connection.sending,
                          onRefresh: { Task { await connection.refreshGoal() } },
                          onControl: { control in
                              Task { await connection.controlGoal(control, for: sessionID) }
                          })
                .id(goal.objective)
        }
    }
}
