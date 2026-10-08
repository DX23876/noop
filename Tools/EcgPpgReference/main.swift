import Foundation

// Optional HR-only control using the repository's ACTUAL PpgHr implementation.
// Passing R20 with an explicit sample rate is an offline experiment. The app only
// calls this estimator for v26; this program must never be described as its R20 path.
struct Input: Decodable {
    let sampleRate: Int
    let samples: [Int]
}
struct Output: Encodable {
    let integerLag: [PpgHrSample]
    let interpolatedLag: [PpgHrSample]
}
do {
    let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
    guard [24, 25, 50].contains(input.sampleRate),
          input.samples.count >= input.sampleRate * 3,
          input.samples.count % input.sampleRate == 0 else {
        throw NSError(domain: "EcgPpgReference", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected complete seconds at 24, 25 or 50 Hz"])
    }
    let records = stride(from: 0, to: input.samples.count, by: input.sampleRate).map { offset in
        (ts: offset / input.sampleRate,
         samples: Array(input.samples[offset..<(offset + input.sampleRate)]))
    }
    let result = Output(
        integerLag: PpgHr.derivePpgHr(records: records, fs: input.sampleRate),
        interpolatedLag: PpgHr.derivePpgHr(records: records, fs: input.sampleRate, subLagInterp: true))
    FileHandle.standardOutput.write(try JSONEncoder().encode(result))
} catch {
    FileHandle.standardError.write(Data("Invalid HR-control input: \(error.localizedDescription)\n".utf8))
    exit(1)
}
