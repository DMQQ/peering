import RemoteCore

extension AgentPermissionMode {
    /// The name `--permission-mode` and `set_permission_mode` take. Claude has no mode that never asks, so `.auto` is not offered and falls back to its default.
    public var claudeCLIName: String {
        switch self {
        case .acceptEdits: "acceptEdits"
        case .plan: "plan"
        case .manual, .auto: "default"
        }
    }
}
