import Foundation

// The sentences that take modifier chains: an event the change emits or omits, a payload it
// alters. Each chained call narrows the declaration it is on and returns the narrowed sentence.

/// An `Emits` or `Omits` sentence: one `Intent.EventChange`, narrowed by the chained modifiers
/// both spell the same way.
public protocol EventIntention: Intention {
    var declaration: Intent.EventChange { get set }
}

public extension EventIntention {
    /// Only in a probe whose recorded reads of `seam` all returned `value`.
    func when(_ seam: String, is value: CanonicalValue) -> Self {
        var narrowed = self
        narrowed.declaration.conditions.append(InputCondition(seam: seam, is: value))
        return narrowed
    }

    /// Only under the declared op `op`.
    func only(in op: String) -> Self {
        var narrowed = self
        narrowed.declaration.scoped(.only(in: op))
        return narrowed
    }

    /// Under the declared op `op`, at most once per application of it.
    func once(per op: String) -> Self {
        var narrowed = self
        narrowed.declaration.scoped(.once(per: op))
        return narrowed
    }

    /// After some event labeled `anchor` in the same op (the whole trace when the event has none).
    func after(_ anchor: String) -> Self {
        var narrowed = self
        narrowed.declaration.placed(.after(anchor))
        return narrowed
    }

    /// Before some event labeled `anchor` in the same op (the whole trace when the event has none).
    func before(_ anchor: String) -> Self {
        var narrowed = self
        narrowed.declaration.placed(.before(anchor))
        return narrowed
    }
}

extension Intent.EventChange {
    /// Sets the one op scope; a second is a contradiction and traps.
    mutating func scoped(_ scope: OpScope) {
        precondition(
            self.scope == nil,
            "\(label) already declares \(self.scope!.dslText); one op scope per declaration"
        )
        self.scope = scope
    }

    /// Sets the one position; a second is a contradiction and traps.
    mutating func placed(_ position: Position) {
        precondition(
            self.position == nil,
            "\(label) already declares \(self.position!.dslText); one position per declaration"
        )
        self.position = position
    }
}

/// The change emits an event the baseline never had — a declared feature, not an accident.
///
/// Narrow it to where it belongs and it trips on everything else:
///
///     Emits("Inventory.reserve").when("add.quantity", is: 1)     // in these probes
///     Emits("CartRewardsDidUpdate").once(per: "add")             // one per application of the op
///     Emits("CartRewardsDidUpdate").after("CartDidChange")       // after that event, same op
///
/// One op scope and one position per declaration; a second of either traps.
public struct Emits: EventIntention {
    public var declaration: Intent.EventChange

    public init(_ label: String) {
        declaration = Intent.EventChange(label)
    }

    public func apply(to intent: inout Intent) {
        intent.expectedNewEvents.append(declaration)
    }
}

/// The change omits an event the baseline produced — a declared removal.
///
/// Narrowed the way `Emits` is: `Omits("Inventory.reserve").when("add.quantity", is: 0)`,
/// `.only(in:)`, `.once(per:)`, `.after(_:)`, `.before(_:)` — a position is checked where the
/// event was, in the baseline.
public struct Omits: EventIntention {
    public var declaration: Intent.EventChange

    public init(_ label: String) {
        declaration = Intent.EventChange(label)
    }

    public func apply(to intent: inout Intent) {
        intent.expectedRemovedEvents.append(declaration)
    }
}

/// The change alters an event's payload — a specific field, or (with no fields named) any of them.
/// Declaring one field does NOT excuse a change to another field of the same event.
///
/// Say *how* it changes and the declaration becomes a tripwire for everything else:
///
///     Changes("CheckoutDidComplete", field: "totalCents").to(11363)
///     Changes("Receipt", field: "discountCents").increases()
///     Changes("LoyaltyPointsEarned", field: "points").within(1 ... 64)
///     Changes("Receipt", field: "discountCents").when("applyPromo.code", is: "SAVE10")
///     Changes("LoyaltyPointsEarned", field: "points").only(in: "checkout")
///
/// One value relation and one op scope per declaration; a second of either traps.
public struct Changes: Intention {
    let label: String
    let fields: [String]
    var relation: ValueRelation?
    var conditions: [InputCondition] = []
    var scope: OpScope?

    public init(_ label: String, field fields: String...) {
        self.label = label
        self.fields = fields
    }

    /// The new value is exactly `value` — a scalar, the only shape the grammar can spell back.
    public func to(_ value: CanonicalValue) -> Changes {
        precondition(value.isScalar, "Changes(…).to(_:) takes a scalar, not \(value.canonicalString)")
        return narrowed(.to(value))
    }

    /// The value went up.
    public func increases() -> Changes {
        narrowed(.increases)
    }

    /// The value went down.
    public func decreases() -> Changes {
        narrowed(.decreases)
    }

    /// The new value lies in `range`.
    public func within(_ range: ClosedRange<Int>) -> Changes {
        narrowed(.within(Double(range.lowerBound) ... Double(range.upperBound)))
    }

    /// The new value lies in `range`.
    public func within(_ range: ClosedRange<Double>) -> Changes {
        narrowed(.within(range))
    }

    private func narrowed(_ relation: ValueRelation) -> Changes {
        precondition(
            self.relation == nil,
            "Changes(\"\(label)\") already declares \(self.relation!.dslText); one value relation per declaration"
        )
        var narrowed = self
        narrowed.relation = relation
        return narrowed
    }

    /// Only in a probe whose recorded reads of `seam` all returned `value`.
    public func when(_ seam: String, is value: CanonicalValue) -> Changes {
        var narrowed = self
        narrowed.conditions.append(InputCondition(seam: seam, is: value))
        return narrowed
    }

    /// Only under the declared op `op`.
    public func only(in op: String) -> Changes {
        precondition(
            scope == nil,
            "Changes(\"\(label)\") already declares \(scope!.dslText); one op scope per declaration"
        )
        var narrowed = self
        narrowed.scope = .only(in: op)
        return narrowed
    }

    public func apply(to intent: inout Intent) {
        let fields: [String?] = fields.isEmpty ? [nil] : fields
        for field in fields {
            intent.expectedValueChanges.append(
                Intent.ValueChange(label, field: field, relation: relation, when: conditions, scope: scope)
            )
        }
    }
}
