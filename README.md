# Metabind AI for Apple

Embed a Metabind AI assistant in your iOS, macOS, or visionOS app — one that calls real tools and renders real interactive UI as native SwiftUI, governed by the same MCP App you publish to Claude, ChatGPT, and every other MCP host.

This is the Apple side of Metabind's [Assistant SDK](https://metabind.ai). A single MCP App definition powers two surfaces — a hosted MCP server discoverable by every AI host, and a drop-in native assistant inside your own app. This package handles the second.

## What's in the package

Two libraries. Most apps want the first.

| Library | Purpose |
|---|---|
| `MetabindAssistant` | High-level conversational wrapper. Drop in `MetabindAssistantView` and you have a working assistant — LLM, MCP tool execution, and interactive rendering, wired together. Two provider options: the Metabind Agent proxy (no provider keys in your binary) or BYOK Anthropic. |
| `MCPAppsHost` | Low-level building blocks. `MCPAppsClient`, `MCPAppSession`, `MCPAppView` — for rendering a single tool result without the conversational layer. |

Tool returns aren't JSON dumps. When an MCP App returns a `ui` resource, this SDK fetches the BindJS bundle and renders it as native SwiftUI — the same UI a user would see in Claude or ChatGPT, running natively inside your app.

Format negotiation is automatic. On the MCP `initialize` handshake the client advertises the mimetypes its registered `ContentResolver`s support — `application/vnd.bindjs+json` for native rendering, `text/html;profile=mcp-app` as a fallback — via the `io.modelcontextprotocol/ui` capability extension. The server picks the right bundle format per call; you don't set `Accept` headers by hand. Register a custom resolver and its mimetypes are picked up on the next `initialize`.

## Requirements

- Swift 5.11+
- iOS 17 / macOS 14 / visionOS 1
- An MCP server that returns `ui` resources — typically a [Metabind](https://metabind.ai) project

## Install

```swift
.package(url: "https://github.com/metabindai/metabind-ai-apple.git", from: "0.1.0"),
```

Add the products you need:

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "MetabindAssistant", package: "metabind-ai-apple"),
    // Or, for low-level rendering only:
    .product(name: "MCPAppsHost", package: "metabind-ai-apple"),
])
```

## Quick start — Agent proxy

`MetabindAgentProvider` routes the conversation through `agent.metabind.ai`. The proxy holds your LLM provider credentials server-side, runs the tool-use loop, and streams normalized events back. Your app ships zero Anthropic or OpenAI keys.

```swift
import SwiftUI
import MetabindAssistant

struct ContentView: View {
    @State private var assistant = MetabindAssistant(
        serverURL: URL(string: "https://mcp.metabind.ai/<org>/projects/<project>")!,
        serverHeaders: ["authorization": "Bearer \(metabindApiKey)"],
        provider: MetabindAgentProvider(
            apiKey: metabindApiKey,
            orgId: "<org>",
            projectId: "<project>"
        )
    )

    var body: some View {
        MetabindAssistantView(assistant: assistant)
    }
}
```

One Metabind API key authenticates the MCP server *and* the agent proxy. Create one in MCP App Studio or with `metabind api-key create`.

`MetabindAssistant` is `@Observable` — `conversation`, `isProcessing`, `tools`, and `pendingContext` are all observable, so you can build entirely custom UIs around it instead of using `MetabindAssistantView`.

## Quick start — Anthropic BYOK

Run the tool-use loop client-side against your own Anthropic key:

```swift
@State private var assistant = MetabindAssistant(
    serverURL: URL(string: "https://mcp.metabind.ai/<org>/projects/<project>")!,
    serverHeaders: ["authorization": "Bearer \(mcpBearer)"],
    provider: AnthropicProvider(apiKey: anthropicKey)
)
```

Same view, same observable surface — different conversation engine.

## Quick start — MCPAppsHost (low level)

Render a single tool result without the conversational wrapper:

```swift
import SwiftUI
import MCPAppsHost

struct ContentView: View {
    let client = MCPAppsClient(
        url: URL(string: "https://your-mcp-server.example.com")!,
        headers: ["authorization": "Bearer \(token)"]
    )

    @State private var session: MCPAppSession?

    var body: some View {
        VStack {
            Button("Launch tool") {
                let call = SimpleMCPToolCall(
                    id: UUID().uuidString,
                    name: "create_promotion",
                    arguments: .object([:])
                )
                session = MCPAppSession(toolCall: call, server: client)
            }
            if let session {
                MCPAppView(session: session)
            }
        }
    }
}
```

## useMCPHost — components talking back to your app

BindJS components rendered inside a tool result can reach host capabilities via `useMCPHost()`:

```js
// inside a BindJS component
const host = useMCPHost()
if (host) {
    const { products } = await host.toolCall('search_products', { query })
    await host.updateModelContext({ selectedProduct: products[0] })
    await host.sendMessage('Tell me more about this one')
    const answer = await host.elicit(
        { type: 'object', properties: { email: { type: 'string' } } },
        { title: 'Sign up for updates' }
    )
}
```

When you use `MetabindAssistant`, `assistant.hostBridge` is pre-wired so components automatically see:

- `toolCall(name, args)` — executes via the MCP server, returns unwrapped structured data.
- `sendMessage(text)` — injects a new user turn into the conversation.
- `updateModelContext(dict)` — buffers structured context as a `<context>{…}</context>` prefix on the next user turn. The user's visible chat bubble stays clean.
- `log(level, message, data)` — routed through `os.Logger`, subsystem `MetabindAssistant.Host`.

`MetabindAssistantView` additionally wires:

- `openLink(url)` — to SwiftUI's `@Environment(\.openURL)`.

Your app fills in the rest by setting handlers on `assistant.hostBridge.handlers`:

```swift
.task {
    assistant.hostBridge.handlers.onElicit = { schema, metadata in
        // present a SwiftUI sheet derived from `schema`
        return ElicitationResponse(action: .accept, content: [...])
    }
    assistant.hostBridge.handlers.onDisplayMode = { requested in
        return .fullscreen
    }
}
```

For apps using `MCPAppView` standalone — without the assistant — build a bridge directly and inject it:

```swift
MCPAppView(session: session)
    .mcpHostBridge(myBridge)
```

## Logging

Every layer logs to `os.Logger`:

| Subsystem | Category | Contents |
|---|---|---|
| `MetabindAssistant` | `Assistant` | Conversation lifecycle, tool discovery, loop iterations |
| `MetabindAssistant` | `AgentProxy` | SSE events from the Metabind agent service |
| `MetabindAssistant` | `Anthropic` | Anthropic BYOK provider stream |
| `MetabindAssistant` | `Host` | Component-originated host calls (`useMCPHost`) |
| `MCPAppsHost` | `MCPAppSession` | Session phase transitions, resource fetching |
| `MCPAppsHost` | `MCPAppsClient` | MCP JSON-RPC requests and responses |
| `MCPAppsHost` | `MCPAppContent` | Per-render BindJS argument keys |
| `BindJS` | `Runtime` | JS exceptions and `console.log` output from components |

Tail them in Console or with:

```bash
log show --info --debug --last 5m \
  --predicate 'subsystem BEGINSWITH "MetabindAssistant" OR subsystem == "MCPAppsHost" OR subsystem == "BindJS"'
```

## Example app

A runnable showcase lives in its own repo:

**[metabind-assistant-demo-apple](https://github.com/metabindai/metabind-assistant-demo-apple)** — macOS / iOS / visionOS chat app wired to the Metabind Agent proxy, rendering real interactive product components.

```sh
git clone https://github.com/metabindai/metabind-assistant-demo-apple
cd metabind-assistant-demo-apple
open MetabindAssistantDemo.xcodeproj
```

## License

Copyright © 2026 Yap Studios LLC. All rights reserved. See [`LICENSE`](LICENSE).
