import RemoteCore

extension AgentPermissionMode {
    /// The name `--permission-mode` and `set_permission_mode` take. For Claude `.auto` is its classifier mode, where a reviewer model checks each action, not the unattended mode Codex and OpenCode mean by it.
    public var claudeCLIName: String {
        switch self {
        case .acceptEdits: "acceptEdits"
        case .plan: "plan"
        case .auto: "auto"
        case .manual: "default"
        }
    }
}
