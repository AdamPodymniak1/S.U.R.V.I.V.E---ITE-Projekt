import 'package:flutter_test/flutter_test.dart';
import 'package:survive_app/mesh_node.dart';

void main() {
  group('MeshNode', () {
    test('creates with required fields', () {
      const node = MeshNode(id: '!abc123', latitude: 52.0, longitude: 19.0);
      expect(node.id, '!abc123');
      expect(node.latitude, 52.0);
      expect(node.longitude, 19.0);
      expect(node.altitude, isNull);
      expect(node.distanceMeters, isNull);
    });

    test('creates with optional fields', () {
      const node = MeshNode(
        id: '!def456',
        latitude: 50.0,
        longitude: 20.0,
        altitude: 150,
        distanceMeters: 500,
      );
      expect(node.altitude, 150);
      expect(node.distanceMeters, 500);
    });

    test('latLng returns correct coordinates', () {
      const node = MeshNode(id: '!xyz789', latitude: 51.5, longitude: -0.1);
      expect(node.latLng.latitude, 51.5);
      expect(node.latLng.longitude, -0.1);
    });
  });
}