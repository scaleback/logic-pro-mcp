import Foundation
import MCP

struct EditDispatcher: OperationTraceDispatching {
    // Keeps dispatcher cases auditable against the registry so fallback cannot bypass strict validation.
    static let handledCommands: Set<String> = OperationRegistry.commands(for: .logicEdit)

    private enum EditRoute {
        case regular(String)
        case unverifiedIsError(String)
    }

    private static let routedCommands: [String: EditRoute] = [
        "undo": .regular("edit.undo"),
        "redo": .regular("edit.redo"),
        // Batuta (Fase 3): cut/delete/bounce_in_place act on "the current
        // selection" with no way for the tool layer to know what that even is
        // (a region, a MIDI note, an automation point...), so there is no
        // readback that could confirm the right thing happened — same
        // constraint documented for select_all below. Reporting these as
        // clean successes was actively misleading; unverifiedIsError makes
        // the isError:true match what verification == .none already
        // declares. See the confirmed:true gate in handle(), which is the
        // other half of this fix (destructive + zero verification needs a
        // human opt-in, not just an honest failure after the fact).
        "cut": .unverifiedIsError("edit.cut"),
        "copy": .regular("edit.copy"),
        "paste": .regular("edit.paste"),
        "delete": .unverifiedIsError("edit.delete"),
        "select_all": .unverifiedIsError("edit.select_all"),
        "split": .regular("edit.split"),
        "join": .regular("edit.join"),
        "bounce_in_place": .unverifiedIsError("edit.bounce_in_place"),
        "normalize": .regular("edit.normalize"),
        "duplicate": .regular("edit.duplicate"),
        "toggle_step_input": .regular("edit.toggle_step_input"),
    ]

    /// Batuta (Fase 3): the Phase 3 anillo rule — nothing destructive without
    /// either a readback or a human confirmation. These three have no
    /// feasible readback (see routedCommands above), so confirmation is the
    /// only guard available. Registry backs this with ConfirmationPolicy.l2
    /// on the same three ops (OperationRegistry.swift) — this set must stay
    /// in sync with that or the census test (OperationRegistryTests) catches
    /// the drift.
    private static let confirmationRequiredCommands: Set<String> = [
        "cut", "delete", "bounce_in_place",
    ]

    private static let validQuantizeGrids = [
        "1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64", "1/4T", "1/8T", "1/16T",
    ]

    static let tool = Tool(
        name: "logic_edit",
        description: """
            Editing actions in Logic Pro. \
            Commands: undo, redo, cut, copy, paste, delete, select_all, \
            split, join, quantize, bounce_in_place, normalize, duplicate, toggle_step_input. \
            Params by command: \
            quantize -> { value: String } ("1/4", "1/8", "1/16", etc.); \
            Most others -> {} (operate on current selection)
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Edit command to execute"),
                ]),
                "params": .object([
                    "type": .string("object"),
                    "description": .string("Command-specific parameters"),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "undo", "redo", "cut", "copy", "paste", "delete", "select_all", "split", "join",
             "bounce_in_place", "normalize", "duplicate", "toggle_step_input":
            guard let route = routedCommands[command] else {
                return toolTextResult("Internal edit route missing for \(command)", isError: true)
            }
            if confirmationRequiredCommands.contains(command) {
                switch strictBoolParam(params, "confirmed") {
                case .missing, .value(false):
                    let level = DestructivePolicy.promptLabel(
                        of: OperationRegistry.spec(
                            tool: ToolID.logicEdit.rawValue,
                            command: command
                        )?.confirmation ?? .l2
                    ) ?? "L2"
                    let response = """
                        {"confirmation_required":true,"command":"\(command)","level":"\(level)","message":"\(command) acts on Logic Pro's current selection, which this server cannot enumerate or verify afterward. Re-call with confirmed:true to proceed anyway.","confirm_command":"logic_edit(\\"\(command)\\", {\\"confirmed\\": true})"}
                        """
                    return toolTextResult(response)
                case .value(true):
                    break
                case .invalid(let hint):
                    return toolInvalidParamsResult("\(command) \(hint)")
                }
            }
            let traceID = await startTraceIfEnabled(command: command)
            let result = await routeEditCommand(route, router: router, traceID: traceID)
            return await finalizeTrace(result, traceID: traceID)

        case "quantize":
            guard params["value"] != nil || params["grid"] != nil else {
                return toolInvalidParamsResult(
                    "quantize requires explicit 'value' or 'grid'"
                )
            }
            let value = stringParam(params, "value", "grid", default: "1/16")
            guard validQuantizeGrids.contains(value) else {
                return toolTextResult(
                    "quantize 'value' must be one of \(validQuantizeGrids.joined(separator: ", ")) (got '\(value)')",
                    isError: true
                )
            }
            let traceID = await startTraceIfEnabled(command: command)
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(
                    operation: "edit.quantize",
                    params: ["value": value]
                )
            }
            return await finalizeTrace(
                toolTextResultTreatingUnverifiedAsError(result),
                traceID: traceID
            )

        default:
            return Self.unhandledCommandResult(command, label: "edit")
        }
    }

    private static func routeEditCommand(
        _ route: EditRoute,
        router: ChannelRouter,
        traceID: TraceID?
    ) async -> CallTool.Result {
        switch route {
        case .regular(let operation):
            return await withWriteBoundaryArmed(traceID) {
                await routedTextResult(router, operation: operation)
            }
        case .unverifiedIsError(let operation):
            let result = await withWriteBoundaryArmed(traceID) {
                await router.route(operation: operation)
            }
            return toolTextResultTreatingUnverifiedAsError(result)
        }
    }
}
