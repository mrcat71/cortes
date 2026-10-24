import Foundation

/// Minimal JSON value that keeps object key order. Grammar-constrained decoding emits properties in the
/// schema's order, and the order matters: scores must come after the text they judge.
indirect enum OrderedJSON {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case int(Int)

    var serialized: String {
        switch self {
        case .object(let pairs):
            "{" + pairs.map { "\(Self.quote($0.0)):\($0.1.serialized)" }.joined(separator: ",") + "}"
        case .array(let items):
            "[" + items.map(\.serialized).joined(separator: ",") + "]"
        case .string(let value):
            Self.quote(value)
        case .int(let value):
            String(value)
        }
    }

    static func quote(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let quoted = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return quoted
    }
}

/// JSON schema for one batch, built from the enabled voices: each voice may only use its own strategies.
public enum SchemaBuilder {
    public static func schema(voices: [VoiceDefinition]) -> String {
        let score = OrderedJSON.object([("type", .string("integer")), ("minimum", .int(0)), ("maximum", .int(9))])
        func text(_ maxLength: Int) -> OrderedJSON {
            .object([("type", .string("string")), ("maxLength", .int(maxLength))])
        }
        func choice(_ values: [String]) -> OrderedJSON {
            .object([("type", .string("string")), ("enum", .array(values.map(OrderedJSON.string)))])
        }
        func object(_ properties: [(String, OrderedJSON)]) -> OrderedJSON {
            .object([
                ("type", .string("object")),
                ("properties", .object(properties)),
                ("required", .array(properties.map { .string($0.0) })),
            ])
        }

        let read = object([
            ("to_me", .object([("type", .string("boolean"))])),
            ("need", choice(["now", "soon", "no"])),
            ("tension", score),
            ("register", choice(["professional", "casual", "mixed"])),
            ("clarity", score),
            ("gist", text(100)),
        ])
        let takes = voices.map { voice in
            (voice.id, object([
                ("rel", score),
                ("strategy", choice(voice.strategies)),
                ("thought", text(160)),
                ("reply", text(240)),
                ("help", score),
                ("risk", score),
                ("fun", score),
            ]))
        }
        return object([("read", read), ("voices", object(takes))]).serialized
    }
}
