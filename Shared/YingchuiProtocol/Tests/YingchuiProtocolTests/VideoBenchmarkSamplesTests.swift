import Testing
@testable import YingchuiProtocol

@Test func benchmarkSamplesKeepUnknownAndRejectInvalidValues() {
    var samples = VideoBenchmarkSamples()
    #expect(samples.percentile(0.5) == nil)
    samples.record(milliseconds: .nan)
    samples.record(milliseconds: -1)
    samples.record(from: 2, to: 1)
    #expect(samples.milliseconds.isEmpty)
    for value in 1...100 { samples.record(milliseconds: Double(value)) }
    #expect(samples.percentile(0.5) == 50)
    #expect(samples.percentile(0.95) == 95)
    #expect(samples.percentile(0.99) == 99)
    #expect(samples.percentile(1.1) == nil)
}

@Test func benchmarkSamplesHaveBoundedMemory() {
    var samples = VideoBenchmarkSamples()
    for _ in 0..<5_000 { samples.record(milliseconds: 1) }
    #expect(samples.milliseconds.count == 4_096)
}
