// Meshtastic over BLE client using flutter_blue_plus.
// Implements the device's serial-wire framing: big-endian 0x94C3 header
// followed by a ToRadio/FromRadio protobuf.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'mesh_node.dart';
import 'meshtastic_proto.dart';

const String meshServiceUuid = '6ba1b218-15a8-461f-9fa8-5dcae273eafd';
const String toRadioUuid = 'f75c76d2-129e-4dad-a1dd-7866124401e7';
const String fromRadioUuid = '2c55e69e-4993-11ed-b878-0242ac120002';

class MeshtasticDevice {
  final String name;
  final String id;
  final int rssi;
  const MeshtasticDevice(this.name, this.id, this.rssi);
}

class MeshtasticBle {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _toRadio;
  BluetoothCharacteristic? _fromRadio;
  StreamSubscription? _rxSub;
  final _nodeStreamController = StreamController<List<MeshNode>>.broadcast();

  final _knownDevices = <String, BluetoothDevice>{};
  bool _connected = false;
  bool _configReady = false;
  final List<int> _rxBuffer = [];

  Stream<List<MeshNode>> get nodeStream => _nodeStreamController.stream;
  bool get isConnected => _connected;
  bool get isConfigReady => _configReady;

  Future<void> dispose() async {
    await disconnect();
    await _nodeStreamController.close();
  }

  Future<List<MeshtasticDevice>> scan({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final found = <MeshtasticDevice>[];
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final adv = r.advertisementData;
        final name = adv.advName;
        final hasService = adv.serviceUuids
            .any((u) => u.toString().toLowerCase() == meshServiceUuid);
        final isMesh =
            name.toLowerCase().contains('meshtastic') || hasService;
        if (isMesh) {
          _knownDevices[r.device.remoteId.str] = r.device;
          found.add(MeshtasticDevice(
            name.isEmpty ? r.device.platformName : name,
            r.device.remoteId.str,
            r.rssi,
          ));
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      await Future.delayed(timeout);
    } finally {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
      await sub.cancel();
    }
    return found;
  }

  Future<bool> connect(MeshtasticDevice device) async {
    await disconnect();

    // Prefer an already-connected instance; otherwise scan to obtain one.
    BluetoothDevice? target;
    for (final d in FlutterBluePlus.connectedDevices) {
      if (d.remoteId.str == device.id) {
        target = d;
        break;
      }
    }
    if (target == null) {
      final cached = _knownDevices[device.id];
      if (cached != null) {
        target = cached;
      } else {
        await scan(timeout: const Duration(seconds: 10));
        target = _knownDevices[device.id];
      }
    }
    if (target == null) return false;

    _device = target;
    await target.connect(timeout: const Duration(seconds: 30));
    await target.discoverServices();
    _connected = true;

    BluetoothService? service;
    for (final s in target.servicesList) {
      if (s.uuid.toString().toLowerCase() == meshServiceUuid) {
        service = s;
        break;
      }
    }
    if (service == null) {
      await disconnect();
      return false;
    }

    for (final c in service.characteristics) {
      final uuid = c.uuid.toString().toLowerCase();
      if (uuid == toRadioUuid) {
        _toRadio = c;
      } else if (uuid == fromRadioUuid) {
        _fromRadio = c;
      }
    }

    if (_toRadio == null || _fromRadio == null) {
      await disconnect();
      return false;
    }

    _rxSub = _fromRadio!.onValueReceived.listen(_handleFromRadioChunk);
    await _fromRadio!.setNotifyValue(true);

    // Kick off the config handshake so the device knows a client is here.
    await _sendFrame(encodeWantConfig(_configNonce()));

    return true;
  }

  Future<void> disconnect() async {
    _configReady = false;
    await _rxSub?.cancel();
    _rxSub = null;
    if (_device != null) {
      try {
        await _device!.disconnect();
      } catch (_) {}
    }
    _device = null;
    _toRadio = null;
    _fromRadio = null;
    _connected = false;
    _rxBuffer.clear();
  }

  int _configNonce() => DateTime.now().millisecondsSinceEpoch & 0x7FFFFFFF;

  /// Send a LOCATE request; replies are streamed via [nodeStream].
  Future<void> requestLocate() async {
    if (!_connected || _toRadio == null) return;
    await _sendFrame(encodeLocateRequest());
  }

  Future<void> _sendFrame(List<int> payload) async {
    final ch = _toRadio;
    if (ch == null || payload.length > 0xFFFF) return;
    final header = ByteData(4)
      ..setUint16(0, 0x94C3, Endian.big)
      ..setUint16(2, payload.length, Endian.big);
    final frame = Uint8List(4 + payload.length)
      ..setRange(0, 4, header.buffer.asUint8List())
      ..setRange(4, 4 + payload.length, payload);
    try {
      await ch.write(frame, withoutResponse: true);
    } catch (_) {}
  }

  /// Meshtastic frames can arrive split across BLE notifications; buffer and
  /// reassemble using the 0x94C3 header.
  void _handleFromRadioChunk(List<int> chunk) {
    _rxBuffer.addAll(chunk);

    while (_rxBuffer.length >= 4) {
      final header = Uint8List.fromList(_rxBuffer.sublist(0, 4));
      final size = ByteData.sublistView(header).getUint16(2, Endian.big);
      if (size > 512) {
        _rxBuffer.removeAt(0); // resync
        continue;
      }
      if (_rxBuffer.length < 4 + size) return;

      final payload = Uint8List.fromList(_rxBuffer.sublist(4, 4 + size));
      _rxBuffer.removeRange(0, 4 + size);
      _handleFromRadio(payload);
    }
  }

  void _handleFromRadio(List<int> payload) {
    final msg = decodeFromRadio(payload);
    if (msg.configCompleteId != null) {
      _configReady = true;
      return;
    }
    if (!msg.isLocateResponse) return;

    final text = utf8.decode(msg.payload!, allowMalformed: true);
    final nodes = parseNodeCsv(text);
    if (nodes.isNotEmpty) {
      _nodeStreamController.add(nodes);
    }
  }
}

/// Parses our firmware CSV report: "<nodehex>,<lat_i>,<lon_i>,<alt>;..." (1e-7 deg)
List<MeshNode> parseNodeCsv(String csv) {
  final nodes = <MeshNode>[];
  for (final entry in csv.split(';')) {
    final parts = entry.split(',');
    if (parts.length < 3) continue;
    final latI = int.tryParse(parts[1]);
    final lonI = int.tryParse(parts[2]);
    if (latI == null || lonI == null) continue;
    final alt = parts.length > 3 ? int.tryParse(parts[3]) : null;
    nodes.add(MeshNode(
      id: '!${parts[0]}',
      latitude: latI / 1e7,
      longitude: lonI / 1e7,
      altitude: alt?.toDouble(),
    ));
  }
  return nodes;
}