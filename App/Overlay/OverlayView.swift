import CortesKit
import SwiftUI

struct OverlayView: View {
    @Bindable var model: AppModel
    let onSizeChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch model.phase {
            case .hidden:
                EmptyView()
            case .thinking:
                ThinkingView(voices: model.voices.filter(\.enabled))
            case .streaming(let batch):
                StreamingView(model: model, batch: batch)
            case .consent(let snapshot):
                ConsentView(
                    engine: model.engine, title: snapshot.key.title,
                    allow: { model.allowAndAsk(snapshot) }, cancel: model.dismissOverlay)
            case .failure(let message):
                FailureView(
                    message: message, showGrant: !model.axTrusted, retry: model.retry,
                    grantAccessibility: model.requestAccessibility)
            case .result(let result):
                ResultView(model: model, result: result)
            }
        }
        .padding(14)
        .frame(width: OverlayController.width, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.95)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09)))
        .environment(\.colorScheme, .dark)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in onSizeChange() }
        .onHover { model.overlayHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("INNER VOICES")
                .font(.system(size: 10, weight: .heavy))
                .tracking(2)
                .foregroundStyle(.secondary)
            if let title = model.current?.key.title {
                Text(verbatim: title)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.callActive {
                Badge(text: "LISTENING", color: .red)
                Button { model.stopCall() } label: { Image(systemName: "stop.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.red).help("Stop listening and clear transcript")
            }
            if model.stale {
                Badge(text: "outdated", color: .orange)
            }
            if case .result(let result) = model.phase {
                switch result.origin {
                case .cloud: Badge(text: "CLOUD", color: .blue)
                case .local: Badge(text: "LOCAL", color: .green)
                case .replay: Badge(text: "REPLAY", color: .gray)
                }
            }
            Button(action: model.retry) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Ask again")
            Button(action: model.dismissOverlay) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.25)))
            .foregroundStyle(color)
    }
}

private struct ThinkingView: View {
    let voices: [VoiceDefinition]
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(voices) { voice in
                HStack(spacing: 8) {
                    Image(systemName: voice.ui.symbol).foregroundStyle(Color(hex: voice.ui.color))
                    Text(voice.name.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color(hex: voice.ui.color))
                    Text("is forming an opinion…")
                        .font(.system(size: 12, design: .serif))
                        .italic()
                        .foregroundStyle(.secondary)
                }
                .opacity(pulse ? 1 : 0.45)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true }
        }
    }
}

private struct ConsentView: View {
    let engine: Engine
    let title: String
    let allow: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch engine {
            case .cloud:
                Text("Send “\(title)” to z.ai?")
                    .font(.headline)
                Text("The voices run on z.ai's cloud. Recent messages from this conversation are sent with names replaced by aliases. Only allow demo or test conversations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .local:
                Text("Ask the voices about “\(title)”?")
                    .font(.headline)
                Text("The voices run locally through Ollama on this Mac. Nothing leaves the machine; names are still replaced by aliases before prompting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .replay:
                Text("Ask the voices about “\(title)”?")
                    .font(.headline)
                Text("Offline replay: a canned answer, nothing sent anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Allow and ask", action: allow).buttonStyle(.borderedProminent)
                Button("Not now", action: cancel)
            }
        }
    }
}

private struct FailureView: View {
    let message: String
    let showGrant: Bool
    let retry: () -> Void
    let grantAccessibility: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            HStack {
                if showGrant {
                    Button("Grant Accessibility…", action: grantAccessibility).buttonStyle(.borderedProminent)
                }
                Button("Retry", action: retry)
                SettingsLink { Text("Settings…") }
            }
        }
    }
}

private struct StreamingView: View {
    let model: AppModel
    let batch: VoiceBatch

    var body: some View {
        let voices = model.voices.filter(\.enabled)
        let verdict = DecisionEngine.decide(batch: batch, voices: voices)
        let completed = Set(batch.takes.map(\.id))
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: batch.read.gist)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TensionMeter(tension: batch.read.tension, need: batch.read.need)
            ForEach(verdict.ranked) { ranked in
                VoiceCard(
                    ranked: ranked, voice: model.voice(ranked.id), recommended: false,
                    copied: false, canCopy: false, copy: {})
            }
            ThinkingView(voices: voices.filter { !completed.contains($0.id) })
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(completed.count)/\(voices.count) voices ready. Copy and recommendation unlock after validation.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct ResultView: View {
    @Bindable var model: AppModel
    let result: SuggestionResult

    var body: some View {
        let verdict = result.verdict
        VStack(alignment: .leading, spacing: 8) {
            if !verdict.read.gist.isEmpty {
                Text(verbatim: verdict.read.gist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TensionMeter(tension: verdict.read.tension, need: verdict.read.need)
            if verdict.sayNothing {
                SayNothingCard(needsReply: verdict.read.need != "no")
            }
            ForEach(verdict.ranked) { ranked in
                VoiceCard(
                    ranked: ranked,
                    voice: model.voice(ranked.id),
                    recommended: verdict.recommended == ranked.id,
                    copied: model.copiedVoiceID == ranked.id,
                    copy: { model.copy(ranked) })
            }
            Text("\(result.model) · \(String(format: "%.1f", result.latency)) s\(result.repaired ? " · repaired" : "")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct TensionMeter: View {
    let tension: Int
    let need: String

    var body: some View {
        HStack(spacing: 3) {
            Text("TENSION")
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(.tertiary)
            ForEach(0..<9, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < tension ? Color(hex: "#C8553D") : Color.white.opacity(0.1))
                    .frame(width: 10, height: 4)
            }
            Spacer()
            Text(need == "now" ? "REPLY NOW" : need == "soon" ? "REPLY SOON" : "NO REPLY NEEDED")
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct SayNothingCard: View {
    let needsReply: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.secondary)
            Text(needsReply ? "Say nothing yet: every reply here is risky." : "Say nothing yet: nobody is waiting on you.")
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
    }
}

private struct VoiceCard: View {
    let ranked: RankedTake
    let voice: VoiceDefinition?
    let recommended: Bool
    let copied: Bool
    var canCopy = true
    let copy: () -> Void

    private var color: Color { Color(hex: voice?.ui.color ?? "#999999") }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: voice?.ui.symbol ?? "person.wave.2").foregroundStyle(color)
                    Text((voice?.name ?? ranked.id).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(color)
                    Text(ranked.take.strategy.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if recommended {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).help("Recommended")
                    }
                    if !ranked.eligible {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(ranked.riskReasons.joined(separator: "; "))
                    }
                }
                Text(verbatim: ranked.take.thought)
                    .font(.system(size: 14, design: .serif))
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                if !ranked.take.reply.isEmpty {
                    replyBox
                }
                if !ranked.eligible, !ranked.riskReasons.isEmpty {
                    Text("⚠ " + ranked.riskReasons.joined(separator: "; "))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(recommended ? 0.09 : 0.05)))
    }

    private var replyBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.highlightPlaceholders(ranked.take.reply))
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: copy) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(color)
            .disabled(!canCopy)
            .help(canCopy ? "Copy reply" : "Waiting for the complete answer to be validated")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
    }

    /// Makes [ETA]-style placeholders stand out so they get filled in before sending.
    static func highlightPlaceholders(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        var searchStart = result.startIndex
        while let open = result[searchStart...].characters.firstIndex(of: "["),
              let close = result[open...].characters.firstIndex(of: "]")
        {
            let range = open..<result.index(afterCharacter: close)
            result[range].foregroundColor = .yellow
            result[range].backgroundColor = Color.yellow.opacity(0.15)
            searchStart = range.upperBound
        }
        return result
    }
}

extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0x999999
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
