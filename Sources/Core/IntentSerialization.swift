import Foundation

// The JSON form of an `Intent` — what `haruspec intent` writes per spec for the replay to read
// (`HARUSPEC_INTENT_PATH`) and what a check site may load with `Intent(contentsOf:)`. Every field
// is optional so a partial spec is ergonomic, and a bare label still spells an unconditioned event.

extension Intent.EventChange: Codable {
    enum CodingKeys: String, CodingKey {
        case label, conditions
    }

    /// A bare label decodes from a plain string — the unconditioned form's natural JSON.
    public init(from decoder: Decoder) throws {
        if let label = try? decoder.singleValueContainer().decode(String.self) {
            self.init(label)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            container.decode(String.self, forKey: .label),
            when: container.decodeIfPresent([InputCondition].self, forKey: .conditions) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        if conditions.isEmpty {
            var container = encoder.singleValueContainer()
            try container.encode(label)
        } else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(label, forKey: .label)
            try container.encode(conditions, forKey: .conditions)
        }
    }
}

extension Intent.ValueChange: Codable {
    enum CodingKeys: String, CodingKey {
        case label, field, relation, conditions
    }

    /// Only the label is required — a bare `{"label": "Receipt"}` is the wholesale form.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            container.decode(String.self, forKey: .label),
            field: container.decodeIfPresent(String.self, forKey: .field),
            relation: container.decodeIfPresent(ValueRelation.self, forKey: .relation),
            when: container.decodeIfPresent([InputCondition].self, forKey: .conditions) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(field, forKey: .field)
        try container.encodeIfPresent(relation, forKey: .relation)
        if !conditions.isEmpty {
            try container.encode(conditions, forKey: .conditions)
        }
    }
}

extension Intent: Codable {
    enum CodingKeys: String, CodingKey {
        case expectedNewEvents, expectedRemovedEvents, expectedValueChanges
        case expectedOrderingRelaxations, expectedOrderingLosses, expectedOrderingAdditions
        case expectedReorders, expectedDomainMigrations, acceptedBlindSpots
    }

    /// Every field is optional in JSON so a partial spec is ergonomic.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expectedNewEvents = try container.decodeIfPresent([EventChange].self, forKey: .expectedNewEvents) ?? []
        expectedRemovedEvents = try container
            .decodeIfPresent([EventChange].self, forKey: .expectedRemovedEvents) ?? []
        expectedValueChanges = try container
            .decodeIfPresent([ValueChange].self, forKey: .expectedValueChanges) ?? []
        expectedOrderingRelaxations = try container
            .decodeIfPresent([DomainName].self, forKey: .expectedOrderingRelaxations) ?? []
        expectedOrderingLosses = try container
            .decodeIfPresent([String].self, forKey: .expectedOrderingLosses) ?? []
        expectedOrderingAdditions = try container
            .decodeIfPresent([String].self, forKey: .expectedOrderingAdditions) ?? []
        expectedReorders = try container
            .decodeIfPresent([String].self, forKey: .expectedReorders) ?? []
        expectedDomainMigrations = try container
            .decodeIfPresent([DomainMove].self, forKey: .expectedDomainMigrations) ?? []
        acceptedBlindSpots = try container
            .decodeIfPresent([String].self, forKey: .acceptedBlindSpots) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expectedNewEvents, forKey: .expectedNewEvents)
        try container.encode(expectedRemovedEvents, forKey: .expectedRemovedEvents)
        try container.encode(expectedValueChanges, forKey: .expectedValueChanges)
        try container.encode(expectedOrderingRelaxations, forKey: .expectedOrderingRelaxations)
        try container.encode(expectedOrderingLosses, forKey: .expectedOrderingLosses)
        try container.encode(expectedOrderingAdditions, forKey: .expectedOrderingAdditions)
        try container.encode(expectedReorders, forKey: .expectedReorders)
        try container.encode(expectedDomainMigrations, forKey: .expectedDomainMigrations)
        try container.encode(acceptedBlindSpots, forKey: .acceptedBlindSpots)
    }
}

public extension Intent {
    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: url))
    }
}
