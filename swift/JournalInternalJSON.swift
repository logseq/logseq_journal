import Foundation

/// Owned JSON uses synthesized CodingKeys as its closed schema, recursively.
/// External service readers continue using their ordinary JSONDecoder.
enum JournalInternalJSON {
  static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    let decoder = JSONDecoder()
    if type == Data.self || type == Date.self || type == URL.self || type == Decimal.self {
      return try decoder.decode(type, from: data)
    }
    return try decoder.decode(OwnedValue<Value>.self, from: data).value
  }
}

private struct AnyField: CodingKey {
  let stringValue: String
  let intValue: Int?
  init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
  init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

private struct OwnedValue<Value: Decodable>: Decodable {
  let value: Value
  init(from decoder: Decoder) throws { value = try Value(from: OwnedDecoder(base: decoder)) }
}

private struct OwnedDecoder: Decoder {
  let base: Decoder
  var codingPath: [CodingKey] { base.codingPath }
  var userInfo: [CodingUserInfoKey: Any] { base.userInfo }

  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    let fields = try base.container(keyedBy: AnyField.self).allKeys
    guard fields.allSatisfy({ Key(stringValue: $0.stringValue) != nil }) else {
      throw DecodingError.dataCorrupted(.init(codingPath: codingPath,
        debugDescription: "Unexpected field in owned JSON object"))
    }
    return KeyedDecodingContainer(OwnedKeyed(base: try base.container(keyedBy: type)))
  }
  func unkeyedContainer() throws -> UnkeyedDecodingContainer {
    OwnedUnkeyed(base: try base.unkeyedContainer())
  }
  func singleValueContainer() throws -> SingleValueDecodingContainer {
    OwnedSingle(base: try base.singleValueContainer(), decoder: self)
  }
}

private struct OwnedKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
  let base: KeyedDecodingContainer<Key>
  var codingPath: [CodingKey] { base.codingPath }
  var allKeys: [Key] { base.allKeys }
  func contains(_ key: Key) -> Bool { base.contains(key) }
  func decodeNil(forKey key: Key) throws -> Bool { try base.decodeNil(forKey: key) }
  func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try base.decode(type, forKey: key) }
  func decode(_ type: String.Type, forKey key: Key) throws -> String { try base.decode(type, forKey: key) }
  func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try base.decode(type, forKey: key) }
  func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try base.decode(type, forKey: key) }
  func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try base.decode(type, forKey: key) }
  func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try base.decode(type, forKey: key) }
  func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try base.decode(type, forKey: key) }
  func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try base.decode(type, forKey: key) }
  func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try base.decode(type, forKey: key) }
  func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try base.decode(type, forKey: key) }
  func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try base.decode(type, forKey: key) }
  func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try base.decode(type, forKey: key) }
  func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try base.decode(type, forKey: key) }
  func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try base.decode(type, forKey: key) }
  func decode<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value {
    // Preserve Foundation's specialized value decoding (not record schemas).
    if type == Data.self || type == Date.self || type == URL.self || type == Decimal.self {
      return try base.decode(type, forKey: key)
    }
    return try base.decode(OwnedValue<Value>.self, forKey: key).value
  }
  func nestedContainer<Nested: CodingKey>(keyedBy type: Nested.Type, forKey key: Key) throws -> KeyedDecodingContainer<Nested> {
    try OwnedDecoder(base: base.superDecoder(forKey: key)).container(keyedBy: type)
  }
  func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
    try OwnedDecoder(base: base.superDecoder(forKey: key)).unkeyedContainer()
  }
  func superDecoder() throws -> Decoder { OwnedDecoder(base: try base.superDecoder()) }
  func superDecoder(forKey key: Key) throws -> Decoder { OwnedDecoder(base: try base.superDecoder(forKey: key)) }
}

private struct OwnedUnkeyed: UnkeyedDecodingContainer {
  var base: UnkeyedDecodingContainer
  var codingPath: [CodingKey] { base.codingPath }
  var count: Int? { base.count }
  var isAtEnd: Bool { base.isAtEnd }
  var currentIndex: Int { base.currentIndex }
  mutating func decodeNil() throws -> Bool { try base.decodeNil() }
  mutating func decode(_ type: Bool.Type) throws -> Bool { try base.decode(type) }
  mutating func decode(_ type: String.Type) throws -> String { try base.decode(type) }
  mutating func decode(_ type: Double.Type) throws -> Double { try base.decode(type) }
  mutating func decode(_ type: Float.Type) throws -> Float { try base.decode(type) }
  mutating func decode(_ type: Int.Type) throws -> Int { try base.decode(type) }
  mutating func decode(_ type: Int8.Type) throws -> Int8 { try base.decode(type) }
  mutating func decode(_ type: Int16.Type) throws -> Int16 { try base.decode(type) }
  mutating func decode(_ type: Int32.Type) throws -> Int32 { try base.decode(type) }
  mutating func decode(_ type: Int64.Type) throws -> Int64 { try base.decode(type) }
  mutating func decode(_ type: UInt.Type) throws -> UInt { try base.decode(type) }
  mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try base.decode(type) }
  mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try base.decode(type) }
  mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try base.decode(type) }
  mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try base.decode(type) }
  mutating func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
    if type == Data.self || type == Date.self || type == URL.self || type == Decimal.self {
      return try base.decode(type)
    }
    return try base.decode(OwnedValue<Value>.self).value
  }
  mutating func nestedContainer<Nested: CodingKey>(keyedBy type: Nested.Type) throws -> KeyedDecodingContainer<Nested> {
    try OwnedDecoder(base: base.superDecoder()).container(keyedBy: type)
  }
  mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
    try OwnedDecoder(base: base.superDecoder()).unkeyedContainer()
  }
  mutating func superDecoder() throws -> Decoder { OwnedDecoder(base: try base.superDecoder()) }
}

private struct OwnedSingle: SingleValueDecodingContainer {
  let base: SingleValueDecodingContainer
  let decoder: OwnedDecoder
  var codingPath: [CodingKey] { base.codingPath }
  func decodeNil() -> Bool { base.decodeNil() }
  func decode(_ type: Bool.Type) throws -> Bool { try base.decode(type) }
  func decode(_ type: String.Type) throws -> String { try base.decode(type) }
  func decode(_ type: Double.Type) throws -> Double { try base.decode(type) }
  func decode(_ type: Float.Type) throws -> Float { try base.decode(type) }
  func decode(_ type: Int.Type) throws -> Int { try base.decode(type) }
  func decode(_ type: Int8.Type) throws -> Int8 { try base.decode(type) }
  func decode(_ type: Int16.Type) throws -> Int16 { try base.decode(type) }
  func decode(_ type: Int32.Type) throws -> Int32 { try base.decode(type) }
  func decode(_ type: Int64.Type) throws -> Int64 { try base.decode(type) }
  func decode(_ type: UInt.Type) throws -> UInt { try base.decode(type) }
  func decode(_ type: UInt8.Type) throws -> UInt8 { try base.decode(type) }
  func decode(_ type: UInt16.Type) throws -> UInt16 { try base.decode(type) }
  func decode(_ type: UInt32.Type) throws -> UInt32 { try base.decode(type) }
  func decode(_ type: UInt64.Type) throws -> UInt64 { try base.decode(type) }
  func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
    if type == Data.self || type == Date.self || type == URL.self || type == Decimal.self {
      return try base.decode(type)
    }
    return try Value(from: decoder)
  }
}
