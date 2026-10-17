// TROCAR_SENHA_FUNCIONARIO_WEB.DART
// ARQUIVO NOVO: lib/screens/trocar_senha_funcionario_web.dart
// Tela obrigatória logo após o primeiro login de um funcionário (ou depois
// de um "resetar senha" do administrador) — troca a senha provisória por
// uma definitiva antes de liberar o acesso ao sistema. Chama
// POST /api/funcionario/trocar-senha; enquanto a senha continuar
// provisória, o backend (authenticateToken) bloqueia qualquer outra rota,
// então não tem como "pular" essa tela.

import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'dashboard_embarcador_web.dart';
import 'login_screen_web.dart';
import 'termos_aceite_web.dart'; // aceite dos Termos de Uso / Política de Privacidade

class TrocarSenhaFuncionarioScreen extends StatefulWidget {
  const TrocarSenhaFuncionarioScreen({super.key});

  @override
  State<TrocarSenhaFuncionarioScreen> createState() => _TrocarSenhaFuncionarioScreenState();
}

class _TrocarSenhaFuncionarioScreenState extends State<TrocarSenhaFuncionarioScreen> {
  final _novaSenhaController = TextEditingController();
  final _confirmarSenhaController = TextEditingController();
  final ApiService _apiService = ApiService();
  bool _isLoading = false;
  bool _ocultarNova = true;
  bool _ocultarConfirmar = true;

  Future<void> _trocarSenha() async {
    final novaSenha = _novaSenhaController.text.trim();
    final confirmarSenha = _confirmarSenhaController.text.trim();

    if (novaSenha.isEmpty || confirmarSenha.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Preencha os dois campos."), backgroundColor: Colors.orange),
      );
      return;
    }
    if (novaSenha.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("A nova senha precisa ter pelo menos 6 caracteres."), backgroundColor: Colors.orange),
      );
      return;
    }
    if (novaSenha != confirmarSenha) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("As senhas não coincidem."), backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      await _apiService.trocarSenhaFuncionario(novaSenha, confirmarSenha);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Senha definida com sucesso!"), backgroundColor: Colors.green),
      );

      // NOVO: depois de definir a senha, o funcionário aceita os termos
      // (se ainda não aceitou esta versão) antes de entrar no sistema.
      final bool aceitou = await garantirAceiteTermosWeb(context);
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => aceitou ? const DashboardEmbarcadorScreen() : const LoginEmbarcadorScreen(),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceAll("Exception: ", "")), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/fundo_embarcador.jpg'),
            fit: BoxFit.cover,
            colorFilter: ColorFilter.mode(Colors.black54, BlendMode.darken),
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8.0, sigmaY: 8.0),
                child: Container(
                  width: 420,
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white.withOpacity(0.2), width: 1.5),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_reset, size: 64, color: Colors.white),
                      const SizedBox(height: 20),
                      const Text(
                        "Defina sua senha",
                        style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        "Este é seu primeiro acesso (ou sua senha foi redefinida).\nEscolha uma nova senha só sua para continuar.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(height: 30),
                      TextField(
                        controller: _novaSenhaController,
                        obscureText: _ocultarNova,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Nova senha",
                          labelStyle: const TextStyle(color: Colors.white70),
                          prefixIcon: const Icon(Icons.lock_outline, color: Colors.white70),
                          suffixIcon: IconButton(
                            icon: Icon(_ocultarNova ? Icons.visibility_off : Icons.visibility, color: Colors.white70),
                            onPressed: () => setState(() => _ocultarNova = !_ocultarNova),
                          ),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.08),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _confirmarSenhaController,
                        obscureText: _ocultarConfirmar,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Confirmar nova senha",
                          labelStyle: const TextStyle(color: Colors.white70),
                          prefixIcon: const Icon(Icons.lock_outline, color: Colors.white70),
                          suffixIcon: IconButton(
                            icon: Icon(_ocultarConfirmar ? Icons.visibility_off : Icons.visibility, color: Colors.white70),
                            onPressed: () => setState(() => _ocultarConfirmar = !_ocultarConfirmar),
                          ),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.08),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (_) => _trocarSenha(),
                      ),
                      const SizedBox(height: 24),
                      _isLoading
                          ? const CircularProgressIndicator(color: Colors.white)
                          : SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: _trocarSenha,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: const Text("SALVAR E ENTRAR", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                              ),
                            ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


