import Foundation
import MetabindAssistant
import MCPAppsHost

@main
struct Probe {
    static func main() async throws {
        guard let hostString = ProcessInfo.processInfo.environment["METABIND_AGENT_HOST"],
              let host = URL(string: hostString),
              let apiKey = ProcessInfo.processInfo.environment["METABIND_API_KEY"],
              let orgId = ProcessInfo.processInfo.environment["METABIND_ORG_ID"],
              let projectId = ProcessInfo.processInfo.environment["METABIND_PROJECT_ID"] else {
            fputs("""
            Missing env. Set:
              METABIND_AGENT_HOST   (e.g. https://agent-dev.metabind.ai)
              METABIND_API_KEY
              METABIND_ORG_ID
              METABIND_PROJECT_ID
              METABIND_PROMPT       (optional; defaults to a basic smoke prompt)

            """, stderr)
            exit(2)
        }

        let prompt = ProcessInfo.processInfo.environment["METABIND_PROMPT"]
            ?? "Say exactly: pong. No other words."

        let provider = MetabindAgentProvider(
            baseURL: host,
            apiKey: apiKey,
            orgId: orgId,
            projectId: projectId
        )

        print("── Turn 1 ──")
        print("host: \(host.absoluteString)")
        print("orgId: \(orgId)")
        print("projectId: \(projectId)")
        print("prompt: \(prompt)")
        print("")

        let start = Date()
        var eventCount = 0
        var textAccumulator = ""

        let stream = provider.stream(
            messages: [.user(prompt)],
            tools: nil,
            systemPrompt: nil
        )

        for await event in stream {
            eventCount += 1
            let t = String(format: "%+.2fs", Date().timeIntervalSince(start))
            switch event {
            case .textDelta(let text):
                textAccumulator += text
                print("[\(t)] text_delta  \(truncated(text, 80))")
            case .toolCallStart(let index, let id, let name):
                print("[\(t)] tool_start  index=\(index) id=\(id) name=\(name)")
            case .toolCallArgumentDelta(let json):
                print("[\(t)] tool_arg    \(truncated(json, 120))")
            case .contentBlockStop(let index):
                print("[\(t)] block_stop  index=\(index)")
            case .toolResult(let id, let content, let structured, let isError):
                print("[\(t)] tool_result id=\(id) isError=\(isError)")
                print("            content: \(truncated(content, 160))")
                if let structured {
                    print("            structuredContent: \(truncated(String(describing: structured), 200))")
                } else {
                    print("            structuredContent: <nil>")
                }
            case .providerSwitch(let from, let to, let reason):
                print("[\(t)] switch      \(from) → \(to) (\(reason))")
            case .done(let reason):
                print("[\(t)] done        \(reason)")
            case .error(let error):
                print("[\(t)] ERROR       \(error)")
            }
        }

        print("")
        print("── Summary ──")
        print("events: \(eventCount)")
        print("duration: \(String(format: "%.2fs", Date().timeIntervalSince(start)))")
        print("final text: \(textAccumulator.isEmpty ? "<none>" : "\"\(textAccumulator)\"")")
        if let convId = await provider.currentConversationId {
            print("conversationId: \(convId)")
        }

        // Turn 2 — verify resume semantics.
        if let followUp = ProcessInfo.processInfo.environment["METABIND_FOLLOWUP"], !followUp.isEmpty {
            print("")
            print("── Turn 2 (follow-up, same conversation) ──")
            print("prompt: \(followUp)")

            let start2 = Date()
            textAccumulator = ""
            let stream2 = provider.stream(
                messages: [.user(followUp)],
                tools: nil,
                systemPrompt: nil
            )
            for await event in stream2 {
                let t = String(format: "%+.2fs", Date().timeIntervalSince(start2))
                switch event {
                case .textDelta(let text):
                    textAccumulator += text
                    print("[\(t)] text_delta  \(truncated(text, 80))")
                case .done(let reason):
                    print("[\(t)] done        \(reason)")
                case .error(let error):
                    print("[\(t)] ERROR       \(error)")
                default:
                    print("[\(t)] \(event)")
                }
            }
            print("final text: \"\(textAccumulator)\"")
        }
    }

    static func truncated(_ s: String, _ n: Int) -> String {
        if s.count <= n { return s }
        return String(s.prefix(n)) + "…"
    }
}
