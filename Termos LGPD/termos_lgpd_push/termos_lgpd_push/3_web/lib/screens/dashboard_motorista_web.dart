//
// DASHBOARD_MOTORISTA_WEB.DART
// Dashboard simplificado para o motorista TAC autônomo logar pela Web e
// gerenciar seus próprios caminhões e carretas (até 3 caminhões, mesma
// regra do app mobile). Segue o mesmo estilo visual do dashboard do
// embarcador, mas só com os módulos que fazem sentido pro TAC.
//

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import 'login_screen_web.dart';
import 'termos_aceite_web.dart'; // NOVO: Termos de Uso e Política de Privacidade
import 'tela_frota_motorista_web.dart';
import 'tela_carretas_motorista_web.dart';
import 'desativar_conta_motorista_web.dart'; // NOVO: zona de perigo — o próprio motorista desativa a conta

class DashboardMotoristaWebScreen extends StatefulWidget {
  const DashboardMotoristaWebScreen({super.key});

  @override
  State<DashboardMotoristaWebScreen> createState() => _DashboardMotoristaWebScreenState();
}

class _DashboardMotoristaWebScreenState extends State<DashboardMotoristaWebScreen> {
  final ApiService _api = ApiService();
  int _indiceSelecionado = 0;
  String _nome = "Motorista";

  @override
  void initState() {
    super.initState();
    _carregarNome();
  }

  Future<void> _carregarNome() async {
    final nome = await _api.getNome();
    if (mounted) setState(() => _nome = nome.isEmpty ? "Motorista" : nome);
  }

  void _sair() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('jwt_token');
    await prefs.remove('role');
    await prefs.remove('nome');
    await prefs.remove('user_id');
    await prefs.remove('is_transportadora');
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginEmbarcadorScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: Row(
        children: [
          // Sidebar — mesmo padrão visual do dashboard do embarcador,
          // só que com apenas os módulos do TAC autônomo.
          Container(
            width: 220,
            color: const Color(0xFF0F172A),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 24),
                Center(child: Image.asset('assets/logo.png', height: 40)),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    "Olá, $_nome",
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 20),
                const Divider(color: Colors.white24, height: 1),
                _menuItem(
                  icone: Icons.local_shipping,
                  label: 'Meus Caminhões',
                  selecionado: _indiceSelecionado == 0,
                  onTap: () => setState(() => _indiceSelecionado = 0),
                ),
                _menuItem(
                  icone: Icons.rv_hookup,
                  label: 'Minhas Carretas',
                  selecionado: _indiceSelecionado == 1,
                  onTap: () => setState(() => _indiceSelecionado = 1),
                ),
                const Spacer(),
                const Divider(color: Colors.white24, height: 1),
                _menuItem(
                  icone: Icons.policy_outlined,
                  label: 'Termos e Privacidade',
                  selecionado: false,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TermosTextoScreen()),
                  ),
                ),
                // NOVO: zona de perigo — desativar a própria conta.
                // Fica separado do "Sair" (que é só logout normal) pra
                // não ter risco de confundir os dois.
                _menuItem(
                  icone: Icons.person_off,
                  label: 'Desativar Conta',
                  selecionado: false,
                  corIcone: Colors.redAccent,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const DesativarContaMotoristaScreen()),
                  ),
                ),
                _menuItem(
                  icone: Icons.exit_to_app,
                  label: 'Sair',
                  selecionado: false,
                  corIcone: Colors.redAccent,
                  onTap: _sair,
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: _indiceSelecionado == 0
                  ? const TelaFrotaMotoristaWeb()
                  : const TelaCarretasMotoristaWeb(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _menuItem({
    required IconData icone,
    required String label,
    required bool selecionado,
    required VoidCallback onTap,
    Color corIcone = Colors.white,
  }) {
    return Material(
      color: selecionado ? Colors.white.withOpacity(0.08) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icone, color: selecionado ? Colors.white : corIcone, size: 22),
              const SizedBox(width: 14),
              Text(
                label,
                style: TextStyle(
                  color: selecionado ? Colors.white : Colors.white70,
                  fontWeight: selecionado ? FontWeight.bold : FontWeight.normal,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


