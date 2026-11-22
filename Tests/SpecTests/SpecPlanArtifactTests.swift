import Foundation
import HaruspecCore
import HaruspecSeams
@testable import HaruspecSpec
import XCTest

final class SpecPlanArtifactTests: XCTestCase {
    private func cart() -> BaselinedSpec<PromoCart> {
        Spec<PromoCart>("promo-cart.artifact")
            .operations {
                Op("addCoffee") { cart, seams in
                    cart.addItem(priceCents: 999, qty: Int(seams.int("coffeeQty", default: 10)))
                }
                Op("promo") { $0.applyPromo() }
                Op("checkout") { _ = $0.checkout() }.last()
            }
            .vary {
                Seam("coffeeQty", .int(1 ... 20))
                Ordering(max: 10)
            }
            .baselined(on: makeGood)
    }

    private func artifactURL(_ name: String, suffix: String = "json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).\(suffix)")
    }

    // MARK: - Gzip plan artifacts

    func testGzipPlanRoundTripsAndShrinks() async throws {
        let url = artifactURL("plan", suffix: "plan.json.gz")
        defer { try? FileManager.default.removeItem(at: url) }

        let written = await try cart().record(to: url)
        let reloaded = try SpecPlan(contentsOf: url)
        XCTAssertEqual(reloaded, written, "compression must be invisible to replay")

        let archived = try Data(contentsOf: url)
        let plain = try written.jsonData()
        XCTAssertTrue(archived.prefix(2).elementsEqual([0x1F, 0x8B]), "a .gz destination writes real gzip")
        XCTAssertLessThan(
            archived.count,
            plain.count / 5,
            "the whole point: the committed artifact is a fraction of the pretty JSON"
        )
    }

    /// The `Scenario` → `Spec` rename moved the plan's name key, which is why schemaVersion went to
    /// 2. A version-1 artifact no longer decodes into this shape at all, so the version has to gate
    /// *before* the rest: the caller needs "re-record the plan", not a keyNotFound on `specName`.
    func testAPreRenamePlanIsRejectedWithTheReRecordError() throws {
        let legacy = Data("""
        {"schemaVersion":1,"scenarioName":"promo-cart.artifact","seed":7,
         "variedSeams":[],"probes":[],"coveredClasses":[]}
        """.utf8)

        XCTAssertThrowsError(try SpecPlan(jsonData: legacy)) { error in
            XCTAssertEqual(
                error as? SpecPlanError,
                .unsupportedSchemaVersion(found: 1, supported: SpecPlan.supportedSchemaVersion)
            )
        }
    }

    func testThePlanNamesItsSpec() async throws {
        let data = try await cart().record().jsonData()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"specName\""))
        XCTAssertFalse(json.contains("\"scenarioName\""))
        let roundTripped = try await SpecPlan(jsonData: cart().record().jsonData())
        XCTAssertEqual(roundTripped.specName, "promo-cart.artifact")
    }

    func testGzipDetectionIsByContentNotFilename() async throws {
        // A renamed artifact (plan.json holding gzip bytes) still replays — sniffing the magic, not
        // trusting the extension.
        let url = artifactURL("renamed")
        defer { try? FileManager.default.removeItem(at: url) }

        let plan = await cart().record()
        try Gzip.compress(plan.jsonData()).write(to: url)
        XCTAssertEqual(try SpecPlan(contentsOf: url), plan)
    }

    func testGzipArchivesAreDeterministic() async throws {
        let payload = await try cart().record().jsonData()
        XCTAssertEqual(
            try Gzip.compress(payload),
            try Gzip.compress(payload),
            "MTIME is pinned; identical plans must produce byte-identical archives for git"
        )
    }

    func testGzipHonorsOptionalHeaderFields() throws {
        // A hand-re-gzipped plan may carry FNAME; the reader must skip it, not mis-frame the stream.
        let payload = Data("{\"hand\":\"gzipped\"}".utf8)
        var archive = try Gzip.compress(payload)
        archive[3] |= 0x08 // set FNAME
        archive.insert(contentsOf: Array("plan.json\0".utf8), at: 10)
        XCTAssertEqual(try Gzip.decompress(archive), payload)
    }

    func testGzipRejectsCorruptChecksum() throws {
        var archive = try Gzip.compress(Data("payload-worth-checking".utf8))
        archive[archive.count - 5] ^= 0xFF // flip a CRC byte
        XCTAssertThrowsError(try Gzip.decompress(archive)) { error in
            XCTAssertEqual(error as? Gzip.GzipError, .checksumMismatch)
        }
    }

    // MARK: - Schema gate

    func testUnsupportedSchemaVersionIsRejected() async throws {
        var plan = await cart().record()
        plan.schemaVersion = 99
        let bytes = try plan.jsonData()

        XCTAssertThrowsError(try SpecPlan(jsonData: bytes)) { error in
            XCTAssertEqual(
                error as? SpecPlanError,
                .unsupportedSchemaVersion(found: 99, supported: SpecPlan.supportedSchemaVersion),
                "a stale artifact must refuse to replay, loudly, not decode by field-name luck"
            )
        }
    }
}

// The plan artifact's file-layer guarantees: gzip round-trip (a committed multi-MB plan shrinks to
// hundreds of KB without touching replay semantics), content-sniffed decompression, deterministic
// archives, and the schemaVersion gate that keeps a stale artifact from replaying with confidence.

private func makeGood(_ ctx: SeamContext) -> PromoCart {
    GoodCart(center: ctx.notifications)
}
