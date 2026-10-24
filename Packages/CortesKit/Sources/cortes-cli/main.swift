import CortesKit
import Foundation

// Developer CLI:
//   cortes-cli slack [--raw]                 read the focused Slack conversation (text masked unless --raw)
//   cortes-cli prompt <scenario> [count] [--business]  print the prompts for a demo scenario
//   cortes-cli ask <scenario> [count] [--business]     run the pipeline; picks the backend from the environment:
//                                            ZAI_API_KEY → z.ai, OLLAMA_URL/OLLAMA_MODEL → local Ollama,
//                                            otherwise the offline replay backend

func mask(_ text: String) -> String {
    String(text.map { $0.isLetter ? ($0.isUppercase ? "X" : "x") : ($0.isNumber ? "9" : $0) })
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func scenario(_ id: String?) -> Scenario {
    let all = Scenario.loadBundled()
    guard let id else { fail("scenario id required: \(all.map(\.id).joined(separator: ", "))") }
    guard let found = all.first(where: { $0.id == id }) else {
        fail("unknown scenario \(id); known: \(all.map(\.id).joined(separator: ", "))")
    }
    return found
}

let perspectiveMode: PerspectiveMode = CommandLine.arguments.contains("--business") ? .business : .innerVoices
let args = CommandLine.arguments.dropFirst().filter { $0 != "--business" }
switch args.first {
case "slack":
    let raw = args.contains("--raw")
    do {
        let start = Date()
        let snapshot = try SlackAXReader().read()
        print("read in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        print("title: \(raw ? snapshot.key.title : mask(snapshot.key.title))  kind: \(snapshot.kind.rawValue)")
        print("me: \(snapshot.myName.map { raw ? $0 : mask($0) } ?? "unknown")  anchor: \(snapshot.anchorFrame.map { "\($0)" } ?? "none")")
        for message in snapshot.messages {
            let author = raw ? message.author : mask(message.author)
            let text = raw ? message.text : mask(message.text)
            print("[\(message.id)] \(message.time ?? "--:--") \(message.isMe ? "ME " : "")\(author): \(text.replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
        print("revision: \(snapshot.revision)  attention: \(TriggerPolicy.attentionScore(snapshot))")
        if args.contains("--prompt") {
            // What the model receives: speaker labels in clear, message text masked unless --raw.
            let (chat, _) = SuggestionEngine.prepare(snapshot, pseudonymize: true)
            print("--- prompt (\(chat.kind.rawValue), title \(raw ? chat.title : mask(chat.title)))")
            for message in chat.messages {
                print("\(message.n) from=\(message.from): \(raw ? message.text : mask(message.text))".replacingOccurrences(of: "\n", with: " ⏎ "))
            }
            print(PromptBuilder.user(chat: chat, mode: "manual").components(separatedBy: "\n").last ?? "")
        }
    } catch {
        fail("Slack read failed: \(error.localizedDescription)")
    }

case "prompt":
    let s = scenario(args.dropFirst().first)
    let count = args.dropFirst(2).first.flatMap(Int.init) ?? s.lines.count
    let (chat, _) = SuggestionEngine.prepare(s.snapshot(visibleCount: count), pseudonymize: true)
    print(PromptBuilder.system(voices: VoiceRegistry.load(mode: perspectiveMode), perspectiveMode: perspectiveMode))
    print("---")
    print(PromptBuilder.user(chat: chat, mode: "manual"))

case "ask":
    let s = scenario(args.dropFirst().first)
    let count = args.dropFirst(2).first.flatMap(Int.init) ?? s.lines.count
    let env = ProcessInfo.processInfo.environment
    let backend: any LLMBackend =
        if let key = env["ZAI_API_KEY"], !key.isEmpty {
            ZAIBackend(config: ZAIConfig(
                baseURL: env["ZAI_BASE_URL"] ?? ZAIEndpoint.general,
                model: env["ZAI_MODEL"] ?? "glm-5.2",
                apiKey: key))
        } else if env["OLLAMA_URL"] != nil || env["OLLAMA_MODEL"] != nil {
            OllamaBackend(config: OllamaConfig(
                baseURL: env["OLLAMA_URL"] ?? OllamaConfig.defaultURL,
                model: env["OLLAMA_MODEL"] ?? OllamaConfig.defaultModel))
        } else {
            ReplayBackend(perspectiveMode: perspectiveMode)
        }
    let engine = SuggestionEngine(
        backend: backend, voices: VoiceRegistry.load(mode: perspectiveMode), perspectiveMode: perspectiveMode)
    do {
        let result = try await engine.run(SuggestionRequest(snapshot: s.snapshot(visibleCount: count), mode: "manual", pseudonymize: true))
        let read = result.verdict.read
        print("model: \(result.model)  latency: \(String(format: "%.1f", result.latency)) s  repaired: \(result.repaired)")
        print("read: to_me=\(read.toMe) need=\(read.need) tension=\(read.tension) register=\(read.register) clarity=\(read.clarity) gist=\(read.gist)")
        print("recommended: \(result.verdict.recommended ?? "say nothing yet")")
        for ranked in result.verdict.ranked {
            let take = ranked.take
            print("\n\(take.voiceID.uppercased()) [\(take.strategy)] utility=\(String(format: "%.2f", ranked.utility)) risk=\(ranked.finalRisk) eligible=\(ranked.eligible) \(ranked.riskReasons.joined(separator: "; "))")
            print("  thought: \(take.thought)")
            print("  reply:   \(take.reply)")
            if !take.issues.isEmpty { print("  issues:  \(take.issues.joined(separator: "; "))") }
        }
    } catch {
        fail("ask failed: \(error.localizedDescription)")
    }

default:
    fail("usage: cortes-cli slack [--raw] | prompt <scenario> [count] [--business] | ask <scenario> [count] [--business]")
}
