import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const AutoMapsApp());
}

class AutoMapsApp extends StatelessWidget {
  const AutoMapsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Auto Maps',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
