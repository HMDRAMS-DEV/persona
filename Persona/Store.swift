import AppKit
import Foundation
import Observation

struct Message: Identifiable {
    enum Role: String { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    /// The slider values the reply was generated with, nonzero only.
    var steering: [String: Double] = [:]
    /// Muse Wonder's 0-100 scores for this reply, per trait.
    var scores: [String: Int] = [:]
    var streaming = false
}

/// The create walkthrough: interview answers in, then the server's build steps, then the persona.
struct Creation {
    var answers: [String] = Array(repeating: "", count: Interview.questions.count)
    var steps: [String] = []
    var name: String?
    var tagline: String?
    var persona: Persona?
    var running = false
}

@MainActor @Observable
final class Store {
    enum Status: Equatable { case starting, ready(String), failed(String) }
    enum Screen: Equatable { case gallery, create, chat }

    var status: Status = .starting
    /// Bytes of Glimmer's weights fetched so far, while the first launch downloads them.
    var downloaded: Int64?
    var screen: Screen = .gallery
    var personas: [Persona] = []
    /// The persona being chatted with. Nil is plain Glimmer.
    var persona: Persona?
    var messages: [Message] = []
    var draft = ""
    var creation = Creation()
    /// The label of the current add-a-trait step, while one is running.
    var building: String?
    var error: String?
    var busy = false
    /// False until an OpenRouter key is saved. Creating and adding traits need one; chatting doesn't.
    var hasKey = true

    private var generation: Task<Void, Never>?
    /// Files opened from Finder before the server was ready.
    private var pendingImports: [URL] = []

    func start() async {
        status = .starting
        if await Server.health() == nil {
            do { try Server.launch() } catch { status = .failed(error.localizedDescription); return }
        }
        // First launch downloads 19 GB of weights. After that, loading them takes about a minute.
        while true {
            if let health = await Server.health() {
                downloaded = nil
                status = .ready("Layer \(health.layer) of \(health.layers)")
                hasKey = health.key
                await loadPersonas()
                let pending = pendingImports
                pendingImports = []
                importFiles(pending)
                return
            }
            guard Server.running else {
                let log = (try? String(contentsOf: Server.root.appending(path: "build/server.log"), encoding: .utf8)) ?? ""
                // Python's last error line says why; download progress bars don't.
                let reason = log.split(whereSeparator: \.isNewline).last { $0.contains("Error") }.map { String($0.prefix(240)) }
                status = .failed(reason.map { "\($0). See build/server.log." } ?? "Glimmer stopped. See build/server.log.")
                return
            }
            downloaded = Server.download()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func loadPersonas() async {
        if let list = try? await Server.personas() { personas = list }
    }

    // MARK: Chat

    func open(_ persona: Persona?) {
        generation?.cancel()
        self.persona = persona
        messages = []
        busy = false
        error = nil
        screen = .chat
    }

    var steering: [String: Double] {
        var values: [String: Double] = [:]
        for trait in persona?.traits ?? [] where abs(trait.value) >= 0.05 {
            values[trait.name] = (trait.value * 100).rounded() / 100
        }
        return values
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""
        messages.append(Message(role: .user, text: text))
        reply()
    }

    private func reply() {
        let steering = steering
        let context = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let question = messages.last(where: { $0.role == .user })?.text ?? ""
        messages.append(Message(role: .assistant, text: "", steering: steering, streaming: true))
        let index = messages.count - 1
        busy = true
        error = nil
        var body: [String: Any] = ["messages": context, "coefs": steering]
        if let slug = persona?.slug { body["persona"] = slug }
        generation = Task {
            do {
                for try await event in Server.stream("chat", body) {
                    if let piece = event.t { messages[index].text += piece }
                }
            } catch {
                self.error = error.localizedDescription
            }
            messages[index].streaming = false
            busy = false
            await score(index, question: question)
        }
    }

    private func score(_ index: Int, question: String) async {
        guard let slug = persona?.slug, index < messages.count, !messages[index].text.isEmpty else { return }
        if let judgement = try? await Server.judge(persona: slug, question: question, answer: messages[index].text) {
            messages[index].scores = judgement.scores
        }
    }

    /// Latest Muse Wonder score for a trait, from the newest scored reply.
    func lastScore(_ trait: String) -> Int? {
        messages.last(where: { $0.role == .assistant && !$0.scores.isEmpty })?.scores[trait]
    }

    func clear() {
        generation?.cancel()
        messages = []
        busy = false
    }

    // MARK: Tuning

    /// Saves the current slider values into the persona file as a new version.
    func saveTune() {
        guard let persona else { return }
        let values = Dictionary(uniqueKeysWithValues: persona.traits.map { ($0.name, $0.value) })
        Task {
            do { replace(try await Server.tune(persona.slug, values: values)) }
            catch { self.error = error.localizedDescription }
        }
    }

    func addTrait(_ description: String) {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slug = persona?.slug, !description.isEmpty, building == nil else { return }
        building = "Sending to Muse Wonder"
        error = nil
        Task {
            do {
                for try await event in Server.stream("personas/\(slug)/traits", ["trait": description]) {
                    if let label = event.label { building = label }
                    if let done = event.persona { replace(done) }
                }
            } catch {
                self.error = error.localizedDescription
            }
            building = nil
        }
    }

    private func replace(_ updated: Persona) {
        if let i = personas.firstIndex(where: { $0.slug == updated.slug }) { personas[i] = updated } else { personas.append(updated) }
        if persona?.slug == updated.slug { persona = updated }
    }

    // MARK: Create

    func saveKey(_ key: String) async {
        error = nil
        do { hasKey = try await Server.saveKey(key).key }
        catch { self.error = error.localizedDescription }
    }

    func startCreating() {
        creation = Creation()
        screen = .create
    }

    func create() {
        guard !creation.running else { return }
        let answers = zip(Interview.questions.map(\.prompt), creation.answers).map { [$0, $1] }
        creation.running = true
        creation.steps = []
        error = nil
        Task {
            do {
                for try await event in Server.stream("personas", ["answers": answers]) {
                    if let name = event.name { creation.name = name; creation.tagline = event.tagline }
                    if let label = event.label { creation.steps.append(label) }
                    if let done = event.persona {
                        replace(done)
                        creation.persona = done
                    }
                }
            } catch {
                self.error = error.localizedDescription
                if let health = await Server.health() { hasKey = health.key }
            }
            creation.running = false
        }
    }

    // MARK: Files

    func importFiles(_ urls: [URL]) {
        guard case .ready = status else { pendingImports += urls; return }
        Task {
            for url in urls {
                do {
                    let persona = try await Server.importFile(url)
                    replace(persona)
                    if urls.count == 1 { open(persona) }
                } catch {
                    self.error = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.persona]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func export(_ persona: Persona) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.persona]
        panel.nameFieldStringValue = "\(persona.name).persona"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: Server.file(persona), to: url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ persona: Persona) {
        personas.removeAll { $0.slug == persona.slug }
        Task { try? await Server.delete(persona.slug) }
    }
}
