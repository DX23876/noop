import Foundation
import StrandCore

extension Collector {
    /// Banks a ground-truth IMU frame in the app's raw IMU session files (`ImuSessionFileStore`), the research
    /// capture behind the Raw data collector screen. Reached through `frameTap` for every ingested frame and
    /// directly from the 5/MG live path, whose frames never reach `ingest`.
    func recordGroundTruthImu(_ frame: [UInt8]) {
        _ = ImuSessionFileStore.shared.append(deviceId: deviceId, frame: frame,
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1_000))
    }
}
