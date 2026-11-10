import Foundation

extension HostModel {
    /// A session leaves freed heap pages behind that the allocator keeps for reuse; an idle host sat near its session
    /// peak. Waits for capture and encoding to finish tearing down, then hands those pages back to the system.
    func releaseSessionMemory() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(10)) {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }
}
