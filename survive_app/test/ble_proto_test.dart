import 'package:flutter_test/flutter_test.dart';
import 'package:survive_app/meshtastic_ble.dart';
import 'package:survive_app/meshtastic_proto.dart';

/// Encodes a FromRadio{packet: MeshPacket{decoded: Data{portnum, payload}}} using
/// the same fields/numbers as the firmware, so we can verify our decoder.
List<int> _encodeLocateResponse(String csv) {
  final data = ProtobufWriter()
    ..writeUInt64(1, portNumPrivateApp) // Data.portnum
    ..writeBytes(2, csv.codeUnits); // Data.payload
  final packet = ProtobufWriter()
    ..writeFixed32(1, 0x1234abcd) // MeshPacket.from
    ..writeFixed32(2, 0xffffffff) // MeshPacket.to
    ..writeMessage(4, data.bytes); // MeshPacket.decoded
  final fromRadio = ProtobufWriter()..writeMessage(2, packet.bytes);
  return fromRadio.bytes;
}

List<int> _encodeConfigComplete(int id) {
  final fromRadio = ProtobufWriter()..writeUInt64(7, id);
  return fromRadio.bytes;
}

void main() {
  group('parseNodeCsv', () {
    test('parses valid entries', () {
      const csv = 'a1b2,520000000,190000000,150;c3d4,510000000,181000000,-1;';
      final nodes = parseNodeCsv(csv);
      expect(nodes, hasLength(2));
      expect(nodes[0].id, '!a1b2');
      expect(nodes[0].latitude, closeTo(52.0, 1e-6));
      expect(nodes[0].longitude, closeTo(19.0, 1e-6));
      expect(nodes[0].altitude, 150);
      expect(nodes[1].altitude, -1);
    });

    test('skips malformed entries', () {
      expect(parseNodeCsv('bad,entry;').isEmpty, true);
      expect(parseNodeCsv('').isEmpty, true);
      expect(parseNodeCsv('a1,notanumber,19;').isEmpty, true);
    });
  });

  group('encodeLocateRequest', () {
    test('produces a ToRadio with packet on field 1', () {
      final req = encodeLocateRequest();
      final fields = protobufRead(req);
      expect(fields.any((f) => f.field == 1 && f.isLengthDelimited), isTrue);
    });
  });

  group('decodeFromRadio', () {
    test('detects config complete', () {
      const int id = 99;
      final msg = decodeFromRadio(_encodeConfigComplete(id));
      expect(msg.configCompleteId, id);
      expect(msg.isLocateResponse, isFalse);
    });

    test('decodes locate response payload', () {
      const csv = 'abc,520000000,190000000,100;';
      final msg = decodeFromRadio(_encodeLocateResponse(csv));
      expect(msg.isLocateResponse, isTrue);
      expect(msg.from, 0x1234abcd);
      final text = String.fromCharCodes(msg.payload!);
      expect(text, csv);
    });
  });
}