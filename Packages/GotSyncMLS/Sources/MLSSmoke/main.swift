import Foundation
import GotSyncMLS

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let started = ContinuousClock.now
let client = try MLSClient(directory: directory, deviceID: Data(repeating: 1, count: 16), stateKey: InMemoryStateKeyProvider())
try await client.createGroup(id: Data(repeating: 2, count: 32))
print("MLS create identity and group: \(started.duration(to: .now))")
