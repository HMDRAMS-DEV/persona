import AppKit
import SwiftUI

@main
struct PersonaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store = Store()

    var body: some Scene {
        Window("Persona", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    delegate.store = store
                    await store.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Persona") { store.startCreating() }.keyboardShortcut("n")
                Button("New Chat") { store.clear() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Import Persona…") { store.chooseImport() }.keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened from Finder before the window's task ran wait here.
    var store: Store? {
        didSet { store?.importFiles(early); early = [] }
    }
    private var early: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let store { store.importFiles(urls) } else { early += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { Server.stop() }
}
