import CortesKit
import SwiftUI

/// A neutral chat window fed by scripted scenarios: the demo fallback that needs no permissions.
struct DemoChatView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Scenario", selection: $model.demoScenarioID) {
                    ForEach(model.scenarios) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer()
                Button("Restart") { model.demoReset() }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.demoMessages) { message in
                            DemoMessageRow(message: message).id(message.id)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.demoVisible) {
                    if let last = model.demoMessages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(model.demoVisible)/\(model.demoScenario?.lines.count ?? 0)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Ask the voices") { model.demoAsk() }
                Button("Next message") { model.demoNext() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.demoHasNext)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 480)
        .onAppear { model.demoAppeared() }
    }
}

private struct DemoMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.isMe ? Color.accentColor : Color.gray.opacity(0.5))
                .frame(width: 32, height: 32)
                .overlay(Text(String(message.author.prefix(1))).font(.headline).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(message.author).font(.system(size: 13, weight: .bold))
                    Text(message.time ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
