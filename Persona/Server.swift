import Foundation

/// The local Python server that runs Muse Glimmer and talks to Muse Wonder.
/// The app starts it if nothing answers on the port, and stops it on quit.
enum Server {
    static let base = URL(string: "http://127.0.0.1:4410")!
    /// The repo checkout. The app bundle sits in build/, so its grandparent is the repo.
    static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["PERSONA_ROOT"] { return URL(fileURLWithPath: path) }
        return Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    }()

    nonisolated(unsafe) private static var process: Process?

    static func health() async -> Health? {
        var request = URLRequest(url: base.appending(path: "health"))
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(Health.self, from: data)
    }

    static func launch() throws {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = root.appending(path: ".venv/bin/python")
        p.arguments = [root.appending(path: "server/persona.py").path]
        p.currentDirectoryURL = root
        let log = root.appending(path: "build/server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        process = p
    }

    static func stop() { process?.terminate() }

    static func personas() async throws -> [Persona] {
        let (data, _) = try await URLSession.shared.data(from: base.appending(path: "personas"))
        return try JSONDecoder().decode([Persona].self, from: data)
    }

    static func portrait(_ persona: Persona) -> URL {
        base.appending(path: "personas/\(persona.slug)/portrait").appending(queryItems: [.init(name: "v", value: "\(persona.version)")])
    }

    /// The shareable file itself. Exporting a persona is copying this.
    static func file(_ persona: Persona) -> URL {
        root.appending(path: "personas/\(persona.slug).persona")
    }

    static func tune(_ slug: String, values: [String: Double]) async throws -> Persona {
        try await send("personas/\(slug)", method: "PATCH", ["values": values])
    }

    static func saveKey(_ key: String) async throws -> KeyStatus {
        try await send("key", method: "POST", ["key": key])
    }

    static func importFile(_ url: URL) async throws -> Persona {
        try await send("personas/import", method: "POST", ["path": url.path])
    }

    static func delete(_ slug: String) async throws {
        var request = URLRequest(url: base.appending(path: "personas/\(slug)"))
        request.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: request)
    }

    /// One JSON request and response. A 4xx carries FastAPI's {"detail": message}.
    private static func send<T: Decodable>(_ path: String, method: String, _ body: [String: Any]) async throws -> T {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw detail.map(ServerError.message) ?? ServerError.status(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Posts JSON and yields each `data:` line of the event stream, decoded.
    static func stream(_ path: String, _ body: [String: Any]) -> AsyncThrowingStream<Event, Error> {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return AsyncThrowingStream { [request] continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw ServerError.status(http.statusCode)
                    }
                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        let event = try JSONDecoder().decode(Event.self, from: Data(line.dropFirst(6).utf8))
                        if let message = event.error { throw ServerError.message(message) }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func judge(persona: String, question: String, answer: String) async throws -> Judgement {
        try await send("judge", method: "POST", ["persona": persona, "question": question, "answer": answer])
    }
}

/// One server-sent event: a chat token, a building step, a finished persona, or an error.
struct Event: Decodable, Sendable {
    let t: String?
    let step: String?
    let label: String?
    let error: String?
    /// Sent once Muse Wonder has designed a persona, before it is built.
    let name: String?
    let tagline: String?
    /// The finished persona. Chat's "done" carries stats instead, so this stays nil there.
    let persona: Persona?

    enum CodingKeys: String, CodingKey { case t, step, label, error, name, tagline, done }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decodeIfPresent(String.self, forKey: .t)
        step = try c.decodeIfPresent(String.self, forKey: .step)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        tagline = try c.decodeIfPresent(String.self, forKey: .tagline)
        persona = try? c.decodeIfPresent(Persona.self, forKey: .done)
    }
}

enum ServerError: LocalizedError {
    case status(Int)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .status(let code): "The server answered \(code)."
        case .message(let text): text
        }
    }
}

struct Health: Decodable, Sendable {
    let model: String
    let layer: Int
    let layers: Int
    /// Whether the server has an OpenRouter key for Muse Wonder and Muse Image.
    let key: Bool
}

struct KeyStatus: Decodable, Sendable { let key: Bool }

/// A persona as the server lists it: no vectors, no portrait bytes.
struct Persona: Decodable, Sendable, Identifiable, Hashable {
    var id: String { slug }
    let slug: String
    let name: String
    let tagline: String
    let intro: String
    let version: Int
    let bytes: Int
    let portrait: Bool
    var traits: [Trait]
}

struct Trait: Decodable, Sendable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    var value: Double
}

struct Judgement: Decodable, Sendable {
    let scores: [String: Int]
    let coherent: Int?
}
