// -----  LOGIN_SCREEN_WEB.DART
import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../utils/formatters_web.dart';
import 'dashboard_embarcador_web.dart';
import 'dashboard_motorista_web.dart';
import 'cadastro_embarcador_web.dart';
import 'verificacao_embarcador_web.dart';
import 'trocar_senha_funcionario_web.dart';
import 'termos_aceite_web.dart'; // aceite dos Termos de Uso / Política de Privacidade

class LoginEmbarcadorScreen extends StatefulWidget {
  const LoginEmbarcadorScreen({super.key});

  @override
  State<LoginEmbarcadorScreen> createState() => _LoginEmbarcadorScreenState();
}

class _LoginEmbarcadorScreenState extends State<LoginEmbarcadorScreen> {
  final _usuarioController = TextEditingController();
  final _senhaController = TextEditingController();
  final ApiService _apiService = ApiService();
  bool _isLoading = false;

  void _fazerLogin() async {
    String user = _usuarioController.text.trim();
    String pass = _senhaController.text.trim();

    if (user.isEmpty || pass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Preencha usuário e senha!"), backgroundColor: Colors.orange),
      );
      return;
    }

    // A máscara de CPF/CNPJ é só visual — antes de enviar pro backend,
    // remove pontos/traço/barra (a menos que seja um e-mail, que precisa
    // ir exatamente como digitado).
    final loginParaEnvio = limparCpfCnpjParaEnvio(user);

    setState(() => _isLoading = true);
    try {
      final dados = await _apiService.loginEmbarcador(loginParaEnvio, pass);
      if (!mounted) return;

      // NOVO: funcionário logando pela primeira vez (ou logo depois de um
      // "resetar senha" do administrador) precisa trocar a senha
      // provisória antes de entrar no sistema — nem chega no dashboard.
      final bool precisaTrocarSenha = dados['senha_provisoria'] == true;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(precisaTrocarSenha ? "Acesso liberado! Defina sua senha definitiva." : "Acesso Liberado!"),
          backgroundColor: Colors.green,
        ),
      );

      if (precisaTrocarSenha) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const TrocarSenhaFuncionarioScreen()),
        );
        return;
      }

      // NOVO: Termos de Uso e Política de Privacidade (LGPD). Aparece uma vez
      // por versão do texto; se a pessoa não aceitar, não entra.
      final bool aceitou = await garantirAceiteTermosWeb(context);
      if (!mounted) return;
      if (!aceitou) {
        setState(() => _isLoading = false);
        return;
      }

      // O backend devolve "role": 'motorista' para um TAC autônomo
      // logando com CPF, ou 'embarcador' para empresa/transportadora
      // logando com usuário/CNPJ — a mesma tela de login serve pros dois.
      final bool ehMotorista = dados['role'] == 'motorista';

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ehMotorista
              ? const DashboardMotoristaWebScreen()
              : const DashboardEmbarcadorScreen(),
        ),
      );
    } on EmailNaoVerificadoException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Confirme seu e-mail para continuar."), backgroundColor: Colors.orange),
      );
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => VerificacaoEmbarcadorScreen(email: e.email)),
      );
    } on FuncionarioInativoException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.mensagem), backgroundColor: Colors.red),
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
            colorFilter: ColorFilter.mode(Colors.black26, BlendMode.darken),
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 4.0, sigmaY: 4.0), 
                child: Container(
                  width: 400,
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05), 
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.blue.withOpacity(0.3), 
                      width: 1.0,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 30,
                        offset: const Offset(0, 10),
                      )
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/logo.png',
                        height: 80,
                        errorBuilder: (context, error, stackTrace) => const Icon(Icons.business_center, size: 60, color: Colors.blueAccent),
                      ),
                      const SizedBox(height: 15),
                      const Text(
                        "TACLOG", 
                        style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 1.5),
                      ),
                      const Text(
                        "Portal do Embarcador e do TAC",
                        style: TextStyle(fontSize: 15, color: Colors.white70),
                      ),
                      const SizedBox(height: 40),
                      TextField(
                        controller: _usuarioController,
                        style: const TextStyle(color: Colors.black87),
                        // NOVO: máscara dinâmica — conforme a pessoa digita
                        // números, o campo formata sozinho como CPF
                        // (000.000.000-00) ou CNPJ (00.000.000/0000-00) a
                        // partir do 12º dígito. Se digitar letras/@ (e-mail
                        // de empresa), a máscara é ignorada automaticamente.
                        inputFormatters: [CpfCnpjInputFormatter()],
                        decoration: InputDecoration(
                          labelText: "CPF (motorista/funcionário) ou Usuário/CNPJ (empresa)",
                          labelStyle: const TextStyle(color: Colors.black54),
                          prefixIcon: const Icon(Icons.person_outline, color: Colors.blue),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.85), 
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _senhaController,
                        obscureText: true,
                        style: const TextStyle(color: Colors.black87),
                        decoration: InputDecoration(
                          labelText: "Senha",
                          labelStyle: const TextStyle(color: Colors.black54),
                          prefixIcon: const Icon(Icons.lock_outline, color: Colors.blue),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.85),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (_) => _fazerLogin(),
                      ),
                      const SizedBox(height: 30),
                      _isLoading
                          ? const CircularProgressIndicator(color: Colors.blueAccent)
                          : ElevatedButton(
                              onPressed: _fazerLogin,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF3B82F6).withOpacity(0.9),
                                foregroundColor: Colors.white,
                                minimumSize: const Size(double.infinity, 55),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                elevation: 0,
                              ),
                              child: const Text("ENTRAR NO SISTEMA", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1)),
                            ),
                      const SizedBox(height: 20),
                      Column(
                        children: [
                          TextButton(
                            onPressed: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Recuperação de senha em desenvolvimento."), backgroundColor: Colors.orange),
                              );
                            },
                            child: const Text("Esqueci minha senha", style: TextStyle(color: Colors.white70, fontSize: 14)),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pushReplacement(
                                context,
                                MaterialPageRoute(builder: (context) => const CadastroEmbarcadorScreen()),
                              );
                            },
                            child: const Text(
                              "Não tem login? Cadastre-se", 
                               style: TextStyle(
                                color: Colors.white, 
                                fontWeight: FontWeight.bold, 
                                fontSize: 15, 
                                decoration: TextDecoration.underline, 
                                decorationColor: Colors.white
                               ),
                            ),
                          ),
                        ],
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


