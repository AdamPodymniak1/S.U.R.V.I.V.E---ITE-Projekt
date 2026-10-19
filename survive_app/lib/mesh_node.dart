import 'package:latlong2/latlong.dart';

class MeshNode {
  final String id;
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? distanceMeters;

  const MeshNode({
    required this.id,
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.distanceMeters,
  });

  LatLng get latLng => LatLng(latitude, longitude);
}