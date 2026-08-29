import Foundation
import MCP

func toolTextContent(_ text: String) -> Tool.Content {
    .text(text: text, annotations: nil, _meta: nil)
}

func toolTextResult(_ text: String, isError: Bool = false) -> CallTool.Result {
    CallTool.Result(
        content: [toolTextContent(text)],
        structuredContent: structuredContentObject(fromToolText: text),
        isError: isError
    )
}

func toolTextResult(_ result: ChannelResult) -> CallTool.Result {
    toolTextResult(result.message, isError: !result.isSuccess)
}

func toolStateCResult(
    _ error: HonestContract.FailureError,
    hint: String? = nil,
    extras: [String: Any] = [:]
) -> CallTool.Result {
    toolTextResult(
        HonestContract.encodeStateC(error: error, hint: hint, extras: extras),
        isError: true
    )
}

func toolInvalidParamsResult(_ hint: String, extras: [String: Any] = [:]) -> CallTool.Result {
    toolStateCResult(.invalidParams, hint: hint, extras: extras)
}

/// #202: a command token the dispatcher recognises but that is deliberately not
/// part of the production MCP contract. Returns a single, machine-classifiable
/// shape — `error:"command_not_exposed"` + `not_exposed:true` + `supported:false`
/// — so a complete-surface harness can mark it expected rather than a
/// malfunction. The hint keeps the canonical "not exposed in the production MCP
/// contract" phrase (the workflow census uses it to detect stubs); `reason`
/// carries any operation-specific detail.
func notExposedCommandResult(operation: String, reason: String? = nil) -> CallTool.Result {
    let detail = reason.map { " — \($0)" } ?? ""
    return toolStateCResult(
        .commandNotExposed,
        hint: "\(operation) is not exposed in the production MCP contract\(detail)",
        extras: [
            "operation": operation,
            "not_exposed": true,
            "supported": false,
        ]
    )
}

func commandParamsToolSchema(commandDescription: String) -> Value {
    .object([
        "type": .string("object"),
        "properties": .object([
            "command": .object(["type": .string("string"), "description": .string(commandDescription)]),
            "params": .object(["type": .string("object"), "description": .string("Command-specific parameters")]),
        ]),
        "required": .array([.string("command")]),
    ])
}

func commandTool(name: String, description: String, commandDescription: String) -> Tool {
    Tool(
        name: name,
        description: description,
        inputSchema: commandParamsToolSchema(commandDescription: commandDescription)
    )
}

func structuredContentValue(fromToolText text: String) -> Value? {
    let data = Data(text.utf8)
    guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
        return nil
    }
    return try? JSONDecoder().decode(Value.self, from: data)
}

/// `structuredContent` for a tool response, guaranteed to be a JSON OBJECT.
///
/// Every tool this server registers declares an `outputSchema` of type
/// `object` (see `ServerCatalog.tools`). MCP requires a tool that advertises
/// an output schema to answer with `structuredContent` conforming to it, so
/// a response whose body is not a JSON object — a prose error sentence, a
/// help listing, a bare `true`/`false` — used to come back with
/// `structuredContent: nil` and be refused outright by a schema-enforcing
/// client (JSON-RPC -32600). Reported upstream by Edgar against v3.13.0 as
/// MongLong0214/logic-pro-mcp#544.
///
/// Prose is therefore carried as `{"message": …}` rather than dropped. The
/// `content` text is left BYTE-IDENTICAL: callers that read the text see no
/// change, and byte-exact response oracles keep passing — notably
/// `SemanticOracleTable.projectIsRunning`, which requires the body to be
/// literally `true` or `false`.
///
/// Returns `Value?` although it never yields nil: `CallTool.Result`'s
/// non-optional `structuredContent` overload is throwing, and an Optional
/// selects the plain one. The guarantee callers rely on is the return VALUE
/// always being `.object`, not its static optionality.
func structuredContentObject(fromToolText text: String) -> Value? {
    structuredContentValue(fromToolText: text) ?? .object(["message": .string(text)])
}

func genericObjectOutputSchema() -> Value {
    .object([
        "type": .string("object"),
        "additionalProperties": .bool(true),
    ])
}

func honestContractOutputSchema() -> Value {
    .object([
        "type": .string("object"),
        "description": .string("Mutating commands return the Honest Contract envelope (success/verified/state, additional operation-specific keys); read-only commands return command-specific JSON objects."),
        "properties": .object([
            "success": .object(["type": .string("boolean")]),
            "verified": .object(["type": .string("boolean")]),
            "state": .object(["type": .string("string")]),
        ]),
        "additionalProperties": .bool(true),
    ])
}

func toolWithOutputSchema(_ tool: Tool, outputSchema: Value) -> Tool {
    Tool(
        name: tool.name,
        title: tool.title,
        description: tool.description,
        inputSchema: tool.inputSchema,
        annotations: tool.annotations,
        outputSchema: outputSchema,
        icons: tool.icons,
        _meta: tool._meta
    )
}
