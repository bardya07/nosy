import SwiftUI
import AppKit

struct LocalModelCard: View {
    let model: LocalModel
    @ObservedObject var store: LocalModelStore
    @State private var confirmRemoval = false
    @State private var removalError: String?
    private var state: LocalModelStore.State { store.state(model) }
    private var partialBytes: Int64 { Core.fileSize(store.partial(model)) }
    private var canRemove: Bool { state == .downloaded || partialBytes > 0 || state == .loaded }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.name).font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(model.sizeLabel).font(Theme.text(11)).foregroundStyle(Theme.muted)
            }
            Text(model.ramNote).font(Theme.text(11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(removalError ?? state.title).font(Theme.text(11, .medium))
                .foregroundStyle(isError ? Theme.validationText : Theme.accentText)
                .accessibilityIdentifier("localModelState")
            if case .downloading(let bytes) = state {
                let fraction = min(1, Double(bytes) / Double(model.bytes))
                ProgressView(value: fraction).tint(Theme.accentText)
                Text("\(bytes / 1_000_000) MB of \(model.bytes / 1_000_000) MB · \(Int(fraction * 100))%")
                    .font(Theme.text(10)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            if case .error(let message) = state {
                Text(message).font(Theme.text(11)).foregroundStyle(Theme.validationText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if state.busy {
                    Button("Cancel") { store.cancel(model) }.buttonStyle(PillButtonStyle(kind: .quiet, height: 27, fullWidth: false))
                        .tip("Keep downloaded bytes to resume later")
                } else if state != .downloaded && state != .loaded {
                    Button(partialBytes > 0 ? "Resume download" : "Download") { if !Snapshot.isRunning { store.download(model) } }
                        .buttonStyle(PillButtonStyle(kind: .quiet, height: 27, fullWidth: false))
                        .tip("Download \(model.sizeLabel) from Hugging Face and verify SHA256")
                }
                if canRemove && !state.busy {
                    Button("Remove") { confirmRemoval = true }
                        .buttonStyle(PillButtonStyle(kind: .quiet, height: 27, fullWidth: false))
                        .disabled(state == .loaded)
                        .tip(state == .loaded ? "Wait until this summary finishes" : "Delete this model from your Mac")
                }
                Spacer(minLength: 0)
            }
            Text("Disk used by summary models: \(ByteCountFormatter.string(fromByteCount: store.diskBytes, countStyle: .decimal))")
                .font(Theme.text(10)).foregroundStyle(Theme.muted)
            Text("Runs on this Mac. Downloads are optional. SHA256 is checked before use.")
                .font(Theme.text(10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        .alert("Remove \(model.name)?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                guard !Snapshot.isRunning else { return }
                do { try store.remove(model); removalError = nil }
                catch { removalError = SummaryError.short(error.localizedDescription) }
            }
        } message: { Text("This deletes the model and its saved excerpt notes. You can download it again later.") }
    }
    private var isError: Bool { if case .error = state { return true }; return removalError != nil }
}
