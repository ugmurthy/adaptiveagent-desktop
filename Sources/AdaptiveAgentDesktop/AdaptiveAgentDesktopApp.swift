import AppKit
import SwiftUI

private struct FocusedAppModelKey: FocusedValueKey {
    typealias Value = AppModel
}

private extension FocusedValues {
    var appModel: AppModel? {
        get { self[FocusedAppModelKey.self] }
        set { self[FocusedAppModelKey.self] = newValue }
    }
}

@MainActor
final class ApplicationModelRegistry: ObservableObject {
    private final class WeakModel {
        weak var value: AppModel?

        init(_ value: AppModel) {
            self.value = value
        }
    }

    private var models: [ObjectIdentifier: WeakModel] = [:]
    private var isTerminating = false

    var registeredModelCount: Int {
        removeReleasedModels()
        return models.count
    }

    func register(_ model: AppModel) {
        removeReleasedModels()
        models[ObjectIdentifier(model)] = WeakModel(model)
        model.applicationQuitHandler = { [weak self] source, confirmed in
            self?.requestQuit(from: source, confirmed: confirmed)
        }
    }

    func close(_ model: AppModel) {
        models.removeValue(forKey: ObjectIdentifier(model))
        model.applicationQuitHandler = nil
        Task { await model.shutdown() }
    }

    func shutdownAll() async {
        let activeModels = liveModels
        await withTaskGroup(of: Void.self) { group in
            for model in activeModels {
                group.addTask { await model.shutdown() }
            }
        }
    }

    private var liveModels: [AppModel] {
        removeReleasedModels()
        return models.values.compactMap(\.value)
    }

    private func requestQuit(from source: AppModel, confirmed: Bool) {
        guard !isTerminating else { return }
        if !confirmed, liveModels.contains(where: \.hasActiveWork) {
            source.showQuitConfirmation = true
            return
        }
        isTerminating = true
        Task {
            await shutdownAll()
            NSApplication.shared.terminate(nil)
        }
    }

    private func removeReleasedModels() {
        models = models.filter { $0.value.value != nil }
    }
}

@MainActor
final class WindowModelOwner: ObservableObject {
    let model: AppModel

    init(registry: ApplicationModelRegistry, model: AppModel = AppModel()) {
        self.model = model
        registry.register(model)
    }
}

private struct DesktopWindowView: View {
    @StateObject private var owner: WindowModelOwner
    private let registry: ApplicationModelRegistry

    @MainActor
    init(registry: ApplicationModelRegistry) {
        self.registry = registry
        _owner = StateObject(wrappedValue: WindowModelOwner(registry: registry))
    }

    var body: some View {
        ContentView()
            .environmentObject(owner.model)
            .focusedSceneValue(\.appModel, owner.model)
            .background {
                WindowCloseObserver {
                    registry.close(owner.model)
                }
            }
    }
}

private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.observe(window: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.observe(window: view.window) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator {
        private let onClose: @MainActor () -> Void
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        init(onClose: @escaping @MainActor () -> Void) {
            self.onClose = onClose
        }

        @MainActor
        func observe(window: NSWindow?) {
            guard let window, self.window !== window else { return }
            stopObserving()
            self.window = window
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose() }
            }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            window = nil
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

private struct AdaptiveAgentCommands: Commands {
    @FocusedValue(\.appModel) private var model

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Run") { model?.newRun() }
                .keyboardShortcut("n")
                .disabled(model?.isConnected != true)
            Button("New Chat") { model?.newChat() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model?.isConnected != true)
        }
        CommandGroup(replacing: .appTermination) {
            Button("Quit AdaptiveAgent Desktop") { model?.requestQuit() }
                .keyboardShortcut("q")
                .disabled(model == nil)
        }
    }
}

@main
struct AdaptiveAgentDesktopApp: App {
    @StateObject private var registry = ApplicationModelRegistry()

    var body: some Scene {
        WindowGroup {
            DesktopWindowView(registry: registry)
        }
        .commands {
            AdaptiveAgentCommands()
        }
        Settings {
            MarkdownSettingsView()
        }
    }
}
