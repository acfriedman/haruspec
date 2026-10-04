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

@Continuous
struct GaugeSpec: SpecProviding {
    var spec: Spec<Gauge> {
        Spec<Gauge>("gauge.continuous")
            .system { _ in LegacyGauge() }
            .operations { Op("read") { gauge in _ = gauge.reading() } }
    }
}

@Suite(.campaign)
struct ContinuousMacroTests {
    @Test
    func theEmittedSuiteRunsNothingWithoutAMode() {
        #expect(GaugeSpec().continuousModes(environment: [:]).isEmpty)
        #expect(ContinuousSuite(GaugeSpecContinuous.self)?.path == "GaugeSpecContinuous")
    }
}
