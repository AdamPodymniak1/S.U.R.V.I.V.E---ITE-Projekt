// Minimal Meshtastic protobuf support (ToRadio / FromRadio / MeshPacket / Data).
// Only the fields needed for our S.U.R.V.I.V.E locate flow are implemented.
//
// Field numbers verified against src/mesh/generated/meshtastic/mesh.pb.h

library;

import 'dart:typed_data';

/// Meshtastic PortNum for private apps (>= 256).
const int portNumPrivateApp = 256;

class ProtobufWriter {
  final BytesBuilder _bytes = BytesBuilder();

  List<int> get bytes => _bytes.toBytes();

  void _tag(int field, int wireType) {
    _varint((field << 3) | wireType);
  }

  void _varint(int value) {
    int v = value & 0xFFFFFFFF;
    do {
      int byte = v & 0x7F;
      v >>= 7;
      if (v != 0) byte |= 0x80;
      _bytes.addByte(byte);
    } while (v != 0);
  }

  void writeUInt64(int field, int value) {
    _tag(field, 0);
    _varint(value);
  }

  void writeFixed32(int field, int value) {
    _tag(field, 5);
    final b = ByteData(4)..setUint32(0, value, Endian.little);
    _bytes.add(b.buffer.asUint8List());
  }

  void writeBool(int field, bool value) {
    _tag(field, 0);
    _varint(value ? 1 : 0);
  }

  void writeBytes(int field, List<int> value) {
    _tag(field, 2);
    _varint(value.length);
    _bytes.add(value);
  }

  void writeMessage(int field, List<int> nested) {
    writeBytes(field, nested);
  }
}

class ProtobufField {
  final int field;
  final int wireType;
  final int varintValue;
  final Uint8List bytesValue;

  ProtobufField(this.field, this.wireType, this.varintValue, this.bytesValue);

  bool get isVarint => wireType == 0;
  bool get isLengthDelimited => wireType == 2;
  bool get isFixed32 => wireType == 5;
}

List<ProtobufField> protobufRead(List<int> data) {
  final fields = <ProtobufField>[];
  final bytes = Uint8List.fromList(data);
  int pos = 0;

  int readVarint() {
    int result = 0;
    int shift = 0;
    while (pos < bytes.length) {
      final b = bytes[pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
      if (shift > 63) break;
    }
    return result;
  }

  while (pos < bytes.length) {
    final tag = readVarint();
    final field = tag >> 3;
    final wireType = tag & 0x7;
    switch (wireType) {
      case 0:
        fields.add(ProtobufField(field, wireType, readVarint(), Uint8List(0)));
        break;
      case 1: // 64-bit, skip (8 bytes)
        pos += 8;
        break;
      case 2:
        final len = readVarint();
        final sub = bytes.sublist(pos, pos + len);
        pos += len;
        fields.add(ProtobufField(field, wireType, 0, sub));
        break;
      case 5: // 32-bit, skip (4 bytes)
        fields.add(ProtobufField(
            field, wireType, 0, bytes.sublist(pos, pos + 4)));
        pos += 4;
        break;
      default:
        return fields; // unknown wire type, stop parsing
    }
  }
  return fields;
}

/// Builds a ToRadio payload: ToRadio { packet = MeshPacket { decoded = Data { portnum, payload } } }
List<int> encodeLocateRequest() {
  final data = ProtobufWriter()
    ..writeUInt64(1, portNumPrivateApp) // Data.portnum
    ..writeBytes(2, 'LOCATE'.codeUnits) // Data.payload
    // writeUInt64(3, 0) skipped: want_response defaults false
    ;
  final packet = ProtobufWriter()
    ..writeUInt64(2, 0xFFFFFFFF) // MeshPacket.to = broadcast
    // MeshPacket.from left as 0, device fills it in
    ..writeMessage(4, data.bytes) // MeshPacket.decoded (Data)
    ;
  final toRadio = ProtobufWriter()
    ..writeMessage(1, packet.bytes) // ToRadio.packet
    ;
  return toRadio.bytes;
}

/// Builds a ToRadio payload: ToRadio { want_config_id = id }
List<int> encodeWantConfig(int id) {
  final toRadio = ProtobufWriter()..writeUInt64(3, id);
  return toRadio.bytes;
}

class FromRadioPacket {
  /// Populated when the FromRadio has a live MeshPacket (its Data payload).
  final int from;
  final int to;
  final int? portnum;
  final Uint8List? payload;

  /// Set when config_complete_id is received.
  final int? configCompleteId;

  FromRadioPacket({
    this.from = 0,
    this.to = 0,
    this.portnum,
    this.payload,
    this.configCompleteId,
  });

  bool get isLocateResponse =>
      portnum == portNumPrivateApp && payload != null;
}

FromRadioPacket decodeFromRadio(List<int> raw) {
  final fields = protobufRead(raw);
  Uint8List? packetBytes;

  for (final f in fields) {
    if (f.field == 2 && f.isLengthDelimited) {
      packetBytes = f.bytesValue;
    }
    if (f.field == 7 && f.isVarint) {
      return FromRadioPacket(configCompleteId: f.varintValue);
    }
  }

  if (packetBytes == null) return FromRadioPacket();

  int from = 0, to = 0;
  Uint8List? dataBytes;
  final pf = protobufRead(packetBytes);
  for (final f in pf) {
    if (f.field == 1 && f.isFixed32) {
      from = f.bytesValue.isEmpty
          ? 0
          : ByteData.sublistView(f.bytesValue).getUint32(0, Endian.little);
    } else if (f.field == 2 && f.isFixed32) {
      to = f.bytesValue.isEmpty
          ? 0
          : ByteData.sublistView(f.bytesValue).getUint32(0, Endian.little);
    } else if (f.field == 4 && f.isLengthDelimited) {
      dataBytes = f.bytesValue;
    }
  }

  if (dataBytes == null) return FromRadioPacket(from: from, to: to);

  int? portnum;
  Uint8List? payload;
  final df = protobufRead(dataBytes);
  for (final f in df) {
    if (f.field == 1 && f.isVarint) {
      portnum = f.varintValue;
    } else if (f.field == 2 && f.isLengthDelimited) {
      payload = f.bytesValue;
    }
  }

  return FromRadioPacket(from: from, to: to, portnum: portnum, payload: payload);
}