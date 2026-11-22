import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

// Packaged resource defaults: linking a `SeamResource` provider is the declaration, so a derived
// system resolves the resource with nothing authored — and every authored route still wins.

private class ScratchPad {}
private final class AuthoredPad: ScratchPad {}

/// The packaged provider under test; `NSObject`-rooted so the class-list census finds it.
private final class DefaultPadProvider: NSObject, SeamResource {
    static var providedResources: [Any.Type] {
        [ScratchPad.self]
    }

    static func makeResource(_: Any.Type, _: SeamContext) -> Any {
        ScratchPad()
    }

    static var sweptSeams: [(seam: String, domain: SeamDomain)] {
        [("ScratchPad.tilt", .anyOf([.bool(false), .bool(true)]))]
    }
}

private final class PadUser {
    let pad: ScratchPad
    init(pad: ScratchPad) {
        self.pad = pad
    }
}

final class ResourceDefaultTests: XCTestCase {
    func testAPackagedDefaultServesAnUnprovidedResource() async {
        var resolved: [ScratchPad] = []
        _ = await spec().baselined(on: padUser(collecting: { resolved.append($0) })).record()

        XCTAssertFalse(resolved.isEmpty)
        XCTAssertFalse(resolved.contains { $0 is AuthoredPad }, "nothing authored, so the default provider builds")
    }

    func testAProvidedResourceBeatsThePackagedDefault() async {
        var resolved: [ScratchPad] = []
        _ = await spec()
            .provides(ScratchPad.self) { _ in AuthoredPad() }
            .baselined(on: padUser(collecting: { resolved.append($0) }))
            .record()

        XCTAssertFalse(resolved.isEmpty)
        XCTAssertTrue(resolved.allSatisfy { $0 is AuthoredPad }, "an authored .provides shadows the default")
    }

    func testAProviderSweepJoinsTheDeclaredSurfaceOnReach() async {
        // No `.vary` anywhere: the golden reading the seam is what earns the provider's sweep, so
        // both declared values get explored with nothing authored.
        var tilts: Set<Bool> = []
        let spec = Spec<PadUser>("pad.sweep")
            .operations {
                Op("tilt") { _, seams in
                    tilts.insert(seams.bool("ScratchPad.tilt", default: false))
                }
            }
            .baselined { seams in PadUser(pad: seams.resolve(ScratchPad.self)) }
        _ = await spec.record()

        XCTAssertEqual(tilts, [false, true])
    }

    func testAnAuthoredSeamShadowsTheProviderSweep() async {
        // Pinned to the live default, so any `true` reading could only come from the provider's
        // sweep leaking past the authored declaration.
        var tilts: Set<Bool> = []
        let spec = Spec<PadUser>("pad.pinned")
            .operations {
                Op("tilt") { _, seams in
                    tilts.insert(seams.bool("ScratchPad.tilt", default: false))
                }
            }
            .vary { Seam("ScratchPad.tilt", .anyOf([.bool(false)])) }
            .baselined { seams in PadUser(pad: seams.resolve(ScratchPad.self)) }
        _ = await spec.record()

        XCTAssertEqual(tilts, [false])
    }

    func testTheDefaultBuildsAFreshResourcePerCapture() async {
        var resolved: [ScratchPad] = []
        _ = await spec().baselined(on: padUser(collecting: { resolved.append($0) })).record()

        XCTAssertEqual(
            Set(resolved.map(ObjectIdentifier.init)).count,
            resolved.count,
            "a capture resource is per-capture; a shared instance would leak state between probes"
        )
    }

    private func spec() -> Spec<PadUser> {
        Spec<PadUser>("pad.default")
            .operations {
                Op("touch") { _ in }
            }
    }

    /// Builds the baseline, handing `resolved` each pad the capture resolves.
    private func padUser(collecting resolved: @escaping (ScratchPad) -> Void) -> (SeamContext) -> PadUser {
        { seams in
            let user = PadUser(pad: seams.resolve(ScratchPad.self))
            resolved(user.pad)
            return user
        }
    }
}
