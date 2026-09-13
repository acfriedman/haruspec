import Foundation

// The JSON form of a `Divergence`: optionals are omitted when absent, and `rejectedBy` only
// appears when a declaration actually rejected the divergence, so a verdict artifact reads as
// what happened rather than as a schema.

public extension Divergence {
    internal enum CodingKeys: String, CodingKey {
        case kind, label, baselineSeq, candidateSeq, detail, fromDomain, toDomain
        case field, baselineValue, candidateValue, op, isAdvisory, classification, rejectedBy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        baselineSeq = try container.decodeIfPresent(Int.self, forKey: .baselineSeq)
        candidateSeq = try container.decodeIfPresent(Int.self, forKey: .candidateSeq)
        detail = try container.decode(String.self, forKey: .detail)
        fromDomain = try container.decodeIfPresent(String.self, forKey: .fromDomain)
        toDomain = try container.decodeIfPresent(String.self, forKey: .toDomain)
        field = try container.decodeIfPresent(String.self, forKey: .field)
        baselineValue = try container.decodeIfPresent(CanonicalValue.self, forKey: .baselineValue)
        candidateValue = try container.decodeIfPresent(CanonicalValue.self, forKey: .candidateValue)
        op = try container.decodeIfPresent(OpIdentity.self, forKey: .op)
        isAdvisory = try container.decode(Bool.self, forKey: .isAdvisory)
        classification = try container.decode(DivergenceClass.self, forKey: .classification)
        rejectedBy = try container.decodeIfPresent([String].self, forKey: .rejectedBy) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(baselineSeq, forKey: .baselineSeq)
        try container.encodeIfPresent(candidateSeq, forKey: .candidateSeq)
        try container.encode(detail, forKey: .detail)
        try container.encodeIfPresent(fromDomain, forKey: .fromDomain)
        try container.encodeIfPresent(toDomain, forKey: .toDomain)
        try container.encodeIfPresent(field, forKey: .field)
        try container.encodeIfPresent(baselineValue, forKey: .baselineValue)
        try container.encodeIfPresent(candidateValue, forKey: .candidateValue)
        try container.encodeIfPresent(op, forKey: .op)
        try container.encode(isAdvisory, forKey: .isAdvisory)
        try container.encode(classification, forKey: .classification)
        if !rejectedBy.isEmpty {
            try container.encode(rejectedBy, forKey: .rejectedBy)
        }
    }
}
