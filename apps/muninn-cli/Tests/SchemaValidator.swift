import Foundation

// A JSON Schema validator for the subset `docs/cli-schemas/` uses: type,
// const, enum, properties, required, additionalProperties: false, items,
// minimum, pattern and $ref (to a file and/or a `#/$defs/...` pointer).
// Any other keyword fails loudly, so a schema can't use something this
// validator would silently ignore. Hand-written: no dependency (AGENTS.md rule 7).

struct SchemaValidator {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // muninn-cli
        .deletingLastPathComponent()      // apps
        .deletingLastPathComponent()      // repo root
        .appendingPathComponent("docs/cli-schemas")

    static let known: Set<String> = [
        "$schema", "$id", "title", "description", "$defs", "$ref", "type", "const", "enum",
        "properties", "required", "additionalProperties", "items", "minimum", "pattern", "format",
    ]

    private var files: [String: [String: Any]] = [:]

    func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.directory.appendingPathComponent(name))
        guard let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchemaError("\(name) isn't a JSON object")
        }
        return schema
    }

    /// Validates a JSON text against a schema file; returns every violation.
    mutating func validate(_ json: String, against file: String) throws -> [String] {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        var errors: [String] = []
        try check(value, try schema(file), file: file, path: "$", errors: &errors)
        return errors
    }

    private mutating func schema(_ file: String) throws -> [String: Any] {
        if let cached = files[file] { return cached }
        let loaded = try load(file)
        files[file] = loaded
        return loaded
    }

    private mutating func resolve(_ ref: String, from file: String) throws -> (schema: [String: Any], file: String) {
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let target = parts[0].isEmpty ? file : parts[0]
        var node: Any = try schema(target)
        if parts.count == 2 {
            for key in parts[1].split(separator: "/") {
                guard let next = (node as? [String: Any])?[String(key)] else {
                    throw SchemaError("unresolvable $ref \(ref) in \(file)")
                }
                node = next
            }
        }
        guard let resolved = node as? [String: Any] else { throw SchemaError("$ref \(ref) isn't a schema") }
        return (resolved, target)
    }

    private mutating func check(_ value: Any, _ schema: [String: Any], file: String, path: String, errors: inout [String]) throws {
        if let unknown = schema.keys.first(where: { !Self.known.contains($0) }) {
            throw SchemaError("unsupported keyword \(unknown) in \(file)")
        }
        if let ref = schema["$ref"] as? String {
            let (target, targetFile) = try resolve(ref, from: file)
            try check(value, target, file: targetFile, path: path, errors: &errors)
        }
        if let expected = schema["const"], !Self.equal(value, expected) {
            errors.append("\(path): expected \(expected), got \(value)")
        }
        if let options = schema["enum"] as? [Any], !options.contains(where: { Self.equal(value, $0) }) {
            errors.append("\(path): \(value) isn't one of \(options)")
        }
        if let type = schema["type"] as? String, !Self.matches(value, type) {
            errors.append("\(path): expected \(type), got \(Swift.type(of: value))")
            return
        }
        if let minimum = schema["minimum"] as? Double, let number = value as? NSNumber, number.doubleValue < minimum {
            errors.append("\(path): \(number) is below \(minimum)")
        }
        if let pattern = schema["pattern"] as? String, let string = value as? String,
           string.range(of: pattern, options: .regularExpression) == nil {
            errors.append("\(path): \"\(string)\" doesn't match \(pattern)")
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                errors.append("\(path): missing required \(key)")
            }
            for (key, child) in object {
                if let childSchema = properties[key] as? [String: Any] {
                    try check(child, childSchema, file: file, path: "\(path).\(key)", errors: &errors)
                } else if schema["additionalProperties"] as? Bool == false {
                    errors.append("\(path): undocumented key \(key)")
                }
            }
        }
        if let array = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (n, element) in array.enumerated() {
                try check(element, items, file: file, path: "\(path)[\(n)]", errors: &errors)
            }
        }
    }

    private static func isBool(_ value: Any) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }

    private static func matches(_ value: Any, _ type: String) -> Bool {
        switch type {
        case "object": value is [String: Any]
        case "array": value is [Any]
        case "string": value is String
        case "boolean": isBool(value)
        case "integer":
            if isBool(value) { false } else if let n = value as? NSNumber { n.doubleValue.rounded() == n.doubleValue } else { false }
        case "number": !isBool(value) && value is NSNumber
        case "null": value is NSNull
        default: false
        }
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? String, let b = b as? String { return a == b }
        if isBool(a) != isBool(b) { return false }
        if let a = a as? NSNumber, let b = b as? NSNumber { return a == b }
        return false
    }
}

struct SchemaError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
