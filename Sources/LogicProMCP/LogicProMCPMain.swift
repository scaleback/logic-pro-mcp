import Foundation

package enum LogicProMCPMain {
    static func defaultRunner(
        arguments: [String],
        permissionCheck: () -> PermissionChecker.PermissionStatus = PermissionChecker.check,
        // Fase 3 (tarea #26): producción real ahora instancia el canal de
        // Accessibility como el proxy sin sandbox (AXHelperProxyChannel), no
        // el AccessibilityChannel en proceso. Todo lo demás (routing, Honest
        // Contract, dispatchers) no cambia — hablan con el canal por la misma
        // interfaz Channel.execute() de siempre. Ningún test se apoya en este
        // default: los que arrancan un servidor real inyectan su propio
        // serverFactory; los que no, nunca llegan a invocar este closure.
        serverFactory: () -> any ServerStarting = { LogicProServer(axChannel: AXHelperProxyChannel()) },
        approvalStoreFactory: () -> any ManualValidationStoring = { ManualValidationStore() },
        doctorRuntime: SetupDoctor.Runtime = .production,
        lifecycleRuntime: SetupLifecycle.Runtime = .production,
        writeStdout: (String) -> Void = { message in
            FileHandle.standardOutput.write(Data(message.utf8))
        },
        writeStderr: (String) -> Void = { message in
            FileHandle.standardError.write(Data(message.utf8))
        }
    ) async -> Int {
        await MainEntrypoint.run(
            arguments: arguments,
            permissionCheck: permissionCheck,
            serverFactory: serverFactory,
            approvalStoreFactory: approvalStoreFactory,
            doctorRuntime: doctorRuntime,
            lifecycleRuntime: lifecycleRuntime,
            writeStdout: writeStdout,
            writeStderr: writeStderr
        )
    }

    package static func exitCode(
        arguments: [String],
        runner: ([String]) async -> Int = { arguments in
            await LogicProMCPMain.defaultRunner(arguments: arguments)
        }
    ) async -> Int32 {
        Int32(await runner(arguments))
    }
}
