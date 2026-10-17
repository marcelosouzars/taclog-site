// MAIN.DART (APP MOTORISTA / GESTORA)
// NOVO: prepara as notificações push (Firebase) antes de abrir o app.

import 'package:flutter/material.dart';
import 'screens/login_screen_app.dart';
import 'services/push_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PushApp.iniciar();
  runApp(const TacLogApp());
}

class TacLogApp extends StatelessWidget {
  const TacLogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TACLOG 2025 - Motorista',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}
