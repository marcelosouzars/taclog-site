// LOGIN_SCREEN_APP.DART

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service_app.dart';
import 'cadastro_wizard_app.dart'; 
import 'dashboard_motorista_app.dart';
import 'dashboard_gestor_app.dart';
import 'verificacao_screen_app.dart';
import 'termos_screen_app.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _cpfController = TextEditingController();
  final _senhaController = TextEditingController();
  final ApiService _apiService = ApiService();
  bool _isLoading = false;

  final maskCpf = MaskTextInputFormatter(mask: '###.###.###-##', filter: {"#": RegExp(r'[0-9]')});

  // NOVO: gestora (avisos de coleta) que já entrou antes neste aparelho
  // volta direto pra tela dela — senão ela teria que digitar CPF e senha
  // toda vez que abrisse o app só pra ver um aviso. Motorista continua
  // exatamente como era (sempre pede login).
  @override
  void initState() {
    super.initState();
    _entrarAutomaticoSeForGestora();
  }

  Future<void> _entrarAutomaticoSeForGestora() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ehGestora = prefs.getString('tipo_app') == 'GESTOR';
      final temToken = (prefs.getString('jwt_token') ?? '').isNotEmpty;
      if (ehGestora && temToken && mounted) {
        // NOVO: se os termos ganharam uma versão nova desde o último acesso,
        // pede o aceite antes de abrir a tela da gestora.
        final aceitou = await garantirAceiteTermos(context);
        if (!aceitou || !mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const DashboardGestorScreen()));
      }
    } catch (_) {
      // sem sessão guardada: segue pro login normal
    }
  }

  void _fazerLogin() async {
    if (_cpfController.text.isEmpty || _senhaController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Preencha CPF e senha!"), backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      String cpfLimpo = _cpfController.text.replaceAll(RegExp(r'[^0-9]'), '');
      
      final resposta = await _apiService.login(cpfLimpo, _senhaController.text);

      if (!mounted) return;

      final prefs = await SharedPreferences.getInstance();

      // NOVO: quem entra com CPF de FUNCIONÁRIA DE ESCRITÓRIO da
      // transportadora (role "embarcador") só usa o app se foi marcada como
      // gestora (recebe os avisos de coleta). Senão, o app não é pra ela.
      if (resposta['role'] == 'embarcador') {
        if (resposta['recebe_avisos_app'] == true) {
          await prefs.setString('tipo_app', 'GESTOR');
          await prefs.setString('gestor_nome', (resposta['funcionario_nome'] ?? '').toString());
          await prefs.setString('gestor_empresa', (resposta['nome'] ?? '').toString());
          if (!mounted) return;
          // NOVO: aceite dos Termos de Uso / Política de Privacidade.
          final aceitouGestora = await garantirAceiteTermos(context);
          if (!aceitouGestora || !mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const DashboardGestorScreen()),
          );
          return;
        }
        await prefs.remove('jwt_token');
        await prefs.remove('tipo_app');
        throw Exception("Este acesso é do painel web. Para receber avisos no app, peça ao administrador para marcar você como gestora na tela Usuários.");
      }

      await prefs.remove('tipo_app');

      // NOVO: aceite dos Termos de Uso / Política de Privacidade (aparece
      // só na primeira vez e quando o texto ganha uma versão nova).
      final aceitou = await garantirAceiteTermos(context);
      if (!aceitou || !mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Login realizado com sucesso!"), backgroundColor: Colors.green),
      );

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const DashboardMotoristaScreen()),
      );
    } on EmailNaoVerificadoException catch (e) {
      // Login e senha corretos, mas o e-mail ainda não foi confirmado.
      // Manda direto para a tela de verificação em vez de só mostrar um erro.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Confirme seu e-mail para continuar."), backgroundColor: Colors.orange),
      );
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => VerificacaoScreen(email: e.email)),
      );
    } catch (e) {
      if (!mounted) return;
      
      String mensagem = e.toString().replaceAll("Exception: ", "");
      Color corFundo = Colors.red;

      if (mensagem.contains("ANÁLISE")) {
        corFundo = Colors.orange[800]!;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(mensagem, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)), 
          backgroundColor: corFundo,
          duration: const Duration(seconds: 5),
        ),
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
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 4.0, sigmaY: 4.0), // Efeito Vidro Cristalino
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 35),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05), // Transparência alta
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
                      // Logomarca TACLOG
                      Image.asset(
                        'assets/logo.png',
                        height: 80,
                        errorBuilder: (context, error, stackTrace) => const Icon(Icons.local_shipping, size: 70, color: Colors.blueAccent),
                      ),
                      const SizedBox(height: 15),
                      const Text(
                        "TACLOG",
                        style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 1.5),
                      ),
                      const Text(
                        "Portal do Motorista",
                        style: TextStyle(fontSize: 16, color: Colors.white70, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 35),
                      TextField(
                        controller: _cpfController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [maskCpf],
                        style: const TextStyle(color: Colors.black87),
                        decoration: InputDecoration(
                          labelText: "CPF",
                          labelStyle: const TextStyle(color: Colors.black54),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.85),
                          prefixIcon: const Icon(Icons.person_outline, color: Colors.blue),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                      ),
                      const SizedBox(height: 15),
                      TextField(
                        controller: _senhaController,
                        obscureText: true,
                        style: const TextStyle(color: Colors.black87),
                        decoration: InputDecoration(
                          labelText: "Senha",
                          labelStyle: const TextStyle(color: Colors.black54),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.85),
                          prefixIcon: const Icon(Icons.lock_outline, color: Colors.blue),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
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
                              child: const Text("ENTRAR", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1)),
                            ),
                      const SizedBox(height: 20),
                      TextButton(
                        onPressed: () {
                          Navigator.push(context, MaterialPageRoute(builder: (context) => const CadastroWizard()));
                        },
                        child: const Text(
                          "Não tem conta? Cadastre-se aqui", 
                          style: TextStyle(fontSize: 15, color: Colors.white, fontWeight: FontWeight.bold, decoration: TextDecoration.underline, decorationColor: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      )
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


