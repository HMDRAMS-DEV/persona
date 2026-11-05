import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        Group {
            switch store.screen {
            case .gallery: GalleryView()
            case .create: CreateView()
            case .chat:
                HStack(spacing: 0) {
                    ChatView()
                    if store.persona != nil {
                        Inspector().frame(width: 360)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .ignoresSafeArea()
        .animation(.smooth, value: store.screen)
    }
}

// MARK: - Chat

struct ChatView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.messages.isEmpty {
                empty
            } else {
                thread
            }
            Composer()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Personas") { store.screen = .gallery }
                .buttonStyle(PillButtonStyle(prominent: false))
            if let persona = store.persona {
                Portrait(persona: persona).frame(width: 30, height: 30).clipShape(Circle())
                Text(persona.name).display(22)
            } else {
                Jolly().frame(width: 30, height: 30).clipShape(Circle())
                Text("Plain Glimmer").display(22)
            }
            Spacer()
            StatusPill()
        }
        .padding(.horizontal, 32)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let persona = store.persona {
                Portrait(persona: persona)
                    .frame(width: 132, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                Text("Say hi to \(persona.name).").display(44)
                Text(persona.intro.isEmpty ? persona.tagline : "“\(persona.intro)”")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: 560, alignment: .leading)
            } else {
                Jolly()
                    .frame(width: 132, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                Text("Glimmer, as it ships.").display(44)
                Text("No persona vectors. Ask the same thing here and in a persona to hear the difference.")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: 520, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 48)
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(store.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    if let error = store.error {
                        Text(error).font(.system(size: 14)).foregroundStyle(Theme.hot)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
            }
            .onChange(of: store.messages.last?.text) {
                if let id = store.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

struct MessageRow: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 120)
                Text(message.text)
                    .font(.system(size: 17))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Theme.quietWash, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                SteeringChips(steering: message.steering)
                Text(markdown(message.text.isEmpty && message.streaming ? "…" : message.text))
                    .font(.system(size: 17))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.scores.isEmpty {
                    ScoreRow(scores: message.scores)
                }
            }
            .padding(20)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(message.steering.isEmpty ? Theme.hairline : Theme.accent.opacity(0.5), lineWidth: 1)
            )
            .animation(.smooth, value: message.scores)
        }
    }
}

struct SteeringChips: View {
    let steering: [String: Double]

    var body: some View {
        HStack(spacing: 6) {
            if steering.isEmpty {
                Text("Plain").chip(Theme.muted, Theme.quietWash)
            } else {
                ForEach(steering.sorted(by: { $0.key < $1.key }), id: \.key) { name, value in
                    Text("\(name) \(value > 0 ? "+" : "")\(value, specifier: "%.1f")")
                        .chip(.white, Theme.accent)
                }
            }
        }
    }
}

struct ScoreRow: View {
    let scores: [String: Int]

    var body: some View {
        HStack(spacing: 14) {
            Text("Muse Wonder rates").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
            ForEach(scores.sorted(by: { $0.key < $1.key }), id: \.key) { name, score in
                HStack(spacing: 5) {
                    Text(name).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Text("\(score)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(score >= 50 ? Theme.accent : Theme.ink)
                        .contentTransition(.numericText(value: Double(score)))
                }
            }
        }
        .transition(.opacity)
    }
}

struct Composer: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            TextField("Message \(store.persona?.name ?? "Glimmer")", text: $store.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .lineLimit(1...5)
                .onSubmit { store.send() }
            Button("Send") { store.send() }
                .buttonStyle(PillButtonStyle())
                .disabled(store.busy || store.draft.isEmpty)
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.horizontal, 32)
        .padding(.bottom, 26)
        .padding(.top, 8)
    }
}

struct StatusPill: View {
    @Environment(Store.self) private var store

    var body: some View {
        switch store.status {
        case .starting:
            HStack(spacing: 7) { ProgressView().controlSize(.small); Text("Loading Glimmer") }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
        case .ready(let detail):
            HStack(spacing: 7) { Circle().fill(Theme.slack).frame(width: 7, height: 7); Text(detail) }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
        case .failed(let message):
            Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.hot)
        }
    }
}

// MARK: - Inspector

struct Inspector: View {
    @Environment(Store.self) private var store
    @State private var newTrait = ""

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tune").display(22)
                Text("Changes apply from your next message and save into the persona.")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
            }
            .padding(.top, 34)
            .padding(.bottom, 18)

            ScrollView {
                VStack(spacing: 10) {
                    if let traits = Binding($store.persona)?.traits {
                        ForEach(traits) { $trait in
                            TraitSlider(trait: $trait, score: store.lastScore(trait.name), onRelease: store.saveTune)
                        }
                    }
                }
            }
            .scrollIndicators(.never)

            VStack(alignment: .leading, spacing: 12) {
                if let step = store.building {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(step).font(.system(size: 15, weight: .medium))
                    }
                    .transition(.opacity)
                }
                HStack(spacing: 8) {
                    TextField("Add a trait in a sentence", text: $newTrait)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .onSubmit(build)
                    Button("Build", action: build)
                        .buttonStyle(PillButtonStyle())
                        .disabled(newTrait.isEmpty || store.building != nil)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(Theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                if let persona = store.persona {
                    ShareRow(persona: persona)
                }
            }
            .padding(.vertical, 26)
            .animation(.smooth, value: store.building)
        }
        .padding(.horizontal, 22)
        .background(Theme.quietWash.opacity(0.6))
    }

    private func build() {
        store.addTrait(newTrait)
        newTrait = ""
    }
}

/// Share and Export for a persona's file, with its size: the whole persona travels in it.
struct ShareRow: View {
    @Environment(Store.self) private var store
    let persona: Persona

    var body: some View {
        HStack(spacing: 8) {
            ShareLink(item: Server.file(persona)) { Text("Share") }
                .buttonStyle(PillButtonStyle())
            Button("Export…") { store.export(persona) }
                .buttonStyle(PillButtonStyle(prominent: false))
            Spacer()
            Text("\(persona.bytes / 1024) KB · v\(persona.version)")
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(Theme.muted)
        }
    }
}

struct TraitSlider: View {
    @Binding var trait: Trait
    let score: Int?
    let onRelease: () -> Void

    var body: some View {
        let on = abs(trait.value) >= 0.05
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(trait.name).font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(on ? String(format: "%+.1f", trait.value) : "Off")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(on ? Theme.accent : Theme.muted)
                    .contentTransition(.numericText(value: trait.value))
            }
            Slider(value: $trait.value, in: -1...1) { editing in
                guard !editing else { return }
                if abs(trait.value) < 0.05 { trait.value = 0 }
                onRelease()
            }
            .tint(on ? Theme.accent : Theme.muted)
            HStack {
                Text(trait.description).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                if let score {
                    Text("\(score)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(score >= 50 ? Theme.accent : Theme.muted)
                        .contentTransition(.numericText(value: Double(score)))
                }
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(on ? Theme.accent.opacity(0.5) : Theme.hairline)
        )
        .animation(.smooth, value: score)
    }
}

extension Text {
    func chip(_ foreground: Color, _ background: Color) -> some View {
        font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
    }
}

/// Glimmer writes inline markdown (**bold**, *actions*). Render it; an unclosed marker mid-stream stays literal.
func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}
