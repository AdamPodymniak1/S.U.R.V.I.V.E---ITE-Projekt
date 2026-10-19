import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'mesh_node.dart';

class MapScreen extends StatelessWidget {
  final List<MeshNode> nodes;
  final LatLng? center;
  final double zoom;
  final String? connectionLabel;
  final bool loading;
  final VoidCallback? onConnect;
  final VoidCallback? onLocate;
  final VoidCallback? onDisconnect;

  const MapScreen({
    super.key,
    this.nodes = const [],
    this.center,
    this.zoom = 13.0,
    this.connectionLabel,
    this.loading = false,
    this.onConnect,
    this.onLocate,
    this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final mapCenter = center ?? const LatLng(52.0, 19.0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('S.U.R.V.I.V.E'),
        actions: [
          if (connectionLabel != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(connectionLabel!,
                    style: const TextStyle(fontSize: 12, color: Colors.greenAccent)),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: mapCenter,
              initialZoom: zoom,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.survive.app',
              ),
              MarkerLayer(
                markers: nodes.map((node) {
                  return Marker(
                    point: node.latLng,
                    width: 180,
                    height: 70,
                    child: Column(
                      children: [
                        const Icon(Icons.brightness_1, color: Colors.red, size: 14),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            node.id.length > 8
                                ? '…${node.id.substring(node.id.length - 8)}'
                                : node.id,
                            style: const TextStyle(color: Colors.white, fontSize: 10),
                          ),
                        ),
                        if (node.distanceMeters != null)
                          Text(
                            '${node.distanceMeters!.toStringAsFixed(0)}m',
                            style: const TextStyle(color: Colors.white70, fontSize: 9),
                          ),
                      ],
                    ),
                  );
                }).toList(),
              ),
              if (center != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: mapCenter,
                      width: 30,
                      height: 30,
                      child: const Icon(Icons.my_location, color: Colors.blue, size: 24),
                    ),
                  ],
                ),
            ],
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onConnect != null)
                  FloatingActionButton.extended(
                    heroTag: 'connect',
                    onPressed: loading ? null : onConnect,
                    backgroundColor: connectionLabel != null ? Colors.red.shade700 : Colors.green.shade700,
                    icon: connectionLabel != null
                        ? const Icon(Icons.link_off)
                        : const Icon(Icons.bluetooth_searching),
                    label: Text(connectionLabel != null ? 'Disconnect' : 'Connect'),
                  ),
                const SizedBox(height: 8),
                if (onLocate != null)
                  FloatingActionButton.extended(
                    heroTag: 'locate',
                    onPressed: (connectionLabel == null || loading) ? null : onLocate,
                    backgroundColor: Colors.blue.shade700,
                    icon: loading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.my_location),
                    label: Text(loading ? 'Locating…' : 'Locate nodes'),
                  ),
                if (nodes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${nodes.length} nodes',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black87,
                        backgroundColor: Colors.white70,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}