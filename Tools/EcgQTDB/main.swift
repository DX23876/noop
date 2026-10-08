import Foundation
// For each QTDB window file: resample to 100 Hz with the app's own resampler, analyse, print one line.
let dir = CommandLine.arguments[1]
let files = try! FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".txt") }.sorted()
func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
print("file,hr,pr,qrs,qt,qtcf,beats,averaged,corr")
for name in files {
    let text = try! String(contentsOfFile: dir + "/" + name, encoding: .utf8).split(separator: "\n")
    let fs = Double(text[0])!
    let raw = text[1].split(separator: ",").map { Double($0)! }
    let samples = EcgResample.toHundredHertz(raw, rate: fs)
    guard let r = EcgAnalysis.analyze(samples) else { print("\(name),,,,,,,,"); continue }
    print("\(name),\(f(r.meanHeartRate)),\(f(r.prMs)),\(f(r.qrsMs)),\(f(r.qtMs)),\(f(r.qtcFridericiaMs)),\(r.beatsDetected),\(r.beatsAveraged),\(f(r.templateCorrelation))")
}
