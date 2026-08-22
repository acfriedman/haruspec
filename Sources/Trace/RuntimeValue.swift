import Foundation
import HaruspecCore
import ObjectiveC

/// Best-effort conversion of a runtime `Any` into a `CanonicalValue`.
///
/// Used by the runtime capture backends (notifications, KVO) and by `@Traced`, where values arrive
/// type-erased — often as bridged `NSNumber`s or as plain objects. Unlike the compile-time
/// `Encodable` bridge, this must cope with whatever the runtime hands us: bridged JSON scalars are
/// claimed first, then we reach for structure (`Encodable`, then reflection) so a non-`Codable`
/// object still produces a *diffable* tree instead of an opaque `String(describing:)` id, and only
/// truly structureless values degrade to a stable string as a last resort.
public enum RuntimeValue {
    /// Deepest structural nesting we'll reflect through before bailing to a string. The visited set
    /// already breaks reference cycles; this additionally bounds pathologically deep object graphs.
    private static let maxDepth = 8

    public static func canonical(_ any: Any) -> CanonicalValue {
        canonical(any, depth: 0, visited: [])
    }

    private static func canonical(
        _ any: Any,
        depth: Int,
        visited: Set<ObjectIdentifier>
    ) -> CanonicalValue {
        switch any {
        case let value as CanonicalValue:
            return value

        // NSNumber first: it subsumes bridged Swift Bool/Int/Double and disambiguates them by type,
        // avoiding the classic "5 as? Bool == true" bridging trap.
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            switch String(cString: number.objCType) {
            case "f", "d": return .double(number.doubleValue)
            default: return .int(number.int64Value)
            }

        case let string as String:
            return .string(string)

        case let array as [Any]:
            return .array(array.map { canonical($0, depth: depth, visited: visited) })

        case let dict as [String: Any]:
            return .object(dict.mapValues { canonical($0, depth: depth, visited: visited) })

        case let dict as [AnyHashable: Any]:
            return .object(Dictionary(uniqueKeysWithValues: dict.map {
                (String(describing: $0.key), canonical($0.value, depth: depth, visited: visited))
            }))

        default:
            // Encodable first so custom `CodingKeys` are honored, then structural reflection, and
            // only then the opaque string of last resort.
            if let encodable = any as? Encodable, let value = try? CanonicalValue(encoding: encodable) {
                return value
            }
            if let structured = structural(any, depth: depth, visited: visited) {
                return structured
            }
            return .string(String(describing: any))
        }
    }

    // MARK: - Structural canonicalization

    /// Reflects an object into an `.object` tree: Obj-C runtime properties first, then a Swift
    /// `Mirror`. Returns `nil` when the value exposes no keyed structure (or the depth cap is hit),
    /// leaving the caller to fall back to `String(describing:)`.
    private static func structural(
        _ any: Any,
        depth: Int,
        visited: Set<ObjectIdentifier>
    ) -> CanonicalValue? {
        guard depth < maxDepth else { return nil }
        if let object = any as? NSObject,
           let structured = objcObject(object, depth: depth, visited: visited) {
            return structured
        }
        return mirrorObject(any, depth: depth, visited: visited)
    }

    /// Walks the Obj-C property list from the object's class up to (but not including) `NSObject`,
    /// reading each declared property via KVC. Returns `nil` if the class declares no properties,
    /// so a bare `NSObject` subclass falls through to `Mirror`/string.
    private static func objcObject(
        _ object: NSObject,
        depth: Int,
        visited: Set<ObjectIdentifier>
    ) -> CanonicalValue? {
        let id = ObjectIdentifier(object)
        guard !visited.contains(id) else { return nil }
        var visited = visited
        visited.insert(id)

        var result: [String: CanonicalValue] = [:]
        var cls: AnyClass? = type(of: object)
        while let current = cls, current != NSObject.self {
            var count: UInt32 = 0
            if let list = class_copyPropertyList(current, &count) {
                for index in 0 ..< Int(count) {
                    let name = String(cString: property_getName(list[index]))
                    let value = object.value(forKey: name)
                    result[name] = value.map { canonical($0, depth: depth + 1, visited: visited) } ?? .null
                }
                free(list)
            }
            cls = class_getSuperclass(current)
        }
        return result.isEmpty ? nil : .object(result)
    }

    /// Reflects a Swift struct/class via `Mirror`. Optionals are unwrapped transparently; a keyed
    /// structure (all children labeled) becomes an `.object`, recursing each child. Anything else
    /// (tuples, enums, collections already handled above, opaque values) yields `nil`.
    private static func mirrorObject(
        _ any: Any,
        depth: Int,
        visited: Set<ObjectIdentifier>
    ) -> CanonicalValue? {
        let mirror = Mirror(reflecting: any)

        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return .null }
            return canonical(child.value, depth: depth, visited: visited)
        }

        guard mirror.displayStyle == .struct || mirror.displayStyle == .class else { return nil }

        var visited = visited
        if mirror.displayStyle == .class {
            let id = ObjectIdentifier(any as AnyObject)
            guard !visited.contains(id) else { return nil }
            visited.insert(id)
        }

        var result: [String: CanonicalValue] = [:]
        for child in mirror.children {
            guard let label = child.label else { return nil }
            result[label] = canonical(child.value, depth: depth + 1, visited: visited)
        }
        return result.isEmpty ? nil : .object(result)
    }
}
