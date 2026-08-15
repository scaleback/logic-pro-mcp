import Foundation

/// Batuta (Fase 3): the JSON-Lines wire protocol between the sandboxed main
/// process and the unsandboxed AX helper process. Shared by both sides
/// (AXHelperProxyChannel.swift here, and LogicProMCPAXHelper/main.swift) so
/// the two can never silently drift apart — one struct, one source of truth,
/// used by both a Decoder and an Encoder on each side.
package enum AXHelperProtocol {
    package struct Request: Codable, Sendable {
        package let operation: String
        package let params: [String: String]

        package init(operation: String, params: [String: String]) {
            self.operation = operation
            self.params = params
        }
    }

    package struct Response: Codable, Sendable {
        package let kind: Kind
        package let message: String

        package enum Kind: String, Codable, Sendable {
            case success
            case error
        }

        package init(kind: Kind, message: String) {
            self.kind = kind
            self.message = message
        }
    }
}
