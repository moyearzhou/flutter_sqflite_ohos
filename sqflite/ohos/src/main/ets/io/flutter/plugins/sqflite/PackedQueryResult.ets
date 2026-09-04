/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import { Any } from '@ohos/flutter_ohos';
import { ByteBuffer } from '@ohos/flutter_ohos/src/main/ets/util/ByteBuffer';
import StringUtils from '@ohos/flutter_ohos/src/main/ets/util/StringUtils';
import { Constant } from './OhosConstant';

enum PackedValueType {
  NULL = 0,
  INTEGER = 1,
  REAL = 2,
  TEXT = 3,
  BLOB = 4,
  BOOLEAN = 5,
  FLOAT32_ARRAY = 6
}

export class PackedQueryResult {
  private static readonly MAGIC: number = 0x31514653; // "SQF1" in little-endian order.
  private static readonly VERSION: number = 1;
  private static readonly HEADER_SIZE: number = 24;
  private static readonly DECLARED_LENGTH_OFFSET: number = 20;
  private static readonly FLAG_JSON_SCALARS: number = 1;
  private static readonly MAX_INITIAL_CAPACITY: number = 16 * 1024 * 1024;
  private static readonly MIN_INT64: bigint = -9223372036854775808n;
  private static readonly MAX_INT64: bigint = 9223372036854775807n;

  /**
   * Encodes the existing sqflite row matrix as one typed byte array. Returning
   * null is intentional: the caller must then send the untouched map result.
   */
  static tryEncode(results: Map<String, object>): Uint8Array | null {
    try {
      return PackedQueryResult.encode(results);
    } catch (error) {
      // Packing is an optimization only. Allocation, conversion and future
      // value-type failures must never turn a successful query into an error.
      return null;
    }
  }

  private static encode(results: Map<String, object>): Uint8Array | null {
    let rawColumns: Any = results.get(Constant.PARAM_COLUMNS);
    let rawRows: Any = results.get(Constant.PARAM_ROWS);
    if (!(rawColumns instanceof Array) || !(rawRows instanceof Array)) {
      return null;
    }

    const columns: Array<string> = rawColumns as Array<string>;
    const rows: Array<Array<Object>> = rawRows as Array<Array<Object>>;
    const cellCount: number = columns.length * rows.length;
    const jsonResult: Uint8Array | null =
      PackedQueryResult.tryEncodeJsonScalars(columns, rows, cellCount);
    if (jsonResult != null) {
      return jsonResult;
    }

    const estimatedCapacity: number = PackedQueryResult.HEADER_SIZE + cellCount * 12;
    const initialCapacity: number = Math.max(1024,
      Math.min(estimatedCapacity, PackedQueryResult.MAX_INITIAL_CAPACITY));
    const stream: ByteBuffer = ByteBuffer.from(new ArrayBuffer(initialCapacity));

    stream.writeUint32(PackedQueryResult.MAGIC, true);
    stream.writeUint8(PackedQueryResult.VERSION);
    stream.writeUint8(0); // Flags reserved for future protocol changes.
    stream.writeUint16(0, true);
    stream.writeUint32(columns.length, true);
    stream.writeUint32(rows.length, true);
    stream.writeUint32(cellCount, true);
    stream.writeUint32(0, true); // Filled after all variable-width values are written.

    for (let columnIndex = 0; columnIndex < columns.length; columnIndex++) {
      if (typeof columns[columnIndex] !== 'string') {
        return null;
      }
      PackedQueryResult.writeBytes(stream,
        new Uint8Array(StringUtils.stringToArrayBuffer(columns[columnIndex])));
    }

    for (let rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      const row: Any = rows[rowIndex];
      if (!(row instanceof Array) || row.length !== columns.length) {
        return null;
      }
      for (let columnIndex = 0; columnIndex < columns.length; columnIndex++) {
        if (!PackedQueryResult.writeValue(stream, row[columnIndex])) {
          return null;
        }
      }
    }

    stream.setUint32(PackedQueryResult.DECLARED_LENGTH_OFFSET, stream.byteOffset, true);
    return new Uint8Array(stream.buffer);
  }

  /**
   * Most SQLite query results contain only scalar values. Encoding their whole
   * matrix once avoids hundreds of thousands of native UTF-8 conversion calls.
   * Typed values deliberately return null and keep the lossless binary path.
   */
  private static tryEncodeJsonScalars(columns: Array<string>, rows: Array<Array<Object>>,
    cellCount: number): Uint8Array | null {
    for (let columnIndex = 0; columnIndex < columns.length; columnIndex++) {
      if (typeof columns[columnIndex] !== 'string') {
        return null;
      }
    }
    for (let rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      const row: Any = rows[rowIndex];
      if (!(row instanceof Array) || row.length !== columns.length) {
        return null;
      }
      for (let columnIndex = 0; columnIndex < columns.length; columnIndex++) {
        if (!PackedQueryResult.isJsonScalar(row[columnIndex])) {
          return null;
        }
      }
    }

    const json: string = JSON.stringify([columns, rows]);
    const payload: Uint8Array = new Uint8Array(StringUtils.stringToArrayBuffer(json));
    const buffer: ArrayBuffer = new ArrayBuffer(PackedQueryResult.HEADER_SIZE + payload.length);
    const view: DataView = new DataView(buffer);
    view.setUint32(0, PackedQueryResult.MAGIC, true);
    view.setUint8(4, PackedQueryResult.VERSION);
    view.setUint8(5, PackedQueryResult.FLAG_JSON_SCALARS);
    view.setUint16(6, 0, true);
    view.setUint32(8, columns.length, true);
    view.setUint32(12, rows.length, true);
    view.setUint32(16, cellCount, true);
    view.setUint32(PackedQueryResult.DECLARED_LENGTH_OFFSET, buffer.byteLength, true);
    new Uint8Array(buffer, PackedQueryResult.HEADER_SIZE).set(payload);
    return new Uint8Array(buffer);
  }

  private static isJsonScalar(value: Any): boolean {
    if (value == null || value == undefined || typeof value === 'boolean' ||
      typeof value === 'string') {
      return true;
    }
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      return false;
    }
    // JSON would turn an unsafe integer into a Dart arbitrary-precision int,
    // while StandardMessageCodec preserves it as a double.
    return !Number.isInteger(value) || Number.isSafeInteger(value);
  }

  private static writeValue(stream: ByteBuffer, value: Any): boolean {
    if (value == null || value == undefined) {
      stream.writeUint8(PackedValueType.NULL);
    } else if (typeof value === 'boolean') {
      stream.writeUint8(PackedValueType.BOOLEAN);
      stream.writeUint8(value ? 1 : 0);
    } else if (typeof value === 'number') {
      if (Number.isSafeInteger(value)) {
        stream.writeUint8(PackedValueType.INTEGER);
        stream.writeBigInt64(BigInt(value), true);
      } else {
        stream.writeUint8(PackedValueType.REAL);
        stream.writeFloat64(value, true);
      }
    } else if (typeof value === 'bigint') {
      if (value < PackedQueryResult.MIN_INT64 || value > PackedQueryResult.MAX_INT64) {
        // StandardMessageCodec supports larger bigint values; keep its exact
        // behavior instead of truncating them into this protocol's int64 slot.
        return false;
      }
      stream.writeUint8(PackedValueType.INTEGER);
      stream.writeBigInt64(value, true);
    } else if (typeof value === 'string') {
      stream.writeUint8(PackedValueType.TEXT);
      PackedQueryResult.writeBytes(stream,
        new Uint8Array(StringUtils.stringToArrayBuffer(value)));
    } else if (value instanceof Uint8Array) {
      stream.writeUint8(PackedValueType.BLOB);
      PackedQueryResult.writeBytes(stream, value);
    } else if (value instanceof Float32Array) {
      stream.writeUint8(PackedValueType.FLOAT32_ARRAY);
      stream.writeUint32(value.length, true);
      value.forEach((item: number): void => stream.writeFloat32(item, true));
    } else {
      // Asset/Assets and future RDB value types stay on the standard codec path.
      return false;
    }
    return true;
  }

  private static writeBytes(stream: ByteBuffer, bytes: Uint8Array): void {
    stream.writeUint32(bytes.length, true);
    stream.writeUint8Array(bytes);
  }
}
