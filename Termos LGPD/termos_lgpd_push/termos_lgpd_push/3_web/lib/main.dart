//
//  MAIN.DART -V3
//
// CORRIGIDO: antes o app sempre abria direto na tela de Login, mesmo
// com um token válido já salvo — todo F5 (recarregar a página) parecia
// um logout, porque reconstruía do zero e não checava se já existia
// uma sessão. Agora tem uma tela de espera rápida (_AuthGate) que
// confere o SharedPreferences ANTES de decidir: se tem token salvo, já
// pula direto pro Dashboard; senão, mostra o Login normalmente.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/login_screen_web.dart';
import 'screens/dashboard_embarcador_web.dart';
import 'screens/termos_aceite_web.dart';

void main() {
  runApp(const TaclogWebEmbarcadorApp());
}

class TaclogWebEmbarcadorApp extends StatelessWidget {
  const TaclogWebEmbarcadorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TACLOG - Portal do Embarcador',
      debugShowCheckedModeBanner: false,
      theme: _construirTemaProfissional(),
      home: const _AuthGate(),
    );
  }

  // --- CONFIGURAÇÃO DO TEMA PADRÃO (ENTERPRISE) ---
  ThemeData _construirTemaProfissional() {
    return ThemeData(
      useMaterial3: true,
      
      scaffoldBackgroundColor: const Color(0xFFF8FAFC), 
      
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF0F172A), 
        secondary: Color(0xFF3B82F6), 
        surface: Colors.white, 
        error: Color(0xFFEF4444), 
        onPrimary: Colors.white, 
        onSecondary: Colors.white, 
        onSurface: Color(0xFF334155), 
      ),

      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 2,
        shadowColor: Colors.black.withOpacity(0.05),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFFE2E8F0), width: 1),
        ),
        margin: const EdgeInsets.only(bottom: 20),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF3B82F6), 
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF1F5F9), 
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 2),
        ),
        labelStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
        hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
      ),

      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Color(0xFF0F172A),
        selectedIconTheme: IconThemeData(color: Colors.white, size: 28),
        unselectedIconTheme: IconThemeData(color: Color(0xFF94A3B8), size: 24),
        selectedLabelTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        unselectedLabelTextStyle: TextStyle(color: Color(0xFF94A3B8)),
      ),
      
      fontFamily: 'Roboto', 
    );
  }
}

// =========================================================================
// NOVO: decide, ao abrir/recarregar o app, se já existe uma sessão salva
// (token no SharedPreferences) — se tiver, vai direto pro Dashboard, sem
// pedir login de novo. Mostra uma tela de carregamento rapidinha enquanto
// confere (é local, praticamente instantâneo).
// =========================================================================
class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _verificando = true;
  bool _temSessao = false;

  @override
  void initState() {
    super.initState();
    _verificarSessao();
  }

  Future<void> _verificarSessao() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');
    bool temSessao = token != null && token.isNotEmpty;
    // NOVO: quem já estava logado antes dos Termos existirem (ou quando sai
    // uma versão nova do texto) também precisa aceitar antes de continuar.
    if (temSessao && mounted) {
      temSessao = await garantirAceiteTermosWeb(context);
    }
    if (mounted) {
      setState(() {
        _temSessao = temSessao;
        _verificando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_verificando) {
      return const Scaffold(
        backgroundColor: Color(0xFFF8FAFC),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return _temSessao ? const DashboardEmbarcadorScreen() : const LoginEmbarcadorScreen();
  }
}


