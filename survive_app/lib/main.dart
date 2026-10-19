import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'map_screen.dart';
import 'meshtastic_ble.dart';
import 'mesh_node.dart';

void main() {
  runApp(const SurviveApp());
}

class SurviveApp extends StatelessWidget {
  const SurviveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'S.U.R.V.I.V.E',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1B5E20),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MeshtasticBle _ble = MeshtasticBle();
  StreamSubscription<List<MeshNode>>? _nodeSub;

  List<MeshNode> _nodes = [];
  bool _loading = false;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _nodeSub = _ble.nodeStream.listen((nodes) {
      if (!mounted) return;
      setState(() {
        _nodes = nodes;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _nodeSub?.cancel();
    _ble.dispose();
    super.dispose();
  }

  Future<void> _onConnectPressed() async {
    if (_connected) {
      await _ble.disconnect();
      if (!mounted) return;
      setState(() {
        _connected = false;
        _nodes = [];
      });
      return;
    }

    setState(() => _loading = true);
    try {
      final devices = await _ble.scan();
      if (devices.isEmpty) {
        _showSnack('No Meshtastic device found. Is it powered & in range?');
        if (mounted) setState(() => _loading = false);
        return;
      }
      // Prefer the strongest signal.
      devices.sort((a, b) => b.rssi.compareTo(a.rssi));
      final ok = await _ble.connect(devices.first);
      if (!mounted) return;
      if (ok) {
        setState(() {
          _connected = true;
          _loading = false;
        });
        _showSnack('Connected to ${devices.first.name}');
        // Auto-locate once connected so the map fills up.
        _onLocate();
      } else {
        setState(() => _loading = false);
        _showSnack('Could not connect to device');
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _showSnack('Error: $e');
    }
  }

  Future<void> _onLocate() async {
    setState(() => _loading = true);
    await _ble.requestLocate();
    // Give the device time to answer; the stream listener will clear _loading.
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) setState(() => _loading = false);
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    // Center the map on the first node we hear, default to Poland.
    LatLng? center;
    if (_nodes.isNotEmpty) {
      center = _nodes.first.latLng;
    }

    return MapScreen(
      nodes: _nodes,
      center: center ?? const LatLng(52.0, 19.0),
      loading: _loading,
      connectionLabel: _connected ? 'BLE connected' : null,
      onConnect: _onConnectPressed,
      onLocate: _connected ? _onLocate : null,
    );
  }
}