import 'dart:convert';
import 'dart:typed_data';

const int _packedQueryMagic = 0x31514653; // "SQF1" in little-endian order.
const int _packedQueryVersion = 1;
const int _packedQueryHeaderSize = 24;
const int _packedQueryFlagJsonScalars = 1;

const int _valueTypeNull = 0;
const int _valueTypeInteger = 1;
const int _valueTypeReal = 2;
const int _valueTypeText = 3;
const int _valueTypeBlob = 4;
const int _valueTypeBoolean = 5;
const int _valueTypeFloat32Array = 6;

/// Fully decoded rows from the versioned OHOS packed query transport.
class PackedQueryResult {
  /// Creates a packed query result.
  PackedQueryResult(this.columns, this.rows);

  /// Column names in SQL result order.
  final List<String> columns;

  /// Row values in the same shape used by the standard sqflite transport.
  final List<List<Object?>> rows;
}

/// Decodes a packed OHOS result and rejects truncated or version-mismatched data.
PackedQueryResult decodePackedQueryResult(Uint8List bytes) {
  final reader = _PackedQueryReader(bytes);
  if (reader.readUint32() != _packedQueryMagic) {
    throw const FormatException('Invalid packed sqflite query magic');
  }
  if (reader.readUint8() != _packedQueryVersion) {
    throw const FormatException('Unsupported packed sqflite query version');
  }
  final flags = reader.readUint8();
  if ((flags != 0 && flags != _packedQueryFlagJsonScalars) ||
      reader.readUint16() != 0) {
    throw const FormatException('Unsupported packed sqflite query flags');
  }

  final columnCount = reader.readUint32();
  final rowCount = reader.readUint32();
  final cellCount = reader.readUint32();
  final declaredLength = reader.readUint32();
  if (declaredLength != bytes.length ||
      cellCount != columnCount * rowCount ||
      (columnCount == 0 && rowCount != 0)) {
    throw const FormatException('Invalid packed sqflite query dimensions');
  }

  if (flags == _packedQueryFlagJsonScalars) {
    return _decodeJsonScalarResult(
      reader,
      columnCount: columnCount,
      rowCount: rowCount,
    );
  }

  // Validate the cheapest possible payload size before allocating lists from
  // counts supplied by the native side. Every column has a uint32 byte length,
  // and every cell has at least a one-byte type tag.
  final minimumPayloadLength = columnCount * 4 + cellCount;
  if (minimumPayloadLength > bytes.length - _packedQueryHeaderSize) {
    throw const FormatException('Invalid packed sqflite query dimensions');
  }
  final columns = List<String>.generate(
    columnCount,
    (_) => reader.readString(),
    growable: false,
  );
  final rows = List<List<Object?>>.generate(
    rowCount,
    (_) => List<Object?>.generate(
      columnCount,
      (_) => reader.readValue(),
      growable: false,
    ),
    growable: false,
  );
  reader.requireEnd();
  return PackedQueryResult(columns, rows);
}

PackedQueryResult _decodeJsonScalarResult(
  _PackedQueryReader reader, {
  required int columnCount,
  required int rowCount,
}) {
  final dynamic decoded = jsonDecode(reader.readRemainingString());
  if (decoded is! List || decoded.length != 2) {
    throw const FormatException('Invalid packed sqflite JSON result');
  }
  final dynamic rawColumns = decoded[0];
  final dynamic rawRows = decoded[1];
  if (rawColumns is! List ||
      rawRows is! List ||
      rawColumns.length != columnCount ||
      rawRows.length != rowCount) {
    throw const FormatException('Invalid packed sqflite JSON dimensions');
  }

  final columns = List<String>.generate(columnCount, (index) {
    final dynamic column = rawColumns[index];
    if (column is! String) {
      throw const FormatException('Invalid packed sqflite JSON column');
    }
    return column;
  }, growable: false);
  final rows = List<List<Object?>>.generate(rowCount, (rowIndex) {
    final dynamic rawRow = rawRows[rowIndex];
    if (rawRow is! List || rawRow.length != columnCount) {
      throw const FormatException('Invalid packed sqflite JSON row');
    }
    return List<Object?>.generate(columnCount, (columnIndex) {
      final dynamic value = rawRow[columnIndex];
      if (value != null &&
          value is! bool &&
          value is! num &&
          value is! String) {
        throw const FormatException('Invalid packed sqflite JSON value');
      }
      return value;
    }, growable: false);
  }, growable: false);
  return PackedQueryResult(columns, rows);
}

class _PackedQueryReader {
  _PackedQueryReader(this.bytes) : data = ByteData.sublistView(bytes) {
    if (bytes.length < _packedQueryHeaderSize) {
      throw const FormatException('Truncated packed sqflite query header');
    }
  }

  final Uint8List bytes;
  final ByteData data;
  int offset = 0;

  int readUint8() {
    _requireBytes(1);
    return data.getUint8(offset++);
  }

  int readUint16() {
    _requireBytes(2);
    final value = data.getUint16(offset, Endian.little);
    offset += 2;
    return value;
  }

  int readUint32() {
    _requireBytes(4);
    final value = data.getUint32(offset, Endian.little);
    offset += 4;
    return value;
  }

  Object? readValue() {
    switch (readUint8()) {
      case _valueTypeNull:
        return null;
      case _valueTypeInteger:
        _requireBytes(8);
        final value = data.getInt64(offset, Endian.little);
        offset += 8;
        return value;
      case _valueTypeReal:
        _requireBytes(8);
        final value = data.getFloat64(offset, Endian.little);
        offset += 8;
        return value;
      case _valueTypeText:
        return readString();
      case _valueTypeBlob:
        final length = readUint32();
        _requireBytes(length);
        final value = Uint8List.fromList(
          Uint8List.sublistView(bytes, offset, offset + length),
        );
        offset += length;
        return value;
      case _valueTypeBoolean:
        final value = readUint8();
        if (value > 1) {
          throw const FormatException('Invalid packed sqflite boolean');
        }
        return value == 1;
      case _valueTypeFloat32Array:
        final length = readUint32();
        _requireBytes(length * 4);
        final value = Float32List(length);
        for (var index = 0; index < length; index++) {
          value[index] = data.getFloat32(offset, Endian.little);
          offset += 4;
        }
        return value;
      default:
        throw const FormatException('Unknown packed sqflite value type');
    }
  }

  String readString() {
    final length = readUint32();
    _requireBytes(length);
    final value = const Utf8Decoder().convert(bytes, offset, offset + length);
    offset += length;
    return value;
  }

  String readRemainingString() {
    final value = const Utf8Decoder().convert(bytes, offset, bytes.length);
    offset = bytes.length;
    return value;
  }

  void requireEnd() {
    if (offset != bytes.length) {
      throw const FormatException('Trailing packed sqflite query data');
    }
  }

  void _requireBytes(int length) {
    if (length < 0 || offset + length > bytes.length) {
      throw const FormatException('Truncated packed sqflite query data');
    }
  }
}
