import Testing
import Foundation
@testable import MetabindAssistant
@testable import MCPAppsHost

@Suite("MetabindAgentProvider", .serialized)
struct MetabindAgentProviderTests {

    // MARK: - Helpers

    private static let baseURL = URL(string: "https://agent-test.example.com")!

    private func makeProvider(
        sse: String,
        status: Int = 200,
        conversationId: String? = nil
    ) -> MetabindAgentProvider {
        let session = MockURLProtocol.install { _ in .sse(sse, status: status) }
        return MetabindAgentProvider(
            baseURL: Self.baseURL,
            apiKey: "test-api-key",
            orgId: "org_abc",
            projectId: "proj_xyz",
            conversationId: conversationId,
            urlSession: session
        )
    }

    private func makeProvider(
        response: MockURLProtocol.Response,
        conversationId: String? = nil
    ) -> MetabindAgentProvider {
        let session = MockURLProtocol.install { _ in response }
        return MetabindAgentProvider(
            baseURL: Self.baseURL,
            apiKey: "test-api-key",
            orgId: "org_abc",
            projectId: "proj_xyz",
            conversationId: conversationId,
            urlSession: session
        )
    }

    private func collect(_ stream: AsyncStream<LLMEvent>) async -> [LLMEvent] {
        var events: [LLMEvent] = []
        for await e in stream { events.append(e) }
        return events
    }

    // MARK: - Request shape

    @Test func buildsExpectedRequest() async throws {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_start
        data: {"conversationId":"conv-1"}

        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let provider = makeProvider(sse: sse)

        _ = await collect(provider.stream(
            messages: [.user("hi")], tools: nil, systemPrompt: nil
        ))

        let request = try #require(MockURLProtocol.capturedRequest())
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://agent-test.example.com/org_abc/proj_xyz/chat")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-api-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        let body = try #require(MockURLProtocol.capturedBody())
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["stream"] as? Bool == true)
        #expect(json["conversationId"] == nil) // no conversationId on first call
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "hi")
    }

    // MARK: - Event translation

    @Test func textDeltaEmitsTextDelta() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_start
        data: {"conversationId":"conv-1"}

        event: text_delta
        data: {"text":"Hello, "}

        event: text_delta
        data: {"text":"world"}

        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("hi")], tools: nil, systemPrompt: nil
        ))

        let texts = events.compactMap { event -> String? in
            if case .textDelta(let t) = event { return t }
            return nil
        }
        #expect(texts == ["Hello, ", "world"])
    }

    @Test func toolUseSynthesizesStartArgDeltaAndStop() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_start
        data: {"conversationId":"conv-1"}

        event: tool_use
        data: {"id":"toolu_1","name":"getWeather","input":{"city":"NYC"}}

        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("weather?")], tools: nil, systemPrompt: nil
        ))

        // Expect: toolCallStart, toolCallArgumentDelta, contentBlockStop, done
        #expect(events.count == 4)
        if case .toolCallStart(let index, let id, let name) = events[0] {
            #expect(index == 0)
            #expect(id == "toolu_1")
            #expect(name == "getWeather")
        } else {
            Issue.record("expected .toolCallStart, got \(events[0])")
        }
        if case .toolCallArgumentDelta(let json) = events[1] {
            let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
            #expect(parsed == ["city": "NYC"])
        } else {
            Issue.record("expected .toolCallArgumentDelta, got \(events[1])")
        }
        if case .contentBlockStop(let index) = events[2] {
            #expect(index == 0)
        } else {
            Issue.record("expected .contentBlockStop, got \(events[2])")
        }
    }

    @Test func toolResultRoundTripsStructuredContent() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_start
        data: {"conversationId":"conv-1"}

        event: tool_result
        data: {"toolUseId":"toolu_1","content":[{"type":"text","text":"72°F sunny"}],"structuredContent":{"temp":72,"condition":"sunny"}}

        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("weather?")], tools: nil, systemPrompt: nil
        ))

        let result = try? events.first(where: {
            if case .toolResult = $0 { return true }
            return false
        })
        try? #require(result != nil)

        if case .toolResult(let id, let content, let structured, let isError) = events.first(where: {
            if case .toolResult = $0 { return true }
            return false
        }) ?? .error(URLError(.unknown)) {
            #expect(id == "toolu_1")
            #expect(content == "72°F sunny")
            #expect(isError == false)
            // structuredContent preserved verbatim
            #expect(structured == .object(["temp": .number(72), "condition": .string("sunny")]))
        } else {
            Issue.record("expected .toolResult")
        }
    }

    @Test func toolResultWithIsErrorTrue() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: tool_result
        data: {"toolUseId":"toolu_1","content":[{"type":"text","text":"boom"}],"isError":true}

        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))

        if case .toolResult(_, let content, _, let isError) = events.first(where: {
            if case .toolResult = $0 { return true }
            return false
        }) ?? .error(URLError(.unknown)) {
            #expect(content == "boom")
            #expect(isError == true)
        } else {
            Issue.record("expected .toolResult")
        }
    }

    @Test func providerSwitchEmitsEvent() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: provider_switch
        data: {"from":"anthropic","to":"openai","reason":"rate_limit","attempt":2}

        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))

        if case .providerSwitch(let from, let to, let reason) = events[0] {
            #expect(from == "anthropic")
            #expect(to == "openai")
            #expect(reason == "rate_limit")
        } else {
            Issue.record("expected .providerSwitch, got \(events[0])")
        }
    }

    // MARK: - Stream termination

    @Test func messageStopEndTurnEndsStream() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))
        #expect(events.count == 1)
        if case .done(let r) = events[0] { #expect(r == .endTurn) } else { Issue.record() }
    }

    @Test func messageStopMaxTokensEndsStream() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_stop
        data: {"stopReason":"max_tokens"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))
        if case .done(let r) = events[0] { #expect(r == .maxTokens) } else { Issue.record() }
    }

    @Test func messageStopToolUseDoesNotEndStream() async {
        defer { MockURLProtocol.uninstall() }
        // tool_use stop mid-stream, followed by another turn and final end_turn.
        let sse = """
        event: text_delta
        data: {"text":"Let me check."}

        event: tool_use
        data: {"id":"toolu_1","name":"look","input":{}}

        event: message_stop
        data: {"stopReason":"tool_use"}

        event: tool_result
        data: {"toolUseId":"toolu_1","content":[{"type":"text","text":"ok"}]}

        event: text_delta
        data: {"text":"Done."}

        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))

        // Should see text, tool_use synthetics, tool_result, more text, final done.
        let doneEvents = events.filter {
            if case .done = $0 { return true }
            return false
        }
        #expect(doneEvents.count == 1, "stream should only emit .done once (the terminal end_turn)")
        if case .done(let r) = doneEvents.first ?? .error(URLError(.unknown)) {
            #expect(r == .endTurn)
        }
        // Everything through the final text_delta must have been seen.
        let texts = events.compactMap {
            if case .textDelta(let t) = $0 { return t }
            return nil as String?
        }
        #expect(texts == ["Let me check.", "Done."])
    }

    @Test func unknownStopReasonMapsToUnknown() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_stop
        data: {"stopReason":"refusal"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))
        if case .done(let r) = events[0] {
            #expect(r == .unknown("refusal"))
        } else {
            Issue.record()
        }
    }

    @Test func errorEventEndsStream() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: error
        data: {"code":"provider_error","message":"upstream went boom"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))
        #expect(events.count == 1)
        if case .error(let err) = events[0],
           let agentError = err as? AgentError,
           case .serverError(let code, let message) = agentError {
            #expect(code == "provider_error")
            #expect(message == "upstream went boom")
        } else {
            Issue.record("expected .error(AgentError.serverError), got \(events[0])")
        }
    }

    // MARK: - Framing

    @Test func heartbeatLinesAreSkipped() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        :heartbeat

        event: text_delta
        data: {"text":"hi"}

        :heartbeat

        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))
        let texts = events.compactMap {
            if case .textDelta(let t) = $0 { return t }
            return nil as String?
        }
        #expect(texts == ["hi"])
    }

    @Test func malformedFrameDataIsDropped() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: text_delta
        data: not-valid-json

        event: text_delta
        data: {"text":"ok"}

        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let events = await collect(makeProvider(sse: sse).stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))
        let texts = events.compactMap {
            if case .textDelta(let t) = $0 { return t }
            return nil as String?
        }
        // malformed frame is silently dropped; only the valid text_delta comes through.
        #expect(texts == ["ok"])
    }

    // MARK: - Conversation id tracking

    @Test func captureConversationIdFromMessageStart() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_start
        data: {"conversationId":"conv-assigned"}

        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let provider = makeProvider(sse: sse)
        _ = await collect(provider.stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))
        let id = await provider.currentConversationId
        #expect(id == "conv-assigned")
    }

    @Test func resumedConversationSendsOnlyLatestUserMessage() async throws {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let provider = makeProvider(sse: sse, conversationId: "conv-existing")

        let history: [LLMMessage] = [
            .user("first"),
            .assistant(text: "first reply", toolCalls: []),
            .user("second"),
            .assistant(text: "second reply", toolCalls: []),
            .user("third"), // only this should be sent
        ]

        _ = await collect(provider.stream(
            messages: history, tools: nil, systemPrompt: nil
        ))

        let body = try #require(MockURLProtocol.capturedBody())
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["conversationId"] as? String == "conv-existing")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1, "resumed conversations only send the newest user turn")
        #expect(messages[0]["content"] as? String == "third")
    }

    @Test func freshConversationSendsFullHistory() async throws {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let provider = makeProvider(sse: sse)

        let history: [LLMMessage] = [
            .user("hello"),
            .assistant(text: "hi", toolCalls: []),
            .user("continue"),
        ]

        _ = await collect(provider.stream(
            messages: history, tools: nil, systemPrompt: nil
        ))

        let body = try #require(MockURLProtocol.capturedBody())
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["conversationId"] == nil)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
    }

    /// The agent service rejects client-supplied tool protocol blocks with
    /// `bad_request` — a fresh-conversation replay must strip them. (A reset()
    /// racing the end of a streaming turn can orphan an assistant turn with
    /// tool calls into a cleared history; that history must still be sendable.)
    @Test func freshConversationStripsToolProtocolBlocks() async throws {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let provider = makeProvider(sse: sse)

        let history: [LLMMessage] = [
            .user("what's my net worth?"),
            .assistant(text: "Here you go.", toolCalls: [
                LLMToolCall(id: "toolu_1", name: "get_net_worth", arguments: .object([:])),
            ]),
            .toolResults([LLMToolResult(toolCallId: "toolu_1", content: "{}")]),
            .assistant(text: nil, toolCalls: [
                LLMToolCall(id: "toolu_2", name: "net_worth_trend", arguments: .object([:])),
            ]), // tool-only turn: dropped entirely
            .user("show me a graph"),
        ]

        _ = await collect(provider.stream(
            messages: history, tools: nil, systemPrompt: nil
        ))

        let body = try #require(MockURLProtocol.capturedBody())
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 3, "user, text-only assistant, user")

        let serialized = String(data: body, encoding: .utf8) ?? ""
        #expect(!serialized.contains("tool_use"))
        #expect(!serialized.contains("tool_result"))

        let assistant = try #require(
            messages.first(where: { $0["role"] as? String == "assistant" })
        )
        let blocks = try #require(assistant["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "text")
        #expect(blocks[0]["text"] as? String == "Here you go.")
    }

    @Test func resetConversationClearsId() async {
        defer { MockURLProtocol.uninstall() }
        let sse = """
        event: message_stop
        data: {"stopReason":"end_turn"}


        """
        let provider = makeProvider(sse: sse, conversationId: "conv-old")
        await provider.resetConversation()
        let id = await provider.currentConversationId
        #expect(id == nil)
    }

    // MARK: - HTTP errors

    @Test func nonOKStatusYieldsServerError() async {
        defer { MockURLProtocol.uninstall() }
        let body = """
        {"error":"rate_limit_exceeded","message":"Rate limit of 1000 requests/hour exceeded for project"}
        """
        let provider = makeProvider(response: .json(body, status: 429))
        let events = await collect(provider.stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))

        let errors = events.compactMap { event -> AgentError? in
            if case .error(let e) = event, let a = e as? AgentError { return a }
            return nil
        }
        #expect(errors.count == 1)
        if case .serverError(let code, let message) = errors.first {
            #expect(code == "rate_limit_exceeded")
            #expect(message.contains("1000 requests/hour"))
        } else {
            Issue.record("expected serverError, got \(String(describing: errors.first))")
        }
    }

    @Test func unauthorizedMapsToServerError() async {
        defer { MockURLProtocol.uninstall() }
        let body = #"{"error":"unauthorized","message":"Missing or invalid Authorization header"}"#
        let provider = makeProvider(response: .json(body, status: 401))
        let events = await collect(provider.stream(
            messages: [.user("x")], tools: nil, systemPrompt: nil
        ))
        if case .error(let err) = events.first ?? .textDelta(""),
           let a = err as? AgentError,
           case .serverError(let code, _) = a {
            #expect(code == "unauthorized")
        } else {
            Issue.record()
        }
    }

    // MARK: - Runtime characteristics

    @Test func runsToolsRemotelyIsTrue() {
        let provider = MetabindAgentProvider(
            baseURL: Self.baseURL,
            apiKey: "k",
            orgId: "o",
            projectId: "p"
        )
        #expect(provider.runsToolsRemotely)
    }

}
