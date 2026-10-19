import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:survive_app/map_screen.dart';
import 'package:survive_app/mesh_node.dart';

Widget createApp({List<MeshNode> nodes = const [], LatLng? center, double zoom = 13}) {
  return MaterialApp(
    home: MapScreen(
      nodes: nodes,
      center: center,
      zoom: zoom,
      onConnect: () {},
      onLocate: () {},
    ),
  );
}

void main() {
  testWidgets('MapScreen renders with title', (WidgetTester tester) async {
    await tester.pumpWidget(createApp());
    expect(find.text('S.U.R.V.I.V.E'), findsOneWidget);
  });

  testWidgets('MapScreen shows node count', (WidgetTester tester) async {
    const nodes = [
      MeshNode(id: '!a1', latitude: 52.0, longitude: 19.0, distanceMeters: 100),
      MeshNode(id: '!b2', latitude: 52.1, longitude: 19.1, distanceMeters: 200),
    ];
    await tester.pumpWidget(createApp(nodes: nodes));
    expect(find.text('2 nodes'), findsOneWidget);
  });

  testWidgets('MapScreen connect button present', (WidgetTester tester) async {
    await tester.pumpWidget(createApp());
    expect(find.text('Connect'), findsOneWidget);
  });
}