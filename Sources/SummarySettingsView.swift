import SwiftUI
import AppKit

// Settings › Summaries: what to include, who writes it, and when.
struct SummarySettingsSection: View {
    @ObservedObject var summaries: SummaryCenter
    @AppStorage(SummarySettings.providerKey) private var providerRaw = SummaryProvider.off.rawValue
    @AppStorage(SummarySettings.customKey) private var custom = ""
    @AppStorage(SummarySettings.automaticKey) private var automatic = false
    @AppStorage(SummarySection.notes.storageKey) private var notes = SummarySection.notes.includedByDefault
    @AppStorage(SummarySection.terms.storageKey) private var terms = SummarySection.terms.includedByDefault
    @AppStorage(SummarySection.questions.storageKey) private var questions = SummarySection.questions.includedByDefault

    private var provider: SummaryProvider { SummaryProvider(rawValue: providerRaw) ?? .off }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Include").font(Theme.text(12, .medium)).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 6) {
                includeToggle(SummarySection.notes.title, $notes)
                includeToggle(SummarySection.terms.title, $terms)
                includeToggle(SummarySection.questions.title, $questions)
            }
            TextField("", text: $custom, prompt: Text("Custom instructions (optional)").foregroundStyle(Theme.faint), axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain).font(Theme.text(12))
                .fieldChrome()
                .accessibilityLabel("Custom instructions")
                .tip("Extra instructions for every summary")

            providerMenu
            if provider != .off, !summaries.detection.isAvailable(provider), summaries.detection.checked || Snapshot.isRunning {
                hint(provider.unavailableHint, color: Theme.warmText)
            }
            switch provider.kind {
            case .none: EmptyView()
            case .cli: SummaryModelField(provider: provider, placeholder: "Model (CLI default)").id(provider)
            case .local: localModelMenu.id(provider)
            case .api:
                SummaryModelField(provider: provider, placeholder: "Model").id(provider)
                SummaryKeyField(provider: provider, summaries: summaries).id(provider)
            }
            whenMenu
            Text(provider == .off
                 ? "Summaries send the transcript to the provider you choose. Ollama and LM Studio keep it on this Mac."
                 : provider.staysOnMac ? "\(provider.title) keeps the transcript on this Mac. Other providers receive it."
                 : "Summaries send the transcript to \(provider.title.replacingOccurrences(of: " API key", with: "")). Ollama and LM Studio keep it on this Mac.")
                .font(Theme.text(10)).foregroundStyle(Theme.muted)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .tip("Where transcripts go")
        }
        .onAppear { if !Snapshot.isRunning { summaries.refreshDetection() } }
    }

    private func includeToggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(title).font(Theme.text(12.5)).foregroundStyle(Theme.ink)
        }
        .toggleStyle(.checkbox)
        .tip(value.wrappedValue ? "Included in summaries" : "Left out of summaries")
    }

    private var providerMenu: some View {
        Menu {
            // Placeholder: the built in local model lands here later.
            Button("Built in local model (coming soon)") {}.disabled(true)
            Divider()
            ForEach(SummaryProvider.allCases) { option in
                let available = summaries.detection.isAvailable(option) || !summaries.detection.checked && !Snapshot.isRunning
                Button {
                    providerRaw = option.rawValue
                } label: {
                    if option == provider { Label(label(option, available: available), systemImage: "checkmark") }
                    else { Text(label(option, available: available)) }
                }
                .disabled(!available && option != provider)
                if option == .off || option == .geminiCLI || option == .lmStudio { Divider() }
            }
            Divider()
            Button(summaries.detecting ? "Checking…" : "Check again") { summaries.refreshDetection() }
                .disabled(summaries.detecting)
        } label: {
            menuLabel("Provider", value: provider.title)
        }
        .menuStyle(.button).buttonStyle(InsetButtonStyle()).menuIndicator(.hidden)
        .tip("Choose who writes summaries")
        .accessibilityLabel("Summary provider").accessibilityValue(provider.title)
    }
    private func label(_ option: SummaryProvider, available: Bool) -> String {
        available || option.unavailableHint.isEmpty ? option.title : "\(option.title) · \(option.unavailableHint.lowercased())"
    }

    @AppStorage("summaries.model.ollama") private var ollamaModel = ""
    @AppStorage("summaries.model.lmStudio") private var lmStudioModel = ""
    private var localModel: Binding<String> { provider == .ollama ? $ollamaModel : $lmStudioModel }
    private var localModelMenu: some View {
        let models = summaries.detection.localModels[provider] ?? []
        return Menu {
            if models.isEmpty {
                Button(summaries.detection.localModels[provider] == nil ? "\(provider.title) isn't running" : "No models installed") {}.disabled(true)
            }
            ForEach(models, id: \.self) { name in
                Button {
                    localModel.wrappedValue = name
                } label: {
                    if name == localModel.wrappedValue { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button(summaries.detecting ? "Checking…" : "Refresh models") { summaries.refreshDetection() }.disabled(summaries.detecting)
        } label: {
            menuLabel("Model", value: localModel.wrappedValue.isEmpty ? "Pick a model" : localModel.wrappedValue)
        }
        .menuStyle(.button).buttonStyle(InsetButtonStyle()).menuIndicator(.hidden)
        .tip("Choose a local model")
        .accessibilityLabel("Summary model").accessibilityValue(localModel.wrappedValue)
    }

    private var whenMenu: some View {
        Menu {
            Picker("When", selection: $automatic) {
                Text("Automatically after each transcript").tag(true)
                Text("Only when I press Summarize").tag(false)
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            menuLabel("When", value: automatic ? "After each transcript" : "When I press Summarize")
        }
        .menuStyle(.button).buttonStyle(InsetButtonStyle()).menuIndicator(.hidden)
        .tip("Change setting")
        .accessibilityLabel("When to summarize").accessibilityValue(automatic ? "Automatically" : "Only when I press Summarize")
    }

    private func menuLabel(_ label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Theme.text(13)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Text(value).font(Theme.text(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
    private func hint(_ text: String, color: Color) -> some View {
        Text(text).font(Theme.text(10)).foregroundStyle(color).lineLimit(1).truncationMode(.tail).tip(text)
    }
}

// An editable model name, saved per provider.
private struct SummaryModelField: View {
    let provider: SummaryProvider
    let placeholder: String
    @AppStorage private var model: String

    init(provider: SummaryProvider, placeholder: String) {
        self.provider = provider
        self.placeholder = placeholder
        _model = AppStorage(wrappedValue: provider.defaultModel, provider.modelKey)
    }
    var body: some View {
        HStack(spacing: 10) {
            Text("Model").font(Theme.text(13)).foregroundStyle(Theme.muted)
            TextField("", text: $model, prompt: Text(placeholder).foregroundStyle(Theme.faint))
                .textFieldStyle(.plain).font(Theme.text(12)).multilineTextAlignment(.trailing)
                .accessibilityLabel("Summary model")
            if !provider.defaultModel.isEmpty, model != provider.defaultModel {
                Button { model = provider.defaultModel } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(IconButtonStyle(size: 22)).tip("Use \(provider.defaultModel)")
                    .accessibilityLabel("Use the default model")
            }
        }
        .fieldChrome()
        .tip("Model name, editable")
    }
}

// The pasted key goes straight to the Keychain; Settings only ever shows its last four characters.
private struct SummaryKeyField: View {
    let provider: SummaryProvider
    @ObservedObject var summaries: SummaryCenter
    @State private var draft = ""
    @State private var saved: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let saved {
                    Image(systemName: "key.fill").foregroundStyle(Theme.accentText).font(.system(size: 11))
                    Text(saved).font(Theme.text(12)).monospaced().foregroundStyle(Theme.ink)
                        .accessibilityLabel("Key saved in Keychain")
                    Spacer(minLength: 0)
                    Button("Remove key") { remove() }
                        .buttonStyle(PillButtonStyle(kind: .quiet, height: 26, fullWidth: false))
                        .tip("Delete the key from Keychain")
                } else {
                    SecureField("", text: $draft, prompt: Text("Paste your \(provider.title)").foregroundStyle(Theme.faint))
                        .textFieldStyle(.plain).font(Theme.text(12))
                        .onSubmit(save)
                        .accessibilityLabel(provider.title)
                    Button("Save") { save() }
                        .buttonStyle(PillButtonStyle(kind: .quiet, height: 26, fullWidth: false))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .tip("Save to Keychain")
                }
            }
            .fieldChrome()
            Text(failure ?? "Stored only in your Mac's Keychain.")
                .font(Theme.text(10)).foregroundStyle(failure == nil ? Theme.muted : Theme.validationText)
                .lineLimit(1).truncationMode(.tail)
                .tip(failure ?? "Key storage")
        }
        .onAppear(perform: load)
    }
    private func load() {
        if Snapshot.isRunning { saved = summaries.previewKeyTail; return }
        do { saved = try summaries.keychain.read(account: provider.rawValue).map(SummaryKeychain.masked) }
        catch { failure = SummaryError.short(error.localizedDescription) }
    }
    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !Snapshot.isRunning else { return }
        do {
            try summaries.keychain.save(key, account: provider.rawValue)
            draft = ""
            failure = nil
            saved = SummaryKeychain.masked(key)
        } catch { failure = SummaryError.short(error.localizedDescription) }
    }
    private func remove() {
        guard !Snapshot.isRunning else { return }
        do {
            try summaries.keychain.delete(account: provider.rawValue)
            saved = nil
            failure = nil
        } catch { failure = SummaryError.short(error.localizedDescription) }
    }
}
