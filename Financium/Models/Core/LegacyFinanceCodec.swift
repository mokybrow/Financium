import Foundation

/// Compatibility at the storage boundary only. CloudKit keeps its existing
/// payload format so an older participant can still edit a shared account.
/// Native models and the new local archive use Codable, without a runtime
/// package or generated messages. This implements only the field kinds in our
/// saved schema, retaining unknown fields verbatim for round-trip safety.
nonisolated protocol LegacyFinanceRecord: Codable {
    init()
    var legacyUnknownFields: Data { get set }
    static var legacyFields: [LegacyFinanceField<Self>] { get }
}

nonisolated enum LegacyFinanceCodec {
    enum Failure: Error { case malformedPayload }

    static func decode<T: LegacyFinanceRecord>(_ type: T.Type, from data: Data) throws -> T {
        var result = T()
        var reader = Reader(bytes: Array(data))
        let fields = T.legacyFields
        while reader.offset < reader.bytes.count {
            let start = reader.offset
            let tag = try reader.varint()
            let number = tag >> 3
            guard number > 0, number < (1 << 29) else { throw Failure.malformedPayload }
            let value = try reader.value(tag: tag, depth: 0)
            if let field = fields.first(where: { $0.number == Int(number) }) {
                try field.read(&result, value)
            } else {
                result.legacyUnknownFields.append(contentsOf: reader.bytes[start..<reader.offset])
            }
        }
        return result
    }

    static func encode<T: LegacyFinanceRecord>(_ value: T) -> Data {
        var writer = Writer()
        for field in T.legacyFields { field.write(value, &writer) }
        writer.data.append(value.legacyUnknownFields)
        return writer.data
    }

    enum Value {
        case integer(UInt64)
        case bytes(Data)
        case unknown

        func integer() throws -> UInt64 {
            guard case .integer(let value) = self else { throw Failure.malformedPayload }
            return value
        }

        func bytes() throws -> Data {
            guard case .bytes(let value) = self else { throw Failure.malformedPayload }
            return value
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw Failure.malformedPayload }
                let byte = bytes[offset]
                offset += 1
                guard index < 9 || byte <= 1 else { throw Failure.malformedPayload }
                value |= UInt64(byte & 0x7f) << (7 * index)
                if byte < 0x80 { return value }
            }
            throw Failure.malformedPayload
        }

        mutating func consume(_ count: Int) throws -> Data {
            guard count >= 0, count <= bytes.count - offset else { throw Failure.malformedPayload }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }

        mutating func value(tag: UInt64, depth: Int) throws -> Value {
            guard depth < 64, tag >> 3 > 0, tag >> 3 < (1 << 29) else {
                throw Failure.malformedPayload
            }
            switch tag & 7 {
            case 0:
                return .integer(try varint())
            case 1:
                _ = try consume(8)
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count - offset) else { throw Failure.malformedPayload }
                return .bytes(try consume(Int(length)))
            case 3:
                // Groups are not part of our schema, but a future/legacy field
                // can contain one. Bound nesting and validate the closing tag.
                while true {
                    let nested = try varint()
                    if nested & 7 == 4 {
                        guard nested >> 3 == tag >> 3 else { throw Failure.malformedPayload }
                        break
                    }
                    _ = try value(tag: nested, depth: depth + 1)
                }
            case 5:
                _ = try consume(4)
            default:
                throw Failure.malformedPayload
            }
            return .unknown
        }
    }

    struct Writer {
        var data = Data()

        mutating func varint(_ input: UInt64) {
            var value = input
            while value >= 0x80 {
                data.append(UInt8(value & 0x7f) | 0x80)
                value >>= 7
            }
            data.append(UInt8(value))
        }

        mutating func integer(_ number: Int, _ value: UInt64) {
            guard value != 0 else { return }
            varint(UInt64(number) << 3)
            varint(value)
        }

        mutating func bytes(_ number: Int, _ value: Data) {
            varint(UInt64(number) << 3 | 2)
            varint(UInt64(value.count))
            data.append(value)
        }
    }
}

/// Typed field access keeps legacy numbering out of the native model structs.
nonisolated struct LegacyFinanceField<Model> {
    let number: Int
    let read: (inout Model, LegacyFinanceCodec.Value) throws -> Void
    let write: (Model, inout LegacyFinanceCodec.Writer) -> Void

    static func string(_ number: Int, _ key: WritableKeyPath<Model, String>) -> Self {
        Self(number: number, read: { model, value in
            guard let text = String(data: try value.bytes(), encoding: .utf8) else {
                throw LegacyFinanceCodec.Failure.malformedPayload
            }
            model[keyPath: key] = text
        }, write: { model, writer in
            let text = model[keyPath: key]
            if !text.isEmpty { writer.bytes(number, Data(text.utf8)) }
        })
    }

    static func int64(_ number: Int, _ key: WritableKeyPath<Model, Int64>) -> Self {
        Self(number: number, read: { model, value in
            model[keyPath: key] = Int64(bitPattern: try value.integer())
        }, write: { model, writer in
            writer.integer(number, UInt64(bitPattern: model[keyPath: key]))
        })
    }

    static func int32(_ number: Int, _ key: WritableKeyPath<Model, Int32>) -> Self {
        Self(number: number, read: { model, value in
            model[keyPath: key] = Int32(truncatingIfNeeded: try value.integer())
        }, write: { model, writer in
            writer.integer(number, UInt64(bitPattern: Int64(model[keyPath: key])))
        })
    }

    static func bool(_ number: Int, _ key: WritableKeyPath<Model, Bool>) -> Self {
        Self(number: number, read: { model, value in
            model[keyPath: key] = try value.integer() != 0
        }, write: { model, writer in
            writer.integer(number, model[keyPath: key] ? 1 : 0)
        })
    }

    static func enumeration<E: RawRepresentable>(
        _ number: Int, _ key: WritableKeyPath<Model, E>
    ) -> Self where E.RawValue == Int {
        Self(number: number, read: { model, value in
            let raw = Int(Int32(truncatingIfNeeded: try value.integer()))
            guard let decoded = E(rawValue: raw) else { throw LegacyFinanceCodec.Failure.malformedPayload }
            model[keyPath: key] = decoded
        }, write: { model, writer in
            writer.integer(number, UInt64(bitPattern: Int64(model[keyPath: key].rawValue)))
        })
    }

    static func message<T: LegacyFinanceRecord>(
        _ number: Int, _ key: WritableKeyPath<Model, T?>
    ) -> Self {
        Self(number: number, read: { model, value in
            // Repeated singular message fields merge instead of replacing the
            // earlier fields. Scalar fields within the merge remain last-wins.
            var data = model[keyPath: key].map { LegacyFinanceCodec.encode($0) } ?? Data()
            data.append(try value.bytes())
            model[keyPath: key] = try LegacyFinanceCodec.decode(T.self, from: data)
        }, write: { model, writer in
            if let value = model[keyPath: key] {
                writer.bytes(number, LegacyFinanceCodec.encode(value))
            }
        })
    }
}
