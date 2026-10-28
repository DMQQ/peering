import Foundation

/// The phone's own queue for a Mac too old to hold one (see ``ServerHello/supportsAgentQueue``), kept per Mac so it survives the app being closed. A Mac that holds the queue never reads this.
public enum AgentQueueStore {
    private static func key(_ hostKey: String) -> String { "Peering.agentQueues.\(hostKey)" }

    public static func save(_ queues: [UUID: AgentPromptQueue], hostKey: String, defaults: UserDefaults = .standard) {
        let waiting = queues.filter { !$0.value.prompts.isEmpty }
        guard !waiting.isEmpty else {
            defaults.removeObject(forKey: key(hostKey))
            return
        }
        let plain = Dictionary(uniqueKeysWithValues: waiting.map { ($0.key.uuidString, $0.value.prompts) })
        defaults.set(try? JSONEncoder().encode(plain), forKey: key(hostKey))
    }

    public static func load(hostKey: String, defaults: UserDefaults = .standard) -> [UUID: AgentPromptQueue] {
        guard let data = defaults.data(forKey: key(hostKey)),
              let plain = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        var queues: [UUID: AgentPromptQueue] = [:]
        for (id, prompts) in plain {
            guard let id = UUID(uuidString: id), !prompts.isEmpty else { continue }
            queues[id] = AgentPromptQueue(prompts: prompts)
        }
        return queues
    }
}
