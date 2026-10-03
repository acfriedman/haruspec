import HaruspecAudit
import HaruspecTrace
import XCTest

// The static tier of the audit. What is being pinned is mostly the *direction* of its errors: a
// deny-list is never exhaustive, so it must over-report rather than under-report — a false finding
// costs one reviewable declaration, a missed one ships as a silent green.

final class ChannelLintTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func audit(_ origins: [TraceOrigin]) -> AuditReport {
        AuditReport.audit(origins: origins, root: root)
    }

    func testFindsADirectNotificationPostInACoveredClass() throws {
        try write(
            """
            @implementation AnalyticsTracker
            - (void)track:(NSString *)event {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"Tracked" object:self];
            }
            @end
            """,
            to: "App/AnalyticsTracker.m"
        )

        let report = audit([TraceOrigin(label: "Analytics", symbol: "AnalyticsTracker")])

        XCTAssertFalse(report.isClean)
        XCTAssertEqual(report.blindSpots, ["NotificationCenter.default"])
        XCTAssertEqual(report.findings.map(\.line), [3])
        XCTAssertEqual(report.findings.first?.file, "App/AnalyticsTracker.m")
    }

    func testFindsTheSameChannelThroughItsSwiftSpelling() throws {
        try write(
            """
            final class Port {
                func go() { NotificationCenter.default.post(name: .init("X"), object: nil) }
            }
            """,
            to: "App/Port.swift"
        )

        let report = audit([TraceOrigin(label: "P", symbol: "Port", source: "App/Port.swift")])

        XCTAssertEqual(report.blindSpots, ["NotificationCenter.default"])
    }

    // MARK: - Position decides: a default handed in is a seam, a use is an escape

    /// The shape legacy Obj-C is full of: a convenience initializer supplying the real center, with the
    /// designated initializer taking one. The harness overrides it, so nothing escapes — and gating on
    /// this would bury the finding above under one line per injectable class in the codebase.
    func testADefaultSuppliedToAnInitializerDoesNotGate() throws {
        try write(
            """
            @implementation CartManager
            - (instancetype)init {
                return [self initWithInventory:[InventoryLedger shared]
                            notificationCenter:[NSNotificationCenter defaultCenter]];
            }
            @end
            """,
            to: "App/CartManager.m"
        )

        let report = audit([TraceOrigin(label: "Cart", symbol: "CartManager")])

        XCTAssertTrue(report.isClean, "an injectable default is not an escape")
        XCTAssertEqual(report.blindSpots, [])
        XCTAssertEqual(report.injectableDefaults.map(\.line), [4], "still reported, so a reviewer can confirm")
    }

    func testASwiftDefaultedParameterDoesNotGate() throws {
        try write(
            """
            final class Port {
                init(center: NotificationCenter = NotificationCenter.default) {}
            }
            """,
            to: "App/Port.swift"
        )

        let report = audit([TraceOrigin(label: "P", symbol: "Port", source: "App/Port.swift")])

        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.injectableDefaults.count, 1)
    }

    /// A global cached into a field is the temporal hole injection exists to close: nothing overrides
    /// it, and a swap that happens later never reaches this instance.
    func testAGlobalCachedIntoAFieldStillGates() throws {
        try write("final class Port {\n    let center = NotificationCenter.default\n}\n", to: "App/Port.swift")

        let report = audit([TraceOrigin(label: "P", symbol: "Port", source: "App/Port.swift")])

        XCTAssertFalse(report.isClean, "a cached global is not an injection point")
        XCTAssertEqual(report.blindSpots, ["NotificationCenter.default"])
    }

    func testFindsTimersCombineAndDelayedDispatch() throws {
        try write(
            """
            import Combine
            final class Feed {
                func start() {
                    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {}
                }
            }
            """,
            to: "App/Feed.swift"
        )

        let report = audit([TraceOrigin(label: "F", symbol: "Feed", source: "App/Feed.swift")])

        XCTAssertEqual(Set(report.blindSpots), ["Combine", "Timer / RunLoop", "dispatch"])
    }

    /// A class that keeps to the injected center is clean — and only an audit that ran may say so.
    func testAnInjectedCenterIsNotAFinding() throws {
        try write(
            """
            @implementation CartManager
            - (void)add {
                [_notificationCenter postNotificationName:@"CartChanged" object:self];
            }
            @end
            """,
            to: "App/CartManager.m"
        )

        let report = audit([TraceOrigin(label: "Cart", symbol: "CartManager")])

        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.blindSpots, [], "audited-and-clean is [], never nil — that distinction is the claim")
    }

    func testACommentedMentionIsDocumentationNotAReach() throws {
        try write(
            """
            @implementation CartManager
            // was: [[NSNotificationCenter defaultCenter] post...]; now injected
            @end
            """,
            to: "App/CartManager.m"
        )

        XCTAssertTrue(audit([TraceOrigin(label: "Cart", symbol: "CartManager")]).isClean)
    }

    // MARK: - Unresolved sources fail the same way findings do

    func testAnUnreadableDeclarationIsABlindSpotToo() throws {
        try write("@implementation Local\n@end\n", to: "App/Local.m")

        let report = audit([
            TraceOrigin(label: "Local", symbol: "Local"),
            TraceOrigin(label: "Vendor", symbol: "VendorSDKClient")
        ])

        XCTAssertFalse(report.isClean, "a source we cannot read is not a source with nothing in it")
        XCTAssertEqual(report.blindSpots, ["VendorSDKClient (no source found)"])
    }

    /// Categories are audited with the class, which is the payoff of resolving by declaration: this
    /// finding lives in a file whose name has nothing to do with the class.
    func testACategorySBypassIsFoundWithItsClass() throws {
        try write("@implementation CartManager\n@end\n", to: "App/CartManager.m")
        try write(
            """
            @implementation CartManager (Promo)
            - (void)applyPromo {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"Promo" object:self];
            }
            @end
            """,
            to: "App/Discounts.m"
        )

        let report = audit([TraceOrigin(label: "Cart", symbol: "CartManager")])

        XCTAssertEqual(report.findings.map(\.file), ["App/Discounts.m"])
    }

    func testADirectManagedObjectContextReachIsACoreDataBypass() throws {
        try write(
            """
            @implementation CartManager
            - (void)archiveOrder {
                NSManagedObjectContext *context = delegate.persistentContainer.viewContext;
                [context save:NULL];
            }
            @end
            """,
            to: "App/CartManager.m"
        )

        let report = audit([TraceOrigin(label: "Cart", symbol: "CartManager")])

        XCTAssertFalse(report.isClean)
        XCTAssertEqual(report.blindSpots, ["Core Data"], "state leaving through a store nothing records")
    }

    func testAnInjectedContextParameterIsNotACoreDataBypass() throws {
        // The green path: persistence handed in at an injection point the harness can override.
        try write(
            """
            @implementation CartManager
            - (instancetype)initWithContext:(NSManagedObjectContext *)context {
                _context = context;
                return self;
            }
            @end
            """,
            to: "App/CartManager.m"
        )

        let report = audit([TraceOrigin(label: "Cart", symbol: "CartManager")])

        XCTAssertTrue(report.isClean, report.blindSpots.joined(separator: ", "))
        XCTAssertEqual(
            report.findings.map(\.use),
            [.injectableDefault],
            "reported for review, gating nothing — the parameter is the injection point"
        )
    }

    func testADelegateDigSuppliedAsAnInitDefaultDoesNotGate() throws {
        // The migration-prep shape: the designated init takes the context, and plain -init defaults
        // it to the app delegate's container — a chain in argument position, not a reach.
        try write(
            """
            @implementation ProductStore
            - (instancetype)init {
                AppDelegate *delegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
                return [self initWithContext:delegate.persistentContainer.viewContext];
            }
            @end
            """,
            to: "App/ProductStore.m"
        )

        let report = audit([TraceOrigin(label: "ProductStore", symbol: "ProductStore")])

        XCTAssertTrue(report.isClean, report.blindSpots.joined(separator: ", "))
        XCTAssertEqual(report.injectableDefaults.count, 1)
    }

    func testAChainedContextReceiverStillGates() throws {
        try write(
            """
            @implementation ProductStore
            - (void)save {
                [delegate.persistentContainer.viewContext save:NULL];
            }
            @end
            """,
            to: "App/ProductStore.m"
        )

        XCTAssertFalse(audit([TraceOrigin(label: "ProductStore", symbol: "ProductStore")]).isClean)
    }

    func testEachFileIsReadOnceEvenWhenSeveralLabelsShareIt() throws {
        try write(
            """
            @implementation A
            - (void)go { [[NSNotificationCenter defaultCenter] postNotificationName:@"X" object:self]; }
            @end
            @implementation B
            @end
            """,
            to: "App/Both.m"
        )

        let report = audit([TraceOrigin(label: "A", symbol: "A"), TraceOrigin(label: "B", symbol: "B")])

        XCTAssertEqual(report.findings.count, 1, "one file, one reading — not one per declaration")
    }
}
