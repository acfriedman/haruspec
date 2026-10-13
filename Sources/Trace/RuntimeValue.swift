import Foundation
import HaruspecCore
import ObjectiveC

/// Best-effort conversion of a runtime `Any` into a `CanonicalValue`.
///
/// Used by the runtime capture backends (notifications, KVO) and by the stamped forwarders and doubles, where values
/// arrive
/// type-erased — often as bridged `NSNumber`s or as plain objects. Unlike the compile-time
/// `Encodable` bridge, this must cope with whatever the runtime hands us: bridged JSON scalars are
/// claimed first, then we reach for structure (`Encodable`, then reflection) so a non-`Codable`
/// object still produces a *diffable* tree instead of an opaque `String(describing:)` id, and only
/// truly structureless values degrade to a stable string as a last resort. A pointer is recorded
/// without its address, which no two runs share.
public enum RuntimeValue {
    /// Deepest structural nesting we'll reflect through before bailing to a string. The visited set
    /// already breaks reference cycles; this additionally bounds pathologically deep object graphs.
    private static let maxDepth = 8

    public static func canonical(_ any: Any) -> CanonicalValue {
        canonical(any, depth: 0, visited: [])
    }

    /// Returns a thrown error as a caller can branch on it. A Cocoa error is its domain, code, and
    /// user info, so two equal errors match however their user info happens to print.
    ///
    /// - Parameter error: The error a stamped method threw.
    /// - Returns: An `.object` keyed `domain`, `code`, and `userInfo` for an `NSError`; for a Swift
    ///   error, its description, which keeps the associated values a bridged code drops.
    public static func thrown(_ error: any Error) -> CanonicalValue {
        guard type(of: error) is NSError.Type else {
            return .string(String(describing: error))
        }
        return canonical(error: error as NSError, depth: 0, visited: [])
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

        // A pointer's address is where a value happens to live this run, not what the program did:
        // two ports hand a block the same `BOOL *stop` at different addresses. A nil pointer is
        // still `.null`, by way of the optional below, so whether one was passed stays compared.
        case let buffer as any BufferAddress:
            return .string("<buffer pointer, count \(buffer.count)>")

        case is any Address:
            return .string("<pointer>")

        // An enum or option set reads as its raw value: an imported Obj-C enum otherwise prints
        // its type name alone, whatever the case.
        case let raw as any RawRepresentable:
            return canonical(raw.rawValue, depth: depth, visited: visited)

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
        if let error = any as? Error {
            return canonical(error: error as NSError, depth: depth, visited: visited)
        }
        guard depth < maxDepth else { return nil }
        if let object = any as? NSObject,
           let structured = objcObject(object, depth: depth, visited: visited) {
            return structured
        }
        return mirrorObject(any, depth: depth, visited: visited)
    }

    /// Returns an error as what a caller can branch on: its domain, its code, and its user info. Its
    /// description is derived text, and its KVC properties include categories that throw on read.
    ///
    /// - Parameters:
    ///   - error: The error, bridged — a Swift error's domain is its type, its code the case.
    ///   - depth: The current nesting depth.
    ///   - visited: The objects already on the path, so a cycle through user info terminates.
    /// - Returns: An `.object` keyed `domain`, `code`, and — when non-empty — `userInfo`.
    private static func canonical(
        error: NSError,
        depth: Int,
        visited: Set<ObjectIdentifier>
    ) -> CanonicalValue {
        var result: [String: CanonicalValue] = [
            "domain": .string(error.domain),
            "code": .int(Int64(error.code))
        ]
        if !error.userInfo.isEmpty, depth < maxDepth {
            result["userInfo"] = canonical(error.userInfo as [String: Any], depth: depth + 1, visited: visited)
        }
        return .object(result)
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

// MARK: - Pointers

/// A pointer, which ``RuntimeValue`` records as `"<pointer>"`. Its address differs between two runs
/// and between two implementations of the same behavior, so it is never compared.
private protocol Address {}

extension UnsafePointer: Address {}
extension UnsafeMutablePointer: Address {}
extension UnsafeRawPointer: Address {}
extension UnsafeMutableRawPointer: Address {}
extension OpaquePointer: Address {}
extension AutoreleasingUnsafeMutablePointer: Address {}

/// A buffer pointer, which ``RuntimeValue`` records by its count alone. The count is how much the
/// subject handed over; the start address is a pointer like any other.
private protocol BufferAddress {
    /// The number of elements, or of bytes for a raw buffer.
    var count: Int { get }
}

extension UnsafeBufferPointer: BufferAddress {}
extension UnsafeMutableBufferPointer: BufferAddress {}
extension UnsafeRawBufferPointer: BufferAddress {}
extension UnsafeMutableRawBufferPointer: BufferAddress {}
