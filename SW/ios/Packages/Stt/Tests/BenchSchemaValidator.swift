import Foundation
import CoreFoundation

/// Offline test helper for the JSON Schema keywords used by the STT export contract.
/// Reads the authoritative schema; external brain/tool references are deliberately unsupported.
/// No Python, uv, package installation or network is needed for benchmark export validation.
struct BenchSchemaValidator {
    let root: [String: Any]
    enum Invalid: Error { case value, unsupportedReference }
    static func repositorySchema() throws -> BenchSchemaValidator {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 { directory.deleteLastPathComponent() }
        return BenchSchemaValidator(root: try JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("SW/bench/schemas/run.schema.json"))) as! [String: Any])
    }
    func validate(_ data: Data) throws {
        try check(JSONSerialization.jsonObject(with: data), schema: root)
    }
    private func check(_ value: Any, schema: [String: Any]) throws {
        func require(_ condition: Bool) throws { if !condition { throw Invalid.value } }
        func equal(_ a: Any, _ b: Any) -> Bool {
            if let a = a as? NSNumber, let b = b as? NSNumber {
                let aBool = CFGetTypeID(a) == CFBooleanGetTypeID()
                let bBool = CFGetTypeID(b) == CFBooleanGetTypeID()
                guard aBool == bBool else { return false }
                return aBool ? a.boolValue == b.boolValue : a.doubleValue == b.doubleValue
            }
            if let a = a as? String, let b = b as? String { return a == b }
            return NSDictionary(dictionary: ["value": a]).isEqual(to: ["value": b])
        }
        if let ref = schema["$ref"] as? String {
            guard ref.hasPrefix("#/") else { throw Invalid.unsupportedReference }
            var target: Any = root
            for component in ref.dropFirst(2).split(separator: "/") {
                guard let next = (target as? [String: Any])?[String(component)] else { throw Invalid.unsupportedReference }
                target = next
            }
            guard let target = target as? [String: Any] else { throw Invalid.unsupportedReference }
            try check(value, schema: target)
        }
        if let expected = schema["const"] { try require(equal(value, expected)) }
        if let options = schema["enum"] as? [Any] { try require(options.contains { equal(value, $0) }) }
        let number = value as? NSNumber
        let boolean = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        if let type = schema["type"] as? String {
            switch type {
            case "object": try require(value is [String: Any])
            case "array": try require(value is [Any])
            case "string": try require(value is String)
            case "boolean": try require(boolean)
            case "number": try require(number != nil && !boolean)
            default: throw Invalid.value
            }
        }
        if let text = value as? String {
            if let minimum = schema["minLength"] as? Int { try require(text.count >= minimum) }
            if let pattern = schema["pattern"] as? String { try require(text.range(of: pattern, options: .regularExpression) != nil) }
        }
        if let number, !boolean {
            try require(number.doubleValue.isFinite)
            if let minimum = schema["minimum"] as? Double { try require(number.doubleValue >= minimum) }
            if let maximum = schema["maximum"] as? Double { try require(number.doubleValue <= maximum) }
            if let minimum = schema["exclusiveMinimum"] as? Double { try require(number.doubleValue > minimum) }
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for key in schema["required"] as? [String] ?? [] { try require(object[key] != nil) }
            if schema["additionalProperties"] as? Bool == false { try require(Set(object.keys).isSubset(of: Set(properties.keys))) }
            for (key, field) in properties {
                if let item = object[key] { try check(item, schema: field) }
            }
        }
        if let array = value as? [Any] {
            if let minimum = schema["minItems"] as? Int { try require(array.count >= minimum) }
            if schema["uniqueItems"] as? Bool == true {
                for i in array.indices { try require(!array[..<i].contains { equal(array[i], $0) }) }
            }
            if let items = schema["items"] as? [String: Any] {
                for item in array { try check(item, schema: items) }
            }
        }
        for rule in schema["allOf"] as? [[String: Any]] ?? [] { try check(value, schema: rule) }
        if let condition = schema["if"] as? [String: Any], (try? check(value, schema: condition)) != nil,
           let then = schema["then"] as? [String: Any] { try check(value, schema: then) }
    }
}
