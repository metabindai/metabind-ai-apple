import Foundation
import MetabindAssistant
import MCPAppsHost

/// probe-host — Live end-to-end smoke driver for `MetabindHostBridge`.
///
/// Constructs a `MetabindAssistant` wired to the real MCP server and the
/// real agent proxy, then exercises each bridge method a BindJS component
/// would call via `useMCPHost()`. Prints results to stdout.
///
/// This covers the slice that `BindJSTests/MCPHostBridgeIntegrationTests`
/// can't — calls that hit live network and real tools/resources.
///
/// Required env:
///   METABIND_AGENT_HOST  — e.g. https://agent-dev.metabind.ai
///   METABIND_MCP_URL     — e.g. https://mcp-dev.metabind.ai/<org>/projects/<proj>
///   METABIND_MCP_BEARER  — MCP project bearer
///   METABIND_API_KEY     — Metabind API key
///   METABIND_ORG_ID
///   METABIND_PROJECT_ID
///
/// Optional:
///   METABIND_DATA_TOOL   — data-only tool name (default: search_assets)
///   METABIND_TOOL_ARGS   — JSON object of args (default: {"query":"sofa","type":"image","limit":3})
@main
struct Probe {
    static func main() async throws {
        guard
            let agentHostStr = ProcessInfo.processInfo.environment["METABIND_AGENT_HOST"],
            let agentHost = URL(string: agentHostStr),
            let mcpURLStr = ProcessInfo.processInfo.environment["METABIND_MCP_URL"],
            let mcpURL = URL(string: mcpURLStr),
            let mcpBearer = ProcessInfo.processInfo.environment["METABIND_MCP_BEARER"],
            let apiKey = ProcessInfo.processInfo.environment["METABIND_API_KEY"],
            let orgId = ProcessInfo.processInfo.environment["METABIND_ORG_ID"],
            let projectId = ProcessInfo.processInfo.environment["METABIND_PROJECT_ID"]
        else {
            fputs("""
            Missing env. Set:
              METABIND_AGENT_HOST
              METABIND_MCP_URL
              METABIND_MCP_BEARER
              METABIND_API_KEY
              METABIND_ORG_ID
              METABIND_PROJECT_ID

            Optional:
              METABIND_DATA_TOOL  (default: product_data_search_tool)
              METABIND_TOOL_ARGS  (default: {"searchTerm":"sofa"})

            """, stderr)
            exit(2)
        }

        let toolName = ProcessInfo.processInfo.environment["METABIND_DATA_TOOL"]
            ?? "search_assets"
        let toolArgsJSON = ProcessInfo.processInfo.environment["METABIND_TOOL_ARGS"]
            ?? #"{"query":"sofa","type":"image","limit":3}"#

        let server = MCPAppsClient(
            url: mcpURL,
            headers: ["authorization": "Bearer \(mcpBearer)"]
        )
        let provider = MetabindAgentProvider(
            baseURL: agentHost,
            apiKey: apiKey,
            orgId: orgId,
            projectId: projectId
        )
        let assistant = await MetabindAssistant(
            server: server,
            provider: provider
        )
        let bridge = await assistant.hostBridge

        print("── probe-host ──")
        print("mcp:     \(mcpURL.absoluteString)")
        print("agent:   \(agentHost.absoluteString)")
        print("org:     \(orgId)")
        print("project: \(projectId)")
        print("")

        // 1. toolCall against the real MCP server (data-only tool).
        print("[1/5] toolCall \(toolName)(\(toolArgsJSON))")
        do {
            let argsDict = try JSONSerialization.jsonObject(with: Data(toolArgsJSON.utf8)) as? [String: Any] ?? [:]
            let result = try await bridge.toolCall(name: toolName, arguments: argsDict)
            let summary = summarize(result)
            print("  ← \(summary)")
        } catch {
            print("  ! error: \(error.localizedDescription)")
        }
        print("")

        // 2. sendMessage — should enqueue a new user turn on the assistant.
        print("[2/5] sendMessage('hi from probe-host')")
        let conversationCountBefore = await assistant.conversation.messages.count
        try await bridge.sendMessage("hi from probe-host")
        // send(_:) starts processing asynchronously; wait for isProcessing
        // to flip before inspecting (but cap on time).
        let started = Date()
        while await !assistant.isProcessing, Date().timeIntervalSince(started) < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let beganProcessing = await assistant.isProcessing
        print("  → isProcessing=\(beganProcessing), conversation grew from \(conversationCountBefore) to \(await assistant.conversation.messages.count)")
        // Cancel to avoid spending model time on the probe.
        await assistant.cancel()
        // Brief pause to let cancellation settle.
        try await Task.sleep(for: .milliseconds(200))
        print("")

        // 3. updateModelContext — should land in pendingContext.
        print("[3/5] updateModelContext({selectedColor: 'oat', qty: 2})")
        try await bridge.updateModelContext(["selectedColor": "oat", "qty": 2])
        let pendingSnapshot = await assistant.pendingContext
        print("  → pendingContext keys: \(pendingSnapshot.keys.sorted())")
        await assistant.clearPendingContext()
        print("")

        // 4. elicit without a handler — expect .decline.
        print("[4/5] elicit({type: 'object'}) — no handler, expect decline")
        let response = try await bridge.elicit(
            schema: ["type": "object", "properties": ["q": ["type": "string"]]],
            metadata: ["title": "Sign up"]
        )
        print("  ← action=\(response.action.rawValue) content=\(response.content.map { "\($0)" } ?? "nil")")
        print("")

        // 5. log — smoke-test the default os.Logger fallback.
        print("[5/5] log('info', 'probe-host reached end')")
        bridge.log(level: "info", message: "probe-host reached end", data: ["probe": "ok"])
        // log hops to main async — give it a tick to drain.
        try await Task.sleep(for: .milliseconds(100))
        print("  → emitted via os.Logger (subsystem: MetabindAssistant, category: Host)")
        print("")

        print("── done ──")
    }

    static func summarize(_ value: Any?) -> String {
        guard let value else { return "<nil>" }
        if let dict = value as? [String: Any] {
            let keys = dict.keys.sorted().prefix(6).joined(separator: ", ")
            let total = dict.count
            return "object with \(total) keys [\(keys)\(total > 6 ? ", …" : "")]"
        }
        if let array = value as? [Any] {
            return "array len=\(array.count)"
        }
        if let str = value as? String {
            let preview = str.count > 120 ? String(str.prefix(120)) + "…" : str
            return "string \"\(preview)\""
        }
        return "\(type(of: value)) \(value)"
    }
}
