import Foundation
import MCP
import Testing
@testable import LogicProMCP

private actor StructuredContentJSONChannel: Channel {
    nonisolated let id: ChannelID = .mcu
    private let response: String

    init(response: String) {
        self.response = response
    }

    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "structured-content-stub") }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard operation == "transport.rewind" else {
            return .error("unexpected operation: \(operation)")
        }
        return .success(response)
    }
}

@Suite(.serialized)
struct StructuredContentTests {
    @Test("tools_call_includes_structured_content_all_tools")
    func toolsCallIncludesStructuredContentAllTools() async throws {
        let server = LogicProServer()
        let handlers = await server.makeHandlers()
        let cases: [(tool: String, command: String, params: [String: Value])] = [
            ("logic_transport", "set_tempo", [:]),
            ("logic_tracks", "rename", [:]),
            ("logic_mixer", "set_volume", [:]),
            ("logic_midi", "send_note", [:]),
            ("logic_edit", "quantize", [:]),
            ("logic_navigate", "goto_bar", [:]),
            ("logic_project", "open", [:]),
            ("logic_audio", "analyze_file", [:]),
            ("logic_system", "health", [:]),
            ("logic_plugins", "set_param_verified", [
                "track": .int(0),
                "insert": .int(2),
                "plugin": .string("Gain"),
                "param": .string("gain_db"),
                "value": .double(-4.0),
                "unit": .string("dB"),
                "mode": .string("duplicate_applyback"),
                "project_expected_path": .string("/tmp/x.logicx"),
            ]),
        ]

        #expect(ServerCatalog.tools.count == 10)
        for tool in ServerCatalog.tools {
            #expect(tool.outputSchema != nil, "\(tool.name) must advertise outputSchema")
        }

        let gateHeld = VerifiedOpGate.shared.tryAcquire()
        #expect(gateHeld)
        defer { VerifiedOpGate.shared.release() }

        for item in cases {
            let result = await handlers.callTool(.init(
                name: item.tool,
                arguments: [
                    "command": .string(item.command),
                    "params": .object(item.params),
                ]
            ))
            let text = sharedToolText(result)
            let textObject = try #require(sharedJSONObject(text), "\(item.tool).\(item.command) must return JSON object text")
            let structured = try #require(result.structuredContent, "\(item.tool).\(item.command) must include structuredContent")
            let structuredData = try JSONEncoder().encode(structured)
            let structuredObject = try #require(JSONSerialization.jsonObject(with: structuredData) as? [String: Any])

            #expect(try canonicalJSONObjectData(structuredObject) == canonicalJSONObjectData(textObject))
        }
    }

    @Test("tools_call_probe_includes_structured_content", processInspectionUnavailableInSandbox)
    func toolsCallProbeIncludesStructuredContent() async throws {
        let server = LogicProServer()
        let transport = MCPProtocolProbeTransport()
        try await server.startProtocolProbe(transport: transport)
        defer { Task { await server.stopProtocolProbe() } }

        await transport.queueJSON(probeInitializeFrame(id: 1))
        _ = try await waitForProbeResponse(transport, id: 1)

        await transport.queueJSON(probeToolCallFrame(id: 2, name: "logic_system", command: "health"))
        let response = try await waitForProbeResponse(transport, id: 2)
        let result = try #require(response["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let firstContent = try #require(content.first)
        let text = try #require(firstContent["text"] as? String)
        let textObject = try #require(sharedJSONObject(text))
        let structured = try #require(result["structuredContent"] as? [String: Any])

        #expect(try canonicalJSONObjectData(structured) == canonicalJSONObjectData(textObject))
    }

    @Test("channel_result_path_dispatcher_response_includes_structured_content")
    func channelResultPathDispatcherResponseIncludesStructuredContent() async throws {
        let json = #"{"success":true,"verified":false,"state":"B","operation":"transport.rewind"}"#
        let router = ChannelRouter()
        await router.register(StructuredContentJSONChannel(response: json))

        let result = await TransportDispatcher.handle(
            command: "rewind",
            params: [:],
            router: router,
            cache: StateCache()
        )
        let textObject = try #require(sharedJSONObject(sharedToolText(result)))
        let structured = try #require(result.structuredContent)
        let structuredData = try JSONEncoder().encode(structured)
        let structuredObject = try #require(JSONSerialization.jsonObject(with: structuredData) as? [String: Any])

        #expect(try canonicalJSONObjectData(structuredObject) == canonicalJSONObjectData(textObject))
    }
}

/// #544-class: a tool that declares an `outputSchema` must ALWAYS answer with
/// `structuredContent`, including on the paths whose body is prose rather than
/// a JSON object.
///
/// Reported upstream by Edgar against v3.13.0
/// (MongLong0214/logic-pro-mcp#544): `structuredContentValue(fromToolText:)`
/// returns nil unless the text parses as a JSON object, so any handler
/// answering with a sentence, a help listing, or a bare `true`/`false` came
/// back with `structuredContent: nil` and a schema-enforcing client refused
/// the call outright (JSON-RPC -32600).
///
/// Every one of these assertions fails without `structuredContentObject`.
@Suite(.serialized)
struct OutputSchemaProseContractTests {

    /// The property, read off the registration list rather than restated: no
    /// tool may advertise an output schema it cannot honour. A newly
    /// registered tool is covered without anyone remembering to extend a list.
    @Test("every registered tool advertises an object output schema")
    func everyRegisteredToolAdvertisesObjectOutputSchema() throws {
        #expect(!ServerCatalog.tools.isEmpty)
        for tool in ServerCatalog.tools {
            let schema = try #require(tool.outputSchema, "\(tool.name) must advertise an outputSchema")
            let data = try JSONEncoder().encode(schema)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["type"] as? String == "object", "\(tool.name) schema must be an object")
        }
    }

    @Test("prose bodies carry structuredContent as {message} and leave the text byte-identical")
    func proseBodiesCarryStructuredContent() throws {
        let prose = "record_sequence: No project open"
        let result = toolTextResult(prose, isError: true)

        // The text a caller reads is unchanged — byte-for-byte.
        #expect(sharedToolText(result) == prose)

        let structured = try #require(
            result.structuredContent,
            "a prose body must still carry structuredContent"
        )
        let data = try JSONEncoder().encode(structured)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["message"] as? String == prose)
    }

    /// A bare JSON scalar is not an object either, and this one is
    /// load-bearing: `SemanticOracleTable.projectIsRunning` requires the body
    /// to be literally `true` or `false`, so the fix must add structure
    /// WITHOUT touching the text.
    @Test("project.is_running keeps its byte-exact body and still carries structuredContent")
    func projectIsRunningKeepsByteExactBody() async throws {
        for running in [true, false] {
            let result = await ProjectDispatcher.handle(
                command: "is_running",
                params: [:],
                router: ChannelRouter(),
                cache: StateCache(),
                isLogicProRunning: { running }
            )

            let text = sharedToolText(result)
            #expect(text == (running ? "true" : "false"), "oracle requires a byte-exact scalar body")

            let structured = try #require(
                result.structuredContent,
                "is_running must carry structuredContent despite its scalar body"
            )
            let data = try JSONEncoder().encode(structured)
            let object = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any],
                "structuredContent must be a JSON object to satisfy the declared schema"
            )
            #expect(object["message"] as? String == text)
        }
    }

    /// JSON-object bodies must be passed through UNWRAPPED — a fix that
    /// nested already-valid answers under `message` would break more than it
    /// repaired, since callers and the byte-comparison in
    /// `StructuredContentTests` both expect structuredContent to equal the
    /// parsed text.
    @Test("JSON object bodies are passed through, not nested under message")
    func jsonObjectBodiesArePassedThrough() throws {
        let json = #"{"success":true,"verified":false,"state":"B"}"#
        let result = toolTextResult(json)

        let structured = try #require(result.structuredContent)
        let data = try JSONEncoder().encode(structured)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["message"] == nil, "a valid object body must not be re-wrapped")
        #expect(object["state"] as? String == "B")
        #expect(try canonicalJSONObjectData(object) == canonicalJSONObjectData(#require(sharedJSONObject(json))))
    }
}
