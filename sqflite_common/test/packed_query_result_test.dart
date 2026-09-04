import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite_common/src/collection_utils.dart';
import 'package:sqflite_common/src/packed_query_result.dart';
import 'package:test/test.dart';

void main() {
  group('packed query result', () {
    test('decodes every supported value type with query map semantics', () {
      const minimumInt64 = -9223372036854775807 - 1;
      const maximumInt64 = 9223372036854775807;
      final bytes = _encodeResult(
        <String>['null', 'int', 'double', 'text', 'blob', 'bool', 'floats'],
        <List<Object?>>[
          <Object?>[
            null,
            minimumInt64,
            1.25,
            '鸿蒙 / Zotero 📚',
            Uint8List(0),
            true,
            Float32List.fromList(<double>[3.5, -1.25]),
          ],
          <Object?>[
            null,
            maximumInt64,
            -2.5,
            '',
            Uint8List.fromList(<int>[0, 127, 255]),
            false,
            Float32List(0),
          ],
        ],
      );

      final result = queryResultToList(bytes);

      expect(result, hasLength(2));
      expect(result.first['null'], isNull);
      expect(result.first['int'], minimumInt64);
      expect(result.first['double'], 1.25);
      expect(result.first['text'], '鸿蒙 / Zotero 📚');
      expect(result.first['blob'], Uint8List(0));
      expect(result.first['bool'], isTrue);
      expect(
        result.first['floats'],
        Float32List.fromList(<double>[3.5, -1.25]),
      );
      expect(result.last['int'], maximumInt64);
      expect(result.last['blob'], Uint8List.fromList(<int>[0, 127, 255]));
      expect(result.last['bool'], isFalse);
    });

    test('decodes an empty result', () {
      final result = decodePackedQueryResult(
        _encodeResult(<String>[], <List<Object?>>[]),
      );

      expect(result.columns, isEmpty);
      expect(result.rows, isEmpty);
    });

    test('decodes the single-UTF8-pass scalar transport', () {
      final bytes = _encodeJsonResult(
        <String>['id', 'title', 'rating', 'deleted'],
        <List<Object?>>[
          <Object?>[1, '鸿蒙文献', 4.5, false],
          <Object?>[2, 'Zotero', null, true],
        ],
      );

      expect(queryResultToList(bytes), <Map<String, Object?>>[
        <String, Object?>{
          'id': 1,
          'title': '鸿蒙文献',
          'rating': 4.5,
          'deleted': false,
        },
        <String, Object?>{
          'id': 2,
          'title': 'Zotero',
          'rating': null,
          'deleted': true,
        },
      ]);
    });

    test('rejects invalid header fields', () {
      expect(
        () => decodePackedQueryResult(Uint8List(23)),
        throwsFormatException,
      );
      expect(
        () => decodePackedQueryResult(
          _mutate(_encodeResult(<String>[], <List<Object?>>[]), 0, 0),
        ),
        throwsFormatException,
      );
      expect(
        () => decodePackedQueryResult(
          _mutate(_encodeResult(<String>[], <List<Object?>>[]), 4, 2),
        ),
        throwsFormatException,
      );
      expect(
        () => decodePackedQueryResult(
          _mutate(_encodeResult(<String>[], <List<Object?>>[]), 5, 2),
        ),
        throwsFormatException,
      );
      expect(
        () => decodePackedQueryResult(
          _mutate(_encodeResult(<String>[], <List<Object?>>[]), 20, 23),
        ),
        throwsFormatException,
      );
    });

    test('rejects invalid dimensions before allocating rows', () {
      final mismatchedCellCount = _encodeResult(
        <String>['value'],
        <List<Object?>>[
          <Object?>[null],
        ],
      );
      ByteData.sublistView(mismatchedCellCount).setUint32(16, 2, Endian.little);

      final impossibleRows = _encodeResult(<String>[], <List<Object?>>[]);
      ByteData.sublistView(
        impossibleRows,
      ).setUint32(12, 0xffffffff, Endian.little);

      expect(
        () => decodePackedQueryResult(mismatchedCellCount),
        throwsFormatException,
      );
      expect(
        () => decodePackedQueryResult(impossibleRows),
        throwsFormatException,
      );
    });

    test('rejects truncated and trailing payloads', () {
      final valid = _encodeResult(
        <String>['value'],
        <List<Object?>>[
          <Object?>['text'],
        ],
      );
      final truncated = Uint8List.fromList(valid.sublist(0, valid.length - 1));
      ByteData.sublistView(
        truncated,
      ).setUint32(20, truncated.length, Endian.little);

      final trailing = Uint8List.fromList(<int>[...valid, 0]);
      ByteData.sublistView(
        trailing,
      ).setUint32(20, trailing.length, Endian.little);

      expect(() => decodePackedQueryResult(truncated), throwsFormatException);
      expect(() => decodePackedQueryResult(trailing), throwsFormatException);
    });

    test('rejects invalid value tags and booleans', () {
      final invalidTag = _encodeResult(
        <String>['value'],
        <List<Object?>>[
          <Object?>[null],
        ],
      );
      invalidTag[33] = 255;

      final invalidBoolean = _encodeResult(
        <String>['value'],
        <List<Object?>>[
          <Object?>[true],
        ],
      );
      invalidBoolean[34] = 2;

      expect(() => decodePackedQueryResult(invalidTag), throwsFormatException);
      expect(
        () => decodePackedQueryResult(invalidBoolean),
        throwsFormatException,
      );
    });

    test('rejects invalid JSON scalar shapes and values', () {
      final mismatchedRows = _encodeJsonResult(
        <String>['value'],
        <List<Object?>>[
          <Object?>[1],
        ],
      );
      final mismatchedData = ByteData.sublistView(mismatchedRows);
      mismatchedData.setUint32(12, 2, Endian.little);
      mismatchedData.setUint32(16, 2, Endian.little);

      final nestedValue = _encodeJsonResult(
        <String>['value'],
        <List<Object?>>[
          <Object?>[
            <String, bool>{'nested': true}
          ],
        ],
      );

      expect(
        () => decodePackedQueryResult(mismatchedRows),
        throwsFormatException,
      );
      expect(
        () => decodePackedQueryResult(nestedValue),
        throwsFormatException,
      );
    });
  });
}

Uint8List _encodeResult(List<String> columns, List<List<Object?>> rows) {
  final payload = BytesBuilder(copy: false);
  for (final column in columns) {
    _writeBytes(payload, utf8.encode(column));
  }
  for (final row in rows) {
    if (row.length != columns.length) {
      throw ArgumentError('Each row must match the column count');
    }
    for (final value in row) {
      _writeValue(payload, value);
    }
  }

  final payloadBytes = payload.takeBytes();
  final bytes = Uint8List(24 + payloadBytes.length);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0x31514653, Endian.little);
  data.setUint8(4, 1);
  data.setUint32(8, columns.length, Endian.little);
  data.setUint32(12, rows.length, Endian.little);
  data.setUint32(16, columns.length * rows.length, Endian.little);
  data.setUint32(20, bytes.length, Endian.little);
  bytes.setRange(24, bytes.length, payloadBytes);
  return bytes;
}

Uint8List _encodeJsonResult(
  List<String> columns,
  List<List<Object?>> rows,
) {
  final payload = utf8.encode(jsonEncode(<Object?>[columns, rows]));
  final bytes = Uint8List(24 + payload.length);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0x31514653, Endian.little);
  data.setUint8(4, 1);
  data.setUint8(5, 1);
  data.setUint32(8, columns.length, Endian.little);
  data.setUint32(12, rows.length, Endian.little);
  data.setUint32(16, columns.length * rows.length, Endian.little);
  data.setUint32(20, bytes.length, Endian.little);
  bytes.setRange(24, bytes.length, payload);
  return bytes;
}

void _writeValue(BytesBuilder builder, Object? value) {
  if (value == null) {
    builder.addByte(0);
  } else if (value is int) {
    builder.addByte(1);
    _writeInt64(builder, value);
  } else if (value is double) {
    builder.addByte(2);
    _writeFloat64(builder, value);
  } else if (value is String) {
    builder.addByte(3);
    _writeBytes(builder, utf8.encode(value));
  } else if (value is Uint8List) {
    builder.addByte(4);
    _writeBytes(builder, value);
  } else if (value is bool) {
    builder.addByte(5);
    builder.addByte(value ? 1 : 0);
  } else if (value is Float32List) {
    builder.addByte(6);
    _writeUint32(builder, value.length);
    for (final element in value) {
      _writeFloat32(builder, element);
    }
  } else {
    throw ArgumentError.value(value, 'value', 'Unsupported packed type');
  }
}

void _writeBytes(BytesBuilder builder, List<int> bytes) {
  _writeUint32(builder, bytes.length);
  builder.add(bytes);
}

void _writeUint32(BytesBuilder builder, int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.little);
  builder.add(data.buffer.asUint8List());
}

void _writeInt64(BytesBuilder builder, int value) {
  final data = ByteData(8)..setInt64(0, value, Endian.little);
  builder.add(data.buffer.asUint8List());
}

void _writeFloat64(BytesBuilder builder, double value) {
  final data = ByteData(8)..setFloat64(0, value, Endian.little);
  builder.add(data.buffer.asUint8List());
}

void _writeFloat32(BytesBuilder builder, double value) {
  final data = ByteData(4)..setFloat32(0, value, Endian.little);
  builder.add(data.buffer.asUint8List());
}

Uint8List _mutate(Uint8List source, int index, int value) {
  final mutated = Uint8List.fromList(source);
  mutated[index] = value;
  return mutated;
}
