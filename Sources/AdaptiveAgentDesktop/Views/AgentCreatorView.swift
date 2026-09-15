import SwiftUI

struct AgentCreatorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showOverrides = false
    @State private var overwriteConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 760, height: 680)
        .interactiveDismissDisabled(model.agentCreator.isWorking)
        .confirmationDialog(
            "Override Existing Agent Profile?",
            isPresented: $overwriteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Override Existing Profile", role: .destructive) {
                model.approveAgentProfileOverwrite()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saving will replace the profile at the target path. This cannot be undone from this screen.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create Agent Profile")
                        .font(.title2.weight(.semibold))
                    Text("Generation writes nothing until you validate and save.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", action: model.dismissAgentCreator)
                    .disabled(model.agentCreator.isWorking)
            }
            HStack(spacing: 8) {
                step(1, "Brief", active: model.agentCreator.stage == .compose, complete: model.agentCreator.stage != .compose)
                stepDivider
                step(2, "Review", active: model.agentCreator.stage == .review, complete: model.agentCreator.stage == .saved)
                stepDivider
                step(3, "Save", active: model.agentCreator.stage == .saved, complete: false)
            }
        }
        .padding(24)
    }

    @ViewBuilder private var content: some View {
        switch model.agentCreator.stage {
        case .compose:
            composeContent
        case .review:
            reviewContent
        case .saved:
            savedContent
        }
    }

    private var composeContent: some View {
        Form {
            Section("What should this agent do?") {
                TextEditor(text: $model.agentCreator.brief)
                    .font(.body)
                    .frame(minHeight: 150)
                    .overlay(alignment: .topLeading) {
                        if model.agentCreator.brief.isEmpty {
                            Text("For example: Create a TypeScript security reviewer that prioritizes exploitable findings.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("agent-creator-brief")
                TextField("Generator agent", text: $model.agentCreator.generatorAgent,
                          prompt: Text("Current agent"))
                    .font(.body.monospaced())
                Text("Leave the generator blank to use the current agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Optional controls", isExpanded: $showOverrides) {
                TextField("Agent ID", text: $model.agentCreator.idOverride,
                          prompt: Text("Generated from the brief"))
                    .font(.body.monospaced())
                Picker("Provider", selection: $model.agentCreator.providerOverride) {
                    Text("Generator default").tag("")
                    Text("OpenRouter").tag("openrouter")
                    Text("Ollama").tag("ollama")
                    Text("Mistral").tag("mistral")
                    Text("Mesh").tag("mesh")
                }
                TextField("Model", text: $model.agentCreator.modelOverride,
                          prompt: Text("Generator default"))
                    .font(.body.monospaced())
                Text("Blank controls are omitted from the request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.agentCreator.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var reviewContent: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Generated Agent JSON")
                    .font(.headline)
                TextEditor(text: agentJSONBinding)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Generated Agent JSON")
                    .accessibilityIdentifier("agent-creator-json")
                Text("Review or edit the generated configuration before validation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(minWidth: 400)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    targetCard
                    detailSection("Notes", values: model.agentCreator.draft?.notes ?? [])
                    detailSection("Recommendations", values: model.agentCreator.draft?.recommendations ?? [])
                    if let generator = model.agentCreator.draft?.generatorAgent {
                        Label("Generated by \(generator.name) · \(generator.id)", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = model.agentCreator.errorMessage,
                       error != "Edit ID or override to Validate and Save." {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 275, idealWidth: 300)
        }
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Target").font(.headline)
            Text(model.agentCreator.validation?.path ?? model.agentCreator.draft?.path ?? "Unknown")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            if model.agentCreator.hasUnresolvedCollision {
                VStack(alignment: .leading, spacing: 8) {
                    Label("This agent ID already exists.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                    ForEach(model.agentCreator.duplicatePaths, id: \.self) { path in
                        Text(path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Edit ID", action: model.returnToAgentCreatorBrief)
                            .accessibilityLabel("Edit ID")
                            .accessibilityIdentifier("agent-creator-edit-id")
                        if model.agentCreator.canOverrideExistingTarget {
                            Button("Override…") { overwriteConfirmationPresented = true }
                                .accessibilityLabel("Override Existing Profile")
                                .accessibilityIdentifier("agent-creator-override")
                        }
                    }
                    .buttonStyle(.link)
                }
                .foregroundStyle(.orange)
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else if model.agentCreator.overwriteApproved {
                Label("Existing profile override approved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if model.agentCreator.validation != nil {
                Label("Configuration valid", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var savedContent: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("Agent Profile Saved")
                .font(.title2.weight(.semibold))
            Text(model.agentCreator.savedPath ?? "")
                .font(.body.monospaced())
                .textSelection(.enabled)
            Text("The new profile is selected for the next runtime restart.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.agentCreator.stage == .review && model.agentCreator.hasUnresolvedCollision {
                Label(
                    model.agentCreator.canOverrideExistingTarget
                        ? "Edit ID or override to Validate and Save."
                        : "Edit ID to resolve duplicate profiles before validating.",
                    systemImage: "exclamationmark.circle.fill"
                )
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.agentCreator.stage == .review, model.agentCreator.validation != nil {
                Label("Configuration valid", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            switch model.agentCreator.stage {
            case .compose:
                Button("Cancel", action: model.dismissAgentCreator)
                Button(action: model.generateAgentDraft) {
                    if model.agentCreator.isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Generate Draft")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.agentCreator.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || model.agentCreator.isWorking)
                .accessibilityIdentifier("agent-creator-generate")
            case .review:
                Button("Back", action: model.returnToAgentCreatorBrief)
                    .disabled(model.agentCreator.isWorking)
                Button(action: model.validateAgentDraft) {
                    if model.agentCreator.isValidating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Validate")
                    }
                }
                .disabled(model.agentCreator.hasUnresolvedCollision || model.agentCreator.isWorking)
                .accessibilityLabel("Validate Agent Profile")
                .accessibilityIdentifier("agent-creator-validate")
                Button(action: model.saveAgentDraft) {
                    if model.agentCreator.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save Agent")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.agentCreator.validation == nil
                          || model.agentCreator.hasUnresolvedCollision
                          || model.agentCreator.isWorking)
                .accessibilityLabel("Save Agent Profile")
                .accessibilityIdentifier("agent-creator-save")
            case .saved:
                Button("Done", action: model.dismissAgentCreator)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 64)
    }

    private var agentJSONBinding: Binding<String> {
        Binding(
            get: { model.agentCreator.agentJSON },
            set: { model.updateAgentDraftJSON($0) }
        )
    }

    private func detailSection(_ title: String, values: [String]) -> some View {
        DisclosureGroup(title) {
            if values.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(values, id: \.self) { value in
                    Text("• \(value)")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func step(_ number: Int, _ title: String, active: Bool, complete: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: complete ? "checkmark.circle.fill" : "\(number).circle.fill")
                .foregroundStyle(active || complete ? Color.teal : Color.secondary)
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    private var stepDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 44, height: 1)
    }
}
