import SwiftUI
import WorkbenchCore

struct ModelPicker: View {
    let models: [ModelOption]
    @Binding var selection: String
    var current = ""
    private var effective: String { selection.isEmpty ? current : selection }
    private var option: ModelOption? { models.first { $0.id == effective } }
    var body: some View {
        ModelControlWidth {
            Menu {
                Picker("Model", selection: $selection) {
                    Text(current.isEmpty ? "Use default model" : "Keep session model").tag("")
                }.pickerStyle(.inline)
                ForEach(ModelCatalog.groups(models)) { group in
                    Menu(group.id) {
                        Picker(group.id, selection: $selection) {
                            ForEach(group.models) { model in
                                Text(model.name).tag(model.id)
                            }
                        }.pickerStyle(.inline)
                    }
                }
                if models.isEmpty { Text("No models available") }
            } label: {
                Text(option?.name ?? (effective.isEmpty ? "Default model" : String(effective.split(separator: "/").last ?? "")))
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            }.menuStyle(.borderlessButton).menuIndicator(.visible)
                .help("Choose model · \(effective)\nApplies to your next message")
                .accessibilityLabel("Choose model")
        }
    }
}

/// Cap long model labels without reserving empty space after short names.
struct ModelControlWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(ProposedViewSize(width: min(proposal.width ?? 240, 240), height: proposal.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
