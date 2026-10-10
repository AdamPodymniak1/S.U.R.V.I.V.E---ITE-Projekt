import 'package:flutter/material.dart';

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
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('S.U.R.V.I.V.E'),
        centerTitle: true,
      ),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.map, size: 96, color: Colors.white54),
            SizedBox(height: 24),
            Text(
              'Offline Mesh Communication',
              style: TextStyle(fontSize: 18, color: Colors.white70),
            ),
            SizedBox(height: 8),
            Text(
              'Connected • Ready',
              style: TextStyle(fontSize: 14, color: Colors.greenAccent),
            ),
          ],
        ),
      ),
    );
  }
}