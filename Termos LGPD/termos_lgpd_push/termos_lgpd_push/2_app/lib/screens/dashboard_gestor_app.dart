// DASHBOARD_GESTOR_APP.DART
//
// Tela da GESTORA no app do celular (ex.: gerente operacional, diretora da
// transportadora). Não tem frota, mapa nem GPS: só mostra os AVISOS DE
// COLETA — uma cópia de tudo que o sistema avisa para os motoristas — e,
// mais pra frente, Histórico de Agendamentos e Financeiro (ainda "em
// breve"). Os avisos são consultados por polling (a cada 15s) enquanto o app
// está aberto; quando chega aviso novo, toca o alerta e abre um pop-up. Fora
// do app, a mesma informação também chega por e-mail.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import '../audio_bridge.dart'; // mesma ponte de áudio usada no dashboard do motorista
import '../services/api_service_app.dart';
import 'login_screen_app.dart';
import 'termos_screen_app.dart';
import '../services/push_app.dart'; // NOVO: notificações com o app fechado

class DashboardGestorScreen extends StatefulWidget {
  const DashboardGestorScreen({super.key});

  @override
  State<DashboardGestorScreen> createState() => _DashboardGestorScreenState();
}

class _DashboardGestorScreenState extends State<DashboardGestorScreen> with WidgetsBindingObserver {
  static const Color _corTopo = Color(0xFF3A6490);
  static const String _audioSrcWeb = 'assets/assets/audio/alerta_frete.mp3';

  final ApiService _api = ApiService();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _audioDesbloqueado = false;

  String _nome = '';
  String _empresa = '';

  List<dynamic> _avisos = [];
  bool _carregandoInicial = true;
  String? _erro;
  Timer? _timer;

  // Maior id de aviso já visto — tudo que chegar com id maior que isso
  // (e ainda não lido) é "novo" e dispara som + pop-up. Fica nulo até a
  // primeira carga, pra não apitar com avisos antigos ao abrir o app.
  int? _maiorIdVisto;
  bool _dialogoAberto = false;
  bool _trocandoSenha = false;
  bool _atualizando = false;
  bool _saindo = false; // evita atualizar/navegar de novo enquanto está saindo

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PushApp.registrar(); // NOVO: cadastra este celular para receber avisos com o app fechado
    _carregarNomes();
    _inicializarAudio();
    _atualizar();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _atualizar());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  // Voltou do segundo plano (ela olhou outro app e voltou): atualiza na hora,
  // sem esperar o próximo ciclo do timer.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _atualizar();
    }
  }

  Future<void> _carregarNomes() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _nome = prefs.getString('gestor_nome') ?? '';
      _empresa = prefs.getString('gestor_empresa') ?? '';
    });
  }

  // ---------------------------------------------------------------- ÁUDIO
  void _inicializarAudio() {
    if (!kIsWeb) {
      _audioPlayer.setAudioContext(AudioContextConfig(stayAwake: true).build());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          taclogInitAudioPlatform(_audioSrcWeb);
        } catch (e) {
          debugPrint("Falha ao inicializar áudio web (ignorado): $e");
        }
      });
    }
  }

  // Precisa acontecer dentro de um toque dela (regra do iPhone/Safari) —
  // senão o som nunca toca quando o alerta chega sozinho, pelo timer.
  Future<void> _destravarAudioSeNecessario() async {
    if (_audioDesbloqueado) return;
    try {
      if (kIsWeb) {
        taclogDestravarAudioPlatform(_audioSrcWeb);
      } else {
        await _audioPlayer.setVolume(0.0);
        await _audioPlayer.play(AssetSource('audio/alerta_frete.mp3'));
        await Future.delayed(const Duration(milliseconds: 100));
        await _audioPlayer.stop();
        await _audioPlayer.setVolume(1.0);
      }
      _audioDesbloqueado = true;
    } catch (e) {
      debugPrint("Falha ao destravar áudio: $e");
    }
  }

  Future<void> _tocarAlertaSonoro() async {
    try {
      if (kIsWeb) {
        taclogTocarAlertaPlatform();
      } else {
        await _audioPlayer.play(AssetSource('audio/alerta_frete.mp3'));
      }
    } catch (e) {
      debugPrint("Erro ao tocar áudio: $e");
    }
  }

  // ------------------------------------------------------------- AVISOS
  int get _totalNaoLidos => _avisos.where((a) => a['lida'] != true).length;

  int _idDe(dynamic aviso) => (aviso['id'] as num).toInt();

  Future<void> _atualizar() async {
    if (_atualizando || _trocandoSenha || _saindo) return;
    _atualizando = true;
    try {
      final lista = await _api.getNotificacoesGestor();
      if (!mounted) return;

      int maior = 0;
      for (final a in lista) {
        final id = _idDe(a);
        if (id > maior) maior = id;
      }

      // Avisos novos = não lidos e com id maior que o maior já visto.
      final novos = _maiorIdVisto == null
          ? <dynamic>[]
          : lista.where((a) => a['lida'] != true && _idDe(a) > _maiorIdVisto!).toList();

      setState(() {
        _avisos = lista;
        _erro = null;
        _carregandoInicial = false;
      });
      if (_maiorIdVisto == null || maior > _maiorIdVisto!) _maiorIdVisto = maior;

      if (novos.isNotEmpty) {
        _tocarAlertaSonoro();
        _mostrarPopUpNovo(novos);
      }
    } on SenhaProvisoriaException {
      if (mounted) _exigirNovaSenha();
    } on GestoraSemAcessoException catch (e) {
      if (mounted) _sairPorFaltaDeAcesso(e.mensagem);
    } catch (e) {
      if (mounted) {
        setState(() {
          _carregandoInicial = false;
          // Só mostra erro se ainda não temos nada na tela; se já temos avisos,
          // uma falha de rede momentânea não deve atrapalhar a leitura.
          if (_avisos.isEmpty) _erro = e.toString().replaceAll("Exception: ", "");
        });
      }
    } finally {
      _atualizando = false;
    }
  }

  void _mostrarPopUpNovo(List<dynamic> novos) {
    if (_dialogoAberto || !mounted) return;
    _dialogoAberto = true;

    // Mostra o mais recente (a lista vem do mais novo pro mais antigo).
    final mais = novos.first;
    final tipo = (mais['tipo'] ?? 'GERAL').toString();
    final mensagem = (mais['mensagem'] ?? '').toString();
    final extra = novos.length > 1 ? "\n\n(+ ${novos.length - 1} aviso(s) novo(s) na lista)" : "";

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(_iconeDoTipo(tipo), color: _corDoTipo(tipo), size: 42),
        title: Text(_tituloDoTipo(tipo), textAlign: TextAlign.center),
        content: Text("$mensagem$extra", textAlign: TextAlign.center),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("OK"),
          ),
        ],
      ),
    ).then((_) => _dialogoAberto = false);
  }

  IconData _iconeDoTipo(String tipo) {
    switch (tipo) {
      case 'COLETAR_AGORA':
        return Icons.alarm_on;
      case 'ALERTA':
        return Icons.warning_amber_rounded;
      case 'AVISO_ANTECEDENCIA':
        return Icons.schedule;
      default:
        return Icons.local_shipping;
    }
  }

  Color _corDoTipo(String tipo) {
    switch (tipo) {
      case 'COLETAR_AGORA':
        return Colors.red;
      case 'ALERTA':
        return Colors.orange.shade800;
      case 'AVISO_ANTECEDENCIA':
        return Colors.blue;
      default:
        return Colors.indigo;
    }
  }

  String _tituloDoTipo(String tipo) {
    switch (tipo) {
      case 'COLETAR_AGORA':
        return "Hora da coleta!";
      case 'ALERTA':
        return "Atenção!";
      case 'AVISO_ANTECEDENCIA':
        return "Coleta se aproximando";
      default:
        return "Novo aviso";
    }
  }

  String _formatarDataHora(dynamic iso) {
    if (iso == null) return '';
    try {
      final d = DateTime.parse(iso.toString()).toLocal();
      String dois(int n) => n.toString().padLeft(2, '0');
      return "${dois(d.day)}/${dois(d.month)} ${dois(d.hour)}:${dois(d.minute)}";
    } catch (_) {
      return '';
    }
  }

  Future<void> _marcarLida(dynamic aviso) async {
    if (aviso['lida'] == true) return;
    setState(() => aviso['lida'] = true); // na hora, sem esperar o servidor
    try {
      await _api.marcarNotificacaoGestorLida(_idDe(aviso));
    } catch (_) {
      // silencioso: o próximo ciclo do timer ressincroniza
    }
  }

  Future<void> _marcarTodasLidas() async {
    if (_totalNaoLidos == 0) return;
    setState(() {
      for (final a in _avisos) {
        a['lida'] = true;
      }
    });
    try {
      await _api.marcarTodasNotificacoesGestorLidas();
    } catch (_) {}
  }

  // ------------------------------------------------------- SENHA / SAIR
  // Senha provisória (a que o administrador gerou): só dá pra usar o app
  // depois de definir uma senha de verdade.
  Future<void> _exigirNovaSenha() async {
    if (_trocandoSenha) return;
    _trocandoSenha = true;

    final novaCtrl = TextEditingController();
    final confirmaCtrl = TextEditingController();
    String? erro;
    bool salvando = false;

    final focoConfirma = FocusNode();
    bool verSenha = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          Future<void> salvar() async {
            if (salvando) return;
            setStateDialog(() {
              salvando = true;
              erro = null;
            });
            try {
              await _api.trocarSenhaFuncionario(novaCtrl.text.trim(), confirmaCtrl.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) {
              setStateDialog(() {
                salvando = false;
                erro = e.toString().replaceAll("Exception: ", "");
              });
            }
          }

          return PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text("Defina sua senha"),
              // Rolável: com o teclado aberto a tela fica pequena e, sem
              // rolagem, o segundo campo ficava escondido/inalcançável.
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Você entrou com uma senha provisória. Escolha uma senha nova (mínimo de 6 caracteres) para continuar.",
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    if (erro != null) ...[
                      Text(erro!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      controller: novaCtrl,
                      obscureText: !verSenha,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => focoConfirma.requestFocus(),
                      decoration: InputDecoration(
                        labelText: "Nova senha",
                        suffixIcon: IconButton(
                          icon: Icon(verSenha ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setStateDialog(() => verSenha = !verSenha),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: confirmaCtrl,
                      focusNode: focoConfirma,
                      obscureText: !verSenha,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => salvar(),
                      decoration: const InputDecoration(labelText: "Repita a nova senha"),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: salvando
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _sair();
                        },
                  child: const Text("SAIR"),
                ),
                ElevatedButton(
                  onPressed: salvando ? null : salvar,
                  child: salvando
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text("SALVAR"),
                ),
              ],
            ),
          );
        },
      ),
    );

    _trocandoSenha = false;
    novaCtrl.dispose();
    confirmaCtrl.dispose();
    focoConfirma.dispose();
    if (mounted && !_saindo) _atualizar();
  }

  Future<void> _limparSessao() async {
    await PushApp.desregistrar(); // NOVO: este celular para de receber avisos desta conta
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('jwt_token');
    await prefs.remove('usuario_nome');
    await prefs.remove('foto_url');
    await prefs.remove('tipo_app');
    await prefs.remove('gestor_nome');
    await prefs.remove('gestor_empresa');
  }

  Future<void> _sair() async {
    _saindo = true;
    _timer?.cancel();
    await _limparSessao();
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  Future<void> _sairPorFaltaDeAcesso(String mensagem) async {
    if (_saindo) return;
    _saindo = true;
    _timer?.cancel();
    await _limparSessao();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensagem), backgroundColor: Colors.red, duration: const Duration(seconds: 6)),
    );
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  Future<void> _confirmarSair() async {
    final sair = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Sair do TACLOG?"),
        content: const Text("Você deixa de ver os avisos aqui até entrar de novo (os avisos continuam chegando por e-mail)."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("SAIR")),
        ],
      ),
    );
    if (sair == true) _sair();
  }

  // ------------------------------------------------------------- TELA
  Widget _cardEmBreve(IconData icone, String titulo, String descricao) {
    return Card(
      color: Colors.grey.shade100,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: ListTile(
        leading: Icon(icone, color: Colors.grey.shade500),
        title: Text(titulo, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey.shade700)),
        subtitle: Text(descricao, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10)),
          child: const Text("EM BREVE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _tileAviso(dynamic a) {
    final lida = a['lida'] == true;
    final tipo = (a['tipo'] ?? 'GERAL').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: lida ? Colors.white : const Color(0xFFEAF2FB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: lida ? Colors.grey.shade300 : _corDoTipo(tipo).withOpacity(0.5)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _marcarLida(a),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_iconeDoTipo(tipo), color: lida ? Colors.grey : _corDoTipo(tipo), size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (a['mensagem'] ?? '').toString(),
                      style: TextStyle(fontSize: 13.5, fontWeight: lida ? FontWeight.normal : FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatarDataHora(a['data_criacao']),
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              if (!lida)
                Container(
                  margin: const EdgeInsets.only(left: 6, top: 4),
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final naoLidos = _totalNaoLidos;
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(
        backgroundColor: _corTopo,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("TACLOG Gestão", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            if (_empresa.isNotEmpty) Text(_empresa, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.done_all),
            tooltip: "Marcar todas como lidas",
            onPressed: naoLidos == 0 ? null : _marcarTodasLidas,
          ),
          IconButton(
            icon: const Icon(Icons.notifications_active_outlined),
            tooltip: "Testar notificação",
            onPressed: () => PushApp.testar(context),
          ),
          IconButton(
            icon: const Icon(Icons.policy_outlined),
            tooltip: "Termos e Privacidade",
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TermosTextoScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: "Sair",
            onPressed: _confirmarSair,
          ),
        ],
      ),
      // Qualquer toque na tela destrava o áudio (exigência do iPhone/Safari).
      body: Listener(
        onPointerDown: (_) => _destravarAudioSeNecessario(),
        child: RefreshIndicator(
          onRefresh: _atualizar,
          child: ListView(
            padding: const EdgeInsets.all(16),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Text(
                _nome.isEmpty ? "Olá!" : "Olá, $_nome!",
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
              ),
              const SizedBox(height: 4),
              Text(
                "Aqui chegam os mesmos avisos de coleta que os motoristas recebem. Deixe o app aberto para ouvir o alerta; fora dele, os avisos também chegam por e-mail.",
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.notifications_active, color: Color(0xFF3A6490)),
                  const SizedBox(width: 8),
                  Text(
                    naoLidos == 0 ? "Avisos de coleta" : "Avisos de coleta ($naoLidos não lido${naoLidos > 1 ? 's' : ''})",
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_carregandoInicial)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_erro != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  child: Column(
                    children: [
                      Text(_erro!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                      const SizedBox(height: 10),
                      OutlinedButton(onPressed: _atualizar, child: const Text("TENTAR DE NOVO")),
                    ],
                  ),
                )
              else if (_avisos.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    "Nenhum aviso por enquanto. Quando uma coleta for agendada ou estiver na hora, ela aparece aqui.",
                    style: TextStyle(color: Colors.grey.shade600),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                ..._avisos.map(_tileAviso),
              const SizedBox(height: 20),
              _cardEmBreve(Icons.history, "Histórico de agendamentos", "Veja as coletas já realizadas e as próximas."),
              const SizedBox(height: 8),
              _cardEmBreve(Icons.attach_money, "Financeiro", "Fretes, valores e recebimentos."),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
