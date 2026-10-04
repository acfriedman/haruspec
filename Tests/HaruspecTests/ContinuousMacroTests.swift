import Haruspec
import Testing

// The consumer's view of `@Continuous`: the attribute alone yields a suite the test runner finds.

protocol Gauge: AnyObject {
    func reading() -> Int
}

final class LegacyGauge: Gauge {
    func reading() -> Int {
        42
    }
}

@Continuous(baseline: LegacyGauge.init)
struct GaugeSpec: SpecProviding {
    var spec: Spec<Gauge> {
        Spec<Gauge>("gauge.continuous")
            .operations { Op("read") { gauge in _ = gauge.reading() } }
    }
}

@Suite(.campaign)
struct ContinuousMacroTests {
    @Test
    func theEmittedSuiteRunsNothingWithoutAMode() {
        #expect(GaugeSpec().baselined(on: LegacyGauge.init).continuousModes(environment: [:]).isEmpty)
        #expect(ContinuousSuite(GaugeSpecContinuous.self)?.path == "GaugeSpecContinuous")
    }
}
