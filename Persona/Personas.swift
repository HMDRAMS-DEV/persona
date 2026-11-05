import SwiftUI
import UniformTypeIdentifiers

// MARK: - Gallery

struct GalleryView: View {
    @Environment(Store.self) private var store
    @State private var dropping = false

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pick a persona.").display(52)
                        Text("Each one is a few persona vectors inside Glimmer, saved in one small file. Make your own, tune it as you talk, and share it.")
                            .font(.system(size: 19))
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: 600, alignment: .leading)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        StatusPill()
                        Button("Import…") { store.chooseImport() }
                            .buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
                if let error = store.error {
                    Text(error).font(.system(size: 15)).foregroundStyle(Theme.hot)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    NewCard()
                    ForEach(store.personas) { persona in
                        PersonaCard(persona: persona)
                    }
                    PlainCard()
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 54)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.pathExtension == "persona" }
            store.importFiles(files)
            return !files.isEmpty
        } isTargeted: { dropping = $0 }
    }
}

struct PersonaCard: View {
    @Environment(Store.self) private var store
    let persona: Persona

    var body: some View {
        Button { store.open(persona) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Portrait(persona: persona)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(persona.name).font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(persona.tagline)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .cardStyle()
        }
        .buttonStyle(PressStyle())
        .contextMenu {
            Button("Export…") { store.export(persona) }
            ShareLink(item: Server.file(persona)) { Text("Share…") }
            Divider()
            Button("Delete", role: .destructive) { store.delete(persona) }
        }
    }
}

struct NewCard: View {
    @Environment(Store.self) private var store

    var body: some View {
        Button { store.startCreating() } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent)
                    Image(systemName: "plus").font(.system(size: 56, weight: .semibold)).foregroundStyle(.white)
                }
                .aspectRatio(1, contentMode: .fit)
                Text("Make your own").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Answer five questions. About a minute.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(3, reservesSpace: true)
            }
            .cardStyle()
        }
        .buttonStyle(PressStyle())
    }
}

struct PlainCard: View {
    @Environment(Store.self) private var store

    var body: some View {
        Button { store.open(nil) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(Jolly())
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Plain Glimmer").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("No persona vectors. The control.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(3, reservesSpace: true)
            }
            .cardStyle()
        }
        .buttonStyle(PressStyle())
    }
}

/// Plain Glimmer's face: Jolly as designed, the same reference Muse Image dresses up for each persona.
struct Jolly: View {
    private static let image = NSImage(contentsOf: Server.root.appending(path: "server/assets/jolly.jpg"))

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack { Theme.quietWash; Text("G").display(48).foregroundStyle(Theme.muted) }
        }
    }
}

/// The persona's Muse Image portrait, or its initial while loading or if it has none.
struct Portrait: View {
    let persona: Persona

    var body: some View {
        if persona.portrait {
            AsyncImage(url: Server.portrait(persona)) { image in
                image.resizable().scaledToFill()
            } placeholder: { initial }
        } else {
            initial
        }
    }

    private var initial: some View {
        ZStack {
            Theme.quietWash
            Text(String(persona.name.prefix(1))).display(48).foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Create

struct CreateView: View {
    @Environment(Store.self) private var store
    @State private var index = 0
    @State private var forward = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button("Personas") { store.screen = .gallery }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .disabled(store.creation.running)
                Spacer()
                if store.creation.steps.isEmpty {
                    Dots(count: Interview.questions.count, current: index)
                }
            }
            .padding(.top, 34)

            Group {
                if let persona = store.creation.persona {
                    Reveal(persona: persona)
                } else if !store.creation.steps.isEmpty || store.creation.running {
                    Making()
                } else if !store.hasKey {
                    KeyView()
                } else {
                    // Each question keeps its own index, so the outgoing one doesn't redraw as the next.
                    QuestionView(index: index) { new in
                        forward = new > index
                        withAnimation(.smooth(duration: 0.35)) { index = new }
                    }
                    .id(index)
                    .transition(.push(from: forward ? .trailing : .leading))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 40)
    }
}

/// Asks for an OpenRouter or Meta Model API key before the interview, since Muse Wonder and Muse Image run there.
struct KeyView: View {
    @Environment(Store.self) private var store
    @State private var key = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("One key first.").display(52)
                Text("Muse Wonder designs your persona and Muse Image paints it. Paste a Meta Model API key or an OpenRouter key. Glimmer stays on this Mac, and your key is saved in .env here.")
                    .font(.system(size: 19)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: 620, alignment: .leading)
            }
            SecureField("Meta or OpenRouter API key", text: $key)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
                .frame(maxWidth: 760)
                .onSubmit(save)
            if let error = store.error {
                Text(error).font(.system(size: 15)).foregroundStyle(Theme.hot)
            }
            HStack(spacing: 10) {
                Button(saving ? "Checking…" : "Continue", action: save)
                    .buttonStyle(PillButtonStyle())
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                Link("Get a Meta key", destination: URL(string: "https://dev.meta.ai")!)
                    .buttonStyle(PillButtonStyle(prominent: false))
                Link("Get an OpenRouter key", destination: URL(string: "https://openrouter.ai/keys")!)
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
            Spacer()
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task { await store.saveKey(key); saving = false }
    }
}

struct Dots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? Theme.accent : Theme.hairline)
                    .frame(width: i == current ? 22 : 8, height: 8)
            }
        }
        .animation(.smooth, value: current)
    }
}

struct QuestionView: View {
    @Environment(Store.self) private var store
    let index: Int
    let go: (Int) -> Void

    private var question: Interview.Question { Interview.questions[index] }
    private var last: Bool { index == Interview.questions.count - 1 }

    var body: some View {
        @Bindable var store = store
        let answer = $store.creation.answers[index]
        VStack(alignment: .leading, spacing: 26) {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("Question \(index + 1) of \(Interview.questions.count)")
                    .font(.system(size: 19)).foregroundStyle(Theme.muted)
                Text(question.prompt).display(52)
            }
            if !question.options.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), alignment: .leading, spacing: 12) {
                    ForEach(question.options, id: \.self) { option in
                        let on = answer.wrappedValue == option
                        Button {
                            // Picking an option answers the question: show the pick briefly, then move on.
                            answer.wrappedValue = option
                            if !last {
                                Task { try? await Task.sleep(for: .milliseconds(180)); go(index + 1) }
                            }
                        } label: {
                            Text(option)
                                .font(.system(size: 19, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(on ? .white : Theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 18)
                                .background(on ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(on ? Theme.accent : Theme.hairline))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .frame(maxWidth: 760)
            }
            TextField(question.placeholder, text: custom(answer))
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
                .frame(maxWidth: 760)
                .onSubmit(next)
            HStack(spacing: 10) {
                if index > 0 {
                    Button("Back") { go(index - 1) }.buttonStyle(PillButtonStyle(prominent: false))
                }
                Button(last ? "Make my persona" : "Next", action: next)
                    .buttonStyle(PillButtonStyle())
                    .disabled(!last && answer.wrappedValue.isEmpty)
            }
            Spacer()
        }
    }

    /// The text field shows only a typed answer; picking an option clears it.
    private func custom(_ answer: Binding<String>) -> Binding<String> {
        Binding(get: { question.options.contains(answer.wrappedValue) ? "" : answer.wrappedValue },
                set: { answer.wrappedValue = $0 })
    }

    private func next() {
        if last {
            store.create()
        } else if !store.creation.answers[index].isEmpty {
            go(index + 1)
        }
    }
}

struct Making: View {
    @Environment(Store.self) private var store

    var body: some View {
        let creation = store.creation
        VStack(alignment: .leading, spacing: 26) {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text(creation.name.map { "Meet \($0)." } ?? "Designing your persona.").display(52)
                    .contentTransition(.opacity)
                Text(creation.tagline ?? "Muse Wonder is reading your answers.")
                    .font(.system(size: 19)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: 600, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(creation.steps.enumerated()), id: \.offset) { i, step in
                    let current = i == creation.steps.count - 1 && creation.running
                    HStack(spacing: 10) {
                        if current {
                            ProgressView().controlSize(.small).frame(width: 18)
                        } else {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.slack).frame(width: 18)
                        }
                        Text(step).font(.system(size: 17, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? Theme.ink : Theme.muted)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            if let error = store.error {
                VStack(alignment: .leading, spacing: 12) {
                    Text(error).font(.system(size: 15)).foregroundStyle(Theme.hot)
                    Button("Try again") { store.create() }.buttonStyle(PillButtonStyle())
                }
            }
            Spacer()
        }
        .animation(.smooth, value: creation.steps)
        .animation(.smooth, value: creation.name)
    }
}

struct Reveal: View {
    @Environment(Store.self) private var store
    let persona: Persona
    @State private var shown = false

    var body: some View {
        HStack(alignment: .center, spacing: 44) {
            Portrait(persona: persona)
                .frame(width: 340, height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .scaleEffect(shown ? 1 : 0.85)
                .rotationEffect(.degrees(shown ? 0 : -4))
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(persona.name).display(56)
                    Text(persona.tagline).font(.system(size: 19)).foregroundStyle(Theme.muted)
                }
                Text("“\(persona.intro)”")
                    .font(.system(size: 19))
                    .lineSpacing(4)
                    .padding(20)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.5)))
                HStack(spacing: 6) {
                    ForEach(persona.traits) { trait in
                        Text("\(trait.name) \(trait.value, specifier: "%+.1f")").chip(.white, Theme.accent)
                    }
                }
                HStack(spacing: 10) {
                    Button("Start chatting") { store.open(persona) }.buttonStyle(PillButtonStyle())
                    ShareLink(item: Server.file(persona)) { Text("Share") }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    Button("Make another") { store.startCreating() }.buttonStyle(PillButtonStyle(prominent: false))
                }
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
        }
        .frame(maxHeight: .infinity)
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.3)) { shown = true } }
    }
}

// MARK: - Styles

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

extension View {
    func cardStyle() -> some View {
        padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
