// DASHBOARD_MOTORISTA_APP.DART

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:geolocator/geolocator.dart';
import '../home_page_app.dart';
import '../audio_bridge.dart'; // mesma ponte de áudio já usada em home_page_app.dart
import 'gestao_frota_screen_app.dart';
import 'fotos_veiculo_screen_app.dart';
import 'perfil_motorista_screen_app.dart';
import 'login_screen_app.dart';
import 'termos_screen_app.dart';
import '../services/push_app.dart'; // NOVO: notificações com o app fechado
import '../services/api_service_app.dart';

class DashboardMotoristaScreen extends StatefulWidget {
  const DashboardMotoristaScreen({super.key});

  @override
  State<DashboardMotoristaScreen> createState() => _DashboardMotoristaScreenState();
}

class _DashboardMotoristaScreenState extends State<DashboardMotoristaScreen> with WidgetsBindingObserver {
  String _nomeMotorista = "Motorista";
  String _fotoUrl = "";

  final ApiService _api = ApiService();

  // NOVO: contador de notificações não lidas (avisos de coleta da frota,
  // quando o motorista dirige um caminhão de uma transportadora). Checado
  // por polling — mesmo padrão já usado pra buscar ofertas de carga —
  // ainda não é push de verdade (fase simples combinada primeiro).
  int _totalNotificacoesNaoLidas = 0;
  Timer? _timerNotificacoes;

  // NOVO: vínculo do motorista (autônomo x funcionário de transportadora)
  // e, se for funcionário, qual caminhão está atribuído a ele agora.
  // Motorista funcionário não escolhe caminhão nem disponibilidade — tudo
  // isso é decidido pela transportadora que o emprega.
  String _vinculo = 'AUTONOMO';
  String? _caminhaoAtribuidoPlaca;
  bool get _ehFuncionario => _vinculo == 'FUNCIONARIO';

  // NOVO: status de disponibilidade vindo do servidor — alimenta o
  // indicador "DISPONÍVEL/INDISPONÍVEL" aqui na tela inicial. Funcionário
  // é sempre considerado disponível enquanto o app está aberto (presença
  // automática); autônomo reflete o que ele mesmo definiu no switch da
  // tela de mapa, e isso agora persiste até ele mesmo desligar.
  bool _disponivel = false;
  bool get _statusDisponivelExibido => _ehFuncionario || _disponivel;

  // -----------------------------------------------------------------------
  // PRESENÇA AUTOMÁTICA (GPS) — FUNCIONÁRIO E TAC AUTÔNOMO
  // CORREÇÃO BUG "MOTORISTAS ONLINE": antes, disponibilidade + GPS só eram
  // enviados de dentro da tela do mapa (home_page_app.dart), e só depois
  // de um toque manual em "TOQUE PARA COMEÇAR". Um motorista funcionário
  // que ficasse parado aqui no Dashboard — o que é super comum, já que ele
  // não escolhe nada, só espera a transportadora designar uma carga —
  // nunca aparecia como online no painel da transportadora, mesmo com o
  // app aberto e o celular ligado. Por isso a presença dele (disponibi-
  // lidade=true + GPS periódico) é ativada automaticamente aqui, assim
  // que o vínculo é confirmado como FUNCIONARIO — sem depender de ele
  // entrar na tela do mapa nem tocar em nada.
  //
  // AMPLIADO: o TAC autônomo tinha o problema gêmeo — ele decide sozinho
  // QUANDO fica disponível (isso continua só dele, no switch da tela do
  // mapa, ou aqui não mexemos nisso), mas depois de ligar o switch uma
  // vez, o envio de GPS em si só acontecia enquanto ele estivesse DENTRO
  // da tela do mapa. Saiu de lá e voltou pro Dashboard (ou nunca chegou a
  // entrar lá, só ficou "disponível" desde o cadastro) e o GPS parava de
  // vir, então o matchmaking nunca achava ele — a oferta só chegava depois
  // de reabrir "Buscar Cargas". Agora, sempre que o servidor confirma que
  // ele está "disponível" (campo `disponivel` de /api/motorista/meu-
  // vinculo, atualizado a cada 20s pelo polling que já existia aqui), o
  // Dashboard também mantém o GPS periódico rodando sozinho — e desliga o
  // timer se ele ficar indisponível de novo. Só o funcionário continua
  // sendo marcado disponível automaticamente pelo servidor; pro TAC essa
  // decisão continua 100% dele.
  // -----------------------------------------------------------------------
  Timer? _timerPresencaFuncionario;
  bool _presencaAtivada = false;

  // NOVO: TAC autônomo também passa a nascer "disponível" sempre que abre
  // o app — igual ao funcionário — em vez de depender dele lembrar de ir
  // na tela do mapa e ligar o switch toda vez que entra. Essa flag garante
  // que isso só é forçado UMA VEZ por abertura do app (aqui no primeiro
  // /api/motorista/meu-vinculo que responder); se ele mesmo desligar
  // depois, durante a sessão, respeitamos a escolha dele e não ficamos
  // ligando de novo a cada 20s.
  bool _primeiraCargaVinculo = true;

  // NOVO: mesma "máquina de áudio" já usada em home_page_app.dart — toca
  // um alerta sonoro quando uma notificação nova chega enquanto o
  // motorista está parado no dashboard (antes, o som só existia dentro da
  // tela de navegação/mapa — quem nunca abria "Buscar Cargas" nunca ouvia
  // nada, mesmo tendo uma coleta designada).
  static const String _audioSrcWeb = 'assets/assets/audio/alerta_frete.mp3';
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _audioDesbloqueado = false;
  int? _ultimaContagemConhecida;

  // NOVO: lista de cargas/coletas agendadas pro caminhão que ele dirige
  // agora — aparece como "balões" na tela inicial, abaixo dos cards.
  List<dynamic> _agendadas = [];

  // -----------------------------------------------------------------------
  // ALERTA DE OFERTA DE CARGA — MOTORISTA TAC AUTÔNOMO PARADO NO DASHBOARD
  // CORREÇÃO: até aqui, a busca de ofertas do mercado (endpoint
  // /api/motorista/ofertas-pendentes, com Aceitar/Recusar) só rodava
  // dentro da tela do mapa (home_page_app.dart). Se o motorista autônomo
  // estivesse DISPONÍVEL mas parado aqui na tela inicial (com os cards),
  // uma oferta nova podia chegar e ele nunca saber, porque nada aqui
  // checava isso. Agora, sempre que ele estiver DISPONÍVEL, o Dashboard
  // também consulta — com o mesmo ritmo da tela do mapa — e, se achar
  // oferta nova, toca o alerta e mostra um pop-up com atalho pra tela do
  // mapa (onde a decisão de Aceitar/Recusar de fato acontece).
  // -----------------------------------------------------------------------
  Timer? _timerOfertasAutonomo;
  dynamic _ultimaOfertaIdAlertada;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PushApp.registrar(); // NOVO: cadastra este celular para receber avisos com o app fechado
    _carregarDados();
    _carregarVinculo();
    _carregarContagemNotificacoes();
    _carregarAgendadas();
    _timerNotificacoes = Timer.periodic(const Duration(seconds: 20), (timer) {
      _carregarContagemNotificacoes();
      _carregarAgendadas();
      // NOVO: mantém o indicador de DISPONÍVEL/INDISPONÍVEL sempre
      // atualizado, mesmo que o motorista fique parado aqui na tela
      // inicial sem nunca voltar da tela de mapa.
      _carregarVinculo();
    });
    // NOVO: mesmo ritmo de checagem (5s) que já existe dentro da tela do
    // mapa — assim o motorista autônomo é avisado de uma oferta nova tanto
    // faz em qual das duas telas ele estiver.
    _timerOfertasAutonomo = Timer.periodic(const Duration(seconds: 5), (timer) {
      _verificarOfertasPendentesAutonomo();
    });
    _inicializarAudio();
  }

  // NOVO: só faz sentido pro motorista TAC autônomo (o funcionário recebe
  // carga já designada direto, sem etapa de Aceitar/Recusar, avisado pelo
  // mecanismo de notificações genérico que já existe aqui embaixo). Só
  // consulta o servidor se ele estiver DISPONÍVEL — evita tráfego à toa
  // quando ele está offline.
  Future<void> _verificarOfertasPendentesAutonomo() async {
    if (_ehFuncionario || !_disponivel) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token');
      final url = Uri.parse('${ApiService.baseUrl}/api/motorista/ofertas-pendentes?t=${DateTime.now().millisecondsSinceEpoch}');
      final response = await http.get(url, headers: {'Authorization': 'Bearer $token'});
      if (!mounted) return;
      if (response.statusCode == 200) {
        final List ofertas = jsonDecode(response.body);
        if (ofertas.isNotEmpty) {
          final novaOferta = ofertas[0];
          final ofertaId = novaOferta['id'];
          // Só alerta uma vez por oferta — evita ficar repetindo o pop-up
          // a cada 5s enquanto a mesma oferta continua pendente.
          if (_ultimaOfertaIdAlertada != ofertaId) {
            _ultimaOfertaIdAlertada = ofertaId;
            _tocarAlertaSonoro();
            _mostrarPopUpNovaOfertaCarga(novaOferta);
          }
        } else {
          _ultimaOfertaIdAlertada = null;
        }
      }
    } catch (e) {
      debugPrint("Erro ao verificar ofertas pendentes (dashboard): $e");
    }
  }

  // NOVO: pop-up de "chegou oferta nova" — a decisão de Aceitar/Recusar de
  // verdade continua acontecendo só na tela do mapa (onde já existe todo o
  // painel com rota, tempo, distância etc.); aqui é só o aviso + atalho.
  void _mostrarPopUpNovaOfertaCarga(Map<String, dynamic> oferta) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.local_shipping, color: Colors.green, size: 40),
        title: const Text("Nova oferta de carga!", textAlign: TextAlign.center),
        content: Text(
          "${oferta['col_cidade'] ?? '?'}/${oferta['col_uf'] ?? '?'}  →  ${oferta['ent_cidade'] ?? '?'}/${oferta['ent_uf'] ?? '?'}",
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("DEPOIS")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () async {
              Navigator.pop(ctx);
              await Navigator.push(context, MaterialPageRoute(builder: (_) => HomePage(motoristaId: 0, vinculo: _vinculo)));
              _carregarVinculo();
            },
            child: const Text("VER OFERTA", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

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

  // Chamado no primeiro toque na tela — precisa acontecer DENTRO de um
  // gesto do usuário (regra do iOS Safari), senão o som nunca funciona
  // quando o alerta dispara sozinho, via polling, sem toque nenhum.
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
      debugPrint("🔐 Áudio destravado a partir do dashboard!");
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
      debugPrint("🔊 Alerta sonoro disparado pelo dashboard!");
    } catch (e) {
      debugPrint("Erro ao tocar áudio: $e");
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timerNotificacoes?.cancel();
    _timerPresencaFuncionario?.cancel();
    _timerOfertasAutonomo?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  // NOVO: se o app voltar do segundo plano (motorista deu uma olhada em
  // outro app e voltou), manda um GPS fresco na hora — não precisa esperar
  // o próximo ciclo do timer de 30s pra ele voltar a aparecer como online.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // AMPLIADO: mesma lógica do funcionário agora vale pro TAC autônomo
    // quando ele está disponível — o timer de 30s fica pausado/atrasado
    // enquanto o app está em segundo plano (normal no Android e no iOS),
    // então ao voltar pra frente mandamos um GPS na hora em vez de esperar
    // o próximo ciclo.
    if (state == AppLifecycleState.resumed && (_ehFuncionario || _disponivel)) {
      _enviarLocalizacaoAtual();
    }
  }

  Future<void> _carregarDados() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _nomeMotorista = prefs.getString('usuario_nome') ?? "Motorista";
      _fotoUrl = prefs.getString('foto_url') ?? "";
    });
  }

  // NOVO: busca vínculo e caminhão atribuído direto do servidor — assim,
  // se a transportadora atribuir/trocar o caminhão dele, ou o vínculo for
  // ajustado, o app reflete isso sem precisar deslogar e logar de novo.
  Future<void> _carregarVinculo() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token');
      final response = await http.get(
        Uri.parse('${ApiService.baseUrl}/api/motorista/meu-vinculo'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        final dados = jsonDecode(response.body);
        final vinculoRecebido = dados['vinculo'] ?? 'AUTONOMO';
        if (mounted) {
          setState(() {
            _vinculo = vinculoRecebido;
            _caminhaoAtribuidoPlaca = dados['caminhao_atribuido_placa'];
            _disponivel = dados['disponivel'] == true;
          });
        }

        // NOVO: na primeira vez que o vínculo é confirmado nesta abertura
        // do app, se for TAC autônomo e ele NÃO estiver disponível ainda,
        // liga automaticamente — assim ele já entra "pronto pra trabalhar"
        // sem precisar lembrar de ir na tela do mapa ligar o switch. Só
        // acontece uma vez por abertura (guardado por _primeiraCargaVinculo);
        // se ele desligar manualmente depois, durante a sessão, o app
        // respeita e não liga de novo sozinho.
        if (_primeiraCargaVinculo) {
          _primeiraCargaVinculo = false;
          if (vinculoRecebido == 'AUTONOMO' && !_disponivel) {
            await _marcarDisponivelServidor();
            if (mounted) setState(() => _disponivel = true);
          }
        }

        // NOVO: motorista funcionário não escolhe — abriu o app, já está
        // disponível, então liga a presença automática incondicionalmente.
        // O TAC autônomo entra aqui sempre que estiver disponível (seja
        // porque ele mesmo ligou no switch da tela do mapa, seja pelo
        // auto-ligar acima) — continuamos mandando GPS enquanto isso for
        // true, sem forçar nada além do que já foi decidido. Se ele ficar
        // indisponível depois, desliga o timer — não faz sentido gastar
        // GPS/bateria à toa.
        final deveManterGpsAutomatico = vinculoRecebido == 'FUNCIONARIO' || _disponivel;
        if (deveManterGpsAutomatico && !_presencaAtivada) {
          _presencaAtivada = true;
          _ativarPresencaAutomatica(forcarDisponivelServidor: vinculoRecebido == 'FUNCIONARIO');
        } else if (!deveManterGpsAutomatico && _presencaAtivada) {
          _presencaAtivada = false;
          _timerPresencaFuncionario?.cancel();
        }
      }
    } catch (e) {
      debugPrint("Erro ao carregar vínculo: $e");
    }
  }

  // NOVO: liga a "presença" (GPS periódico) — pro funcionário, também
  // força disponibilidade=true no servidor (ele não escolhe isso); pro
  // TAC autônomo, só manda GPS, sem mexer na disponibilidade que ele
  // mesmo já definiu. Manda o primeiro GPS na hora, e depois mantém um
  // timer periódico (30s, bem dentro da janela de frescor de 2min que o
  // matchmaking exige) rodando durante toda a sessão do app, mesmo que o
  // motorista nunca entre na tela do mapa.
  Future<void> _ativarPresencaAutomatica({required bool forcarDisponivelServidor}) async {
    if (forcarDisponivelServidor) {
      await _marcarDisponivelServidor();
    }
    await _enviarLocalizacaoAtual();
    _timerPresencaFuncionario?.cancel();
    _timerPresencaFuncionario = Timer.periodic(const Duration(seconds: 30), (timer) {
      _enviarLocalizacaoAtual();
    });
  }

  Future<void> _marcarDisponivelServidor() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token');
      await http.post(
        Uri.parse('${ApiService.baseUrl}/api/motorista/disponibilidade'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode({"disponivel": true}),
      );
      debugPrint("✅ Presença do funcionário ativada no servidor (disponibilidade=true).");
    } catch (e) {
      debugPrint("Erro ao marcar disponibilidade do funcionário: $e");
    }
  }

  Future<void> _enviarLocalizacaoAtual() async {
    try {
      bool servicoAtivo = await Geolocator.isLocationServiceEnabled();
      if (!servicoAtivo) return;

      LocationPermission permissao = await Geolocator.checkPermission();
      if (permissao == LocationPermission.denied) {
        permissao = await Geolocator.requestPermission();
        if (permissao == LocationPermission.denied) return;
      }
      if (permissao == LocationPermission.deniedForever) return;

      // CORRIGIDO: sem limite de tempo nem precisão definida, num
      // celular com sinal de GPS mais fraco isso podia ficar esperando
      // MUITO tempo por uma localização perfeita antes de mandar
      // qualquer coisa — explica o "delay gigante" só nesse aparelho.
      // Agora, se não conseguir uma posição fresca em 10s, usa a
      // última conhecida (ainda é bem melhor que nada).
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high, timeLimit: const Duration(seconds: 10));
      } catch (_) {
        pos = await Geolocator.getLastKnownPosition();
      }
      if (pos == null) return;

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token');
      await http.post(
        Uri.parse('${ApiService.baseUrl}/api/motorista/localizacao'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode({"latitude": pos.latitude, "longitude": pos.longitude}),
      );
      debugPrint("📍 GPS do funcionário enviado a partir do dashboard.");
    } catch (e) {
      debugPrint("Erro ao enviar localização em segundo plano (dashboard): $e");
    }
  }

  Future<void> _carregarContagemNotificacoes() async {
    try {
      final total = await _api.contarNotificacoesMotoristaNaoLidas();
      if (mounted) {
        // NOVO: se a contagem SUBIU desde a última checagem, chegou algo
        // novo (aviso de coleta, carga designada, etc.) — toca o alerta E
        // mostra um pop-up na tela, mesmo que o motorista esteja parado
        // aqui no dashboard e nunca tenha aberto a tela de mapa/ofertas.
        final subiu = _ultimaContagemConhecida != null && total > _ultimaContagemConhecida!;
        setState(() => _totalNotificacoesNaoLidas = total);
        _ultimaContagemConhecida = total;
        if (subiu) {
          _tocarAlertaSonoro();
          _mostrarPopUpNovaNotificacao();
          _carregarAgendadas(); // atualiza a lista de balões na hora
        }
      }
    } catch (e) {
      debugPrint("Erro ao carregar contagem de notificações: $e");
    }
  }

  // NOVO: pop-up que "pula" na tela avisando de uma carga/coleta nova,
  // além do som — busca a notificação mais recente pra mostrar o texto
  // dela direto no pop-up, sem precisar abrir o sino. Se for do tipo
  // COLETAR_AGORA (chegou a hora exata da coleta), o pop-up ganha um
  // botão "COLETAR" que já leva pra tela de navegação.
  Future<void> _mostrarPopUpNovaNotificacao() async {
    String mensagem = "Você tem uma nova carga agendada!";
    String tipo = 'GERAL';
    dynamic referenciaId;
    String? referenciaOrigem;
    try {
      final lista = await _api.getNotificacoesMotorista();
      if (lista.isNotEmpty) {
        mensagem = lista.first['mensagem']?.toString() ?? mensagem;
        tipo = lista.first['tipo']?.toString() ?? 'GERAL';
        referenciaId = lista.first['referencia_id'];
        referenciaOrigem = lista.first['referencia_origem']?.toString();
      }
    } catch (_) {}
    if (!mounted) return;

    final ehColetarAgora = tipo == 'COLETAR_AGORA' && referenciaId != null && referenciaOrigem != null;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(ehColetarAgora ? Icons.local_shipping : Icons.notifications_active, color: Colors.blue, size: 40),
        title: Text(ehColetarAgora ? "Coletar Carga Programada" : "Nova carga!", textAlign: TextAlign.center),
        content: Text(mensagem, textAlign: TextAlign.center),
        actionsAlignment: MainAxisAlignment.center,
        actions: ehColetarAgora
            ? [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("DEPOIS")),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _abrirColeta(referenciaOrigem!, referenciaId);
                  },
                  child: const Text("COLETAR", style: TextStyle(color: Colors.white)),
                ),
              ]
            : [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text("OK"))],
      ),
    );
  }

  // NOVO: busca o detalhe completo (endereço pra geolocalizar) e leva
  // direto pra tela de navegação — mesmo caminho usado pelo TAC quando
  // aceita uma oferta, só que sem passar pela etapa de aceitar/recusar.
  Future<void> _abrirColeta(String origem, dynamic id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token');
      final response = await http.get(
        Uri.parse('${ApiService.baseUrl}/api/motorista/detalhe-agendada?origem=$origem&id=$id'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200 && mounted) {
        final detalhe = jsonDecode(response.body);

        // NOVO: TRAVA DE SEGURANÇA — se a transportadora ainda não
        // informou o destino (comum: ela cadastra a coleta só com o
        // endereço de origem, e completa depois), o app não deixa
        // seguir pra tela de navegação. Sem isso, o cálculo de rota
        // fica sem destino de verdade e dá distância absurda (chegou a
        // calcular mais de 2.000km num teste).
        final faltaDestino = (detalhe['destinatario_nome'] == null || detalhe['destinatario_nome'].toString().trim().isEmpty) ||
            (detalhe['ent_cidade'] == null || detalhe['ent_cidade'].toString().trim().isEmpty) ||
            (detalhe['ent_uf'] == null || detalhe['ent_uf'].toString().trim().isEmpty);

        if (faltaDestino) {
          if (mounted) await _mostrarAvisoDestinoFaltando();
          return;
        }

        Navigator.push(context, MaterialPageRoute(
          builder: (_) => HomePage(motoristaId: 0, vinculo: _vinculo, cargaInicial: detalhe),
        ));
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Não foi possível carregar os detalhes dessa carga."), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Erro ao abrir coleta: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  // NOVO: aviso bem chamativo, ocupa o meio da tela — a ideia é que dê
  // pra ver de longe que tem algo pendente, forçando o motorista a
  // ligar pra transportadora antes de qualquer coisa.
  Future<void> _mostrarAvisoDestinoFaltando() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red[50],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.red[300]!, width: 2)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error, color: Colors.red, size: 56),
            const SizedBox(height: 12),
            const Text(
              "DESTINO AINDA NÃO INFORMADO",
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.red),
            ),
            const SizedBox(height: 12),
            const Text(
              "A transportadora ainda não cadastrou pra onde essa carga vai. Você não consegue coletar sem essa informação.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 10),
            const Text(
              "Ligue pra empresa e avise que precisa do destino pra poder aceitar essa coleta.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          Center(
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx),
              child: const Text("ENTENDI", style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  // NOVO: busca as cargas/coletas já agendadas pro caminhão que ele
  // dirige agora — vira a lista de "balões" na tela inicial.
  Future<void> _carregarAgendadas() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('jwt_token');
      final response = await http.get(
        Uri.parse('${ApiService.baseUrl}/api/motorista/minhas-agendadas'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200 && mounted) {
        setState(() => _agendadas = jsonDecode(response.body));
      }
    } catch (e) {
      debugPrint("Erro ao carregar agendadas: $e");
    }
  }

  // Abre a lista de avisos de coleta (dia/hora/local marcados pela
  // transportadora). Ao fechar, marca tudo como lido — igual já
  // funciona no painel web do embarcador.
  void _mostrarNotificacoes() {
    List<dynamic> notificacoes = [];
    bool carregando = true;
    String? erro;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            if (carregando && erro == null && notificacoes.isEmpty) {
              _api.getNotificacoesMotorista().then((lista) {
                notificacoes = lista;
                carregando = false;
                setStateDialog(() {});
              }).catchError((e) {
                erro = e.toString().replaceAll("Exception: ", "");
                carregando = false;
                setStateDialog(() {});
              });
            }

            return AlertDialog(
              title: const Text("Avisos de Coleta", style: TextStyle(fontWeight: FontWeight.bold)),
              content: SizedBox(
                width: double.maxFinite,
                child: carregando
                    ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()))
                    : erro != null
                        ? Text(erro!, style: const TextStyle(color: Colors.red))
                        : notificacoes.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 30),
                                child: Text("Nenhum aviso por aqui.", style: TextStyle(color: Colors.grey)),
                              )
                            : ConstrainedBox(
                                constraints: const BoxConstraints(maxHeight: 400),
                                child: ListView.separated(
                                  shrinkWrap: true,
                                  itemCount: notificacoes.length,
                                  separatorBuilder: (_, __) => const Divider(height: 1),
                                  itemBuilder: (ctx2, i) {
                                    final n = notificacoes[i];
                                    final lida = n['lida'] == true;
                                    return ListTile(
                                      leading: Icon(
                                        lida ? Icons.notifications_none : Icons.notifications_active,
                                        color: lida ? Colors.grey : Colors.orange,
                                      ),
                                      title: Text(
                                        n['mensagem']?.toString() ?? '',
                                        style: TextStyle(fontSize: 13, fontWeight: lida ? FontWeight.normal : FontWeight.bold),
                                      ),
                                    );
                                  },
                                ),
                              ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    if (notificacoes.any((n) => n['lida'] != true)) {
                      try {
                        await _api.marcarTodasNotificacoesMotoristaLidas();
                      } catch (e) {
                        // silencioso — o contador recalcula no próximo polling
                      }
                      _carregarContagemNotificacoes();
                    }
                    Navigator.pop(ctx);
                  },
                  child: const Text("FECHAR"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSinoNotificacoes() {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const Icon(Icons.notifications, color: Colors.white),
          onPressed: _mostrarNotificacoes,
          tooltip: "Avisos de coleta",
        ),
        if (_totalNotificacoesNaoLidas > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              child: Text(
                _totalNotificacoesNaoLidas > 9 ? '9+' : '$_totalNotificacoesNaoLidas',
                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }

  // Abre a tela de perfil e, quando o motorista voltar (com ou sem alterar a
  // foto), recarrega os dados locais — assim o avatar do topo já aparece
  // atualizado na hora, sem precisar deslogar e logar de novo.
  Future<void> _abrirPerfil() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const PerfilMotoristaScreen()));
    _carregarDados();
  }

  void _sair() async {
    await PushApp.desregistrar(); // NOVO: este celular para de receber avisos desta conta
    final prefs = await SharedPreferences.getInstance();
    // Apenas removemos o token e os dados locais. Não é necessário chamar a API.
    await prefs.remove('jwt_token');
    await prefs.remove('usuario_nome');
    await prefs.remove('foto_url');

    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  // NOVO: quando o caminhão que aparece pro funcionário não bate com o
  // que ele está de fato dirigindo. Por enquanto só orienta a falar com a
  // central — o aviso automático pra transportadora fica pra uma próxima
  // etapa.
  void _avisarCaminhaoIncorreto() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Caminhão não confere?"),
        content: const Text(
          "Entre em contato com a central da sua empresa pra corrigir qual caminhão está atribuído a você no sistema.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("ENTENDI")),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // O Listener (não GestureDetector) capta o primeiro toque na tela sem
    // "roubar" o gesto dos botões por baixo — só usamos ele pra destravar
    // o áudio silenciosamente, o toque continua funcionando normal em
    // tudo que já existia.
    return Listener(
      onPointerDown: (_) => _destravarAudioSeNecessario(),
      child: Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        backgroundColor: Colors.blue[900],
        elevation: 0,
        toolbarHeight: 70,
        leadingWidth: 76,
        // Avatar da foto + "Editar Perfil" logo abaixo, no canto superior esquerdo
        leading: InkWell(
          onTap: _abrirPerfil,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.white,
                  backgroundImage: _fotoUrl.isNotEmpty ? NetworkImage(_fotoUrl) : null,
                  child: _fotoUrl.isEmpty ? Icon(Icons.person, color: Colors.blue[900], size: 20) : null,
                ),
                const SizedBox(height: 2),
                const Text("Editar Perfil", style: TextStyle(color: Colors.white70, fontSize: 9)),
              ],
            ),
          ),
        ),
        title: Image.asset('assets/logo.png', height: 40),
        centerTitle: true,
        actions: [
          _buildSinoNotificacoes(),
          IconButton(
            icon: const Icon(Icons.notifications_active_outlined, color: Colors.white),
            tooltip: "Testar notificação",
            onPressed: () => PushApp.testar(context),
          ),
          IconButton(
            icon: const Icon(Icons.policy_outlined, color: Colors.white),
            tooltip: "Termos e Privacidade",
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TermosTextoScreen())),
          ),
          IconButton(icon: const Icon(Icons.logout, color: Colors.white), onPressed: _sair)
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header Azul - Estilo Fintech
            Container(
              padding: const EdgeInsets.only(left: 25, right: 25, bottom: 26, top: 14),
              decoration: BoxDecoration(
                color: Colors.blue[900],
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(30),
                  bottomRight: Radius.circular(30),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Olá, $_nomeMotorista", style: const TextStyle(color: Colors.white70, fontSize: 14)),
                  const SizedBox(height: 6),
                  // NOVO: indicador de status atual — DISPONÍVEL (verde) ou
                  // INDISPONÍVEL (vermelho). Pro autônomo, reflete o que ele
                  // mesmo definiu no switch da tela de mapa (e agora
                  // persiste até ele mesmo desligar); pro funcionário, é
                  // sempre DISPONÍVEL enquanto o app está aberto.
                  Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _statusDisponivelExibido ? Colors.greenAccent : Colors.redAccent,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _statusDisponivelExibido ? "DISPONÍVEL" : "INDISPONÍVEL",
                        style: TextStyle(
                          color: _statusDisponivelExibido ? Colors.greenAccent : Colors.redAccent,
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_ehFuncionario) ...[
                    const Text("Caminhão Atribuído", style: TextStyle(color: Colors.white70, fontSize: 12.5)),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          _caminhaoAtribuidoPlaca != null ? Icons.local_shipping : Icons.local_shipping_outlined,
                          color: Colors.white,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _caminhaoAtribuidoPlaca ?? "Nenhum caminhão atribuído",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: _caminhaoAtribuidoPlaca != null ? 24 : 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 10),
                        InkWell(
                          onTap: _avisarCaminhaoIncorreto,
                          child: const Text(
                            "Não está correto?",
                            style: TextStyle(color: Colors.white70, fontSize: 11.5, decoration: TextDecoration.underline),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    // NOVO: o TAC autônomo também passa a ver aqui qual
                    // caminhão está ativo agora (o que ele escolheu em
                    // "Minha Frota") — antes só o funcionário via isso.
                    // Diferente do funcionário, ele pode trocar quando
                    // quiser, então o link leva direto pra tela de frota
                    // em vez de mandar falar com a central.
                    const Text("Caminhão Ativo", style: TextStyle(color: Colors.white70, fontSize: 12.5)),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          _caminhaoAtribuidoPlaca != null ? Icons.local_shipping : Icons.local_shipping_outlined,
                          color: Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _caminhaoAtribuidoPlaca ?? "Nenhum caminhão ativo",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: _caminhaoAtribuidoPlaca != null ? 20 : 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 10),
                        InkWell(
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GestaoFrotaScreen())),
                          child: const Text(
                            "Trocar",
                            style: TextStyle(color: Colors.white70, fontSize: 11.5, decoration: TextDecoration.underline),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Text("Resumo de Ganhos", style: TextStyle(color: Colors.white, fontSize: 13)),
                    const SizedBox(height: 3),
                    const Row(
                      children: [
                        Text("R\$ ", style: TextStyle(color: Colors.white70, fontSize: 18)),
                        Text("0,00", style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            // Grid de Acesso Rápido
            Transform.translate(
              offset: const Offset(0, -20),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    _botaoGigante(
                      context,
                      "BUSCAR CARGAS",
                      "Ir para o mapa de ofertas",
                      Icons.map_outlined,
                      Colors.green[700]!,
                      () async {
                        // NOVO: ao voltar da tela de mapa, reconsulta o
                        // vínculo/disponibilidade — se o motorista ligou ou
                        // desligou o switch de DISPONÍVEL por lá, o
                        // indicador aqui na tela inicial reflete na hora.
                        await Navigator.push(context, MaterialPageRoute(builder: (_) => HomePage(motoristaId: 0, vinculo: _vinculo)));
                        _carregarVinculo();
                      }
                    ),
                    const SizedBox(height: 15),
                    // NOVO: fotos do caminhão e da carreta acoplada (as
                    // embarcadoras pedem antes da entrada no pátio).
                    _botaoGigante(
                      context,
                      "FOTOS DO CAMINHÃO",
                      "Caminhão e carreta acoplada",
                      Icons.photo_camera,
                      Colors.teal[700]!,
                      () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FotosVeiculoScreen())),
                    ),
                    const SizedBox(height: 15),
                    if (_ehFuncionario) ...[
                      // Funcionário: sem Minha Frota (caminhão já vem atribuído
                      // pela transportadora) nem Financeiro (pagamento é direto
                      // com a empresa, fora do app) — Agenda no lugar delas.
                      Row(
                        children: [
                          Expanded(child: _botaoQuadrado(context, "Agenda", Icons.event_note, Colors.indigo[700]!, _abrirAgenda)),
                          const SizedBox(width: 15),
                          Expanded(child: _botaoQuadrado(context, "Meu Perfil", Icons.person, Colors.orange[800]!, _abrirPerfil)),
                          const SizedBox(width: 15),
                          Expanded(child: _botaoQuadrado(context, "Histórico", Icons.history, Colors.grey[700]!, () {})),
                        ],
                      ),
                    ] else ...[
                      Row(
                        children: [
                          Expanded(child: _botaoQuadrado(context, "Minha Frota", Icons.local_shipping, Colors.blue[800]!, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GestaoFrotaScreen())))),
                          const SizedBox(width: 15),
                          Expanded(child: _botaoQuadrado(context, "Meu Perfil", Icons.person, Colors.orange[800]!, _abrirPerfil)),
                        ],
                      ),
                      const SizedBox(height: 15),
                      Row(
                        children: [
                          Expanded(child: _botaoQuadrado(context, "Financeiro", Icons.account_balance_wallet, Colors.purple[700]!, () {})),
                          const SizedBox(width: 15),
                          Expanded(child: _botaoQuadrado(context, "Histórico", Icons.history, Colors.grey[700]!, () {})),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // NOVO: lista de cargas/coletas já agendadas pro caminhão que
            // ele dirige agora — "balões" com ID, data, hora e cidades.
            if (_agendadas.isNotEmpty)
              Transform.translate(
                offset: const Offset(0, -6),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Agendado", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.black87)),
                      const SizedBox(height: 10),
                      ..._agendadas.map((a) => _balaoAgendado(a)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
    );
  }

  // NOVO: cada "balão" da lista de agendados — ID, data/hora da coleta,
  // cidade de coleta e de entrega.
  Widget _balaoAgendado(Map<String, dynamic> a) {
    String dataHora = '';
    if (a['data_coleta'] != null) {
      try {
        final d = DateTime.parse(a['data_coleta'].toString());
        dataHora = "${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}";
      } catch (_) {
        dataHora = a['data_coleta'].toString();
      }
      if (a['hora_coleta'] != null && a['hora_coleta'].toString().isNotEmpty) {
        final partes = a['hora_coleta'].toString().split(':');
        if (partes.length >= 2) dataHora += " ${partes[0].padLeft(2, '0')}:${partes[1].padLeft(2, '0')}";
      }
    }
    final origemMercado = a['origem'] == 'mercado';

    return InkWell(
      onTap: () => _abrirDetalheAgendada(a, dataHora),
      borderRadius: BorderRadius.circular(12),
      child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: origemMercado ? Colors.indigo[100]! : Colors.teal[100]!),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 3))],
      ),
      child: Row(
        children: [
          Icon(Icons.local_shipping, color: origemMercado ? Colors.indigo : Colors.teal, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Carga #${a['id']}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                const SizedBox(height: 3),
                Text(dataHora, style: TextStyle(fontSize: 12.5, color: Colors.blue[900], fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                  "${a['col_cidade'] ?? ''}/${a['col_uf'] ?? ''}  →  ${a['ent_cidade'] ?? ''}/${a['ent_uf'] ?? ''}",
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
        ],
      ),
      ),
    );
  }

  // NOVO: toca no balão → mostra detalhe (ID, data/hora, coleta/entrega)
  // com botão de Fechar ou Coletar. "Coletar" busca o endereço completo
  // e já leva pra tela de navegação.
  void _abrirDetalheAgendada(Map<String, dynamic> a, String dataHora) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Carga #${a['id']}", style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _linhaDetalhe("Data/Hora", dataHora),
            _linhaDetalhe("Coleta", "${a['col_cidade'] ?? ''}/${a['col_uf'] ?? ''}"),
            _linhaDetalhe("Entrega", "${a['ent_cidade'] ?? ''}/${a['ent_uf'] ?? ''}"),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("FECHAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () {
              Navigator.pop(ctx);
              _abrirColeta(a['origem'], a['id']);
            },
            child: const Text("COLETAR", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _linhaDetalhe(String label, String valor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13))),
          Expanded(child: Text(valor, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
        ],
      ),
    );
  }

  // Agenda do funcionário — a lista de verdade já aparece direto na tela
  // inicial (seção "Agendado", logo abaixo dos cards). Esse botão só
  // avisa quando não tem nada agendado ainda, pra não deixar sem resposta.
  void _abrirAgenda() {
    if (_agendadas.isNotEmpty) return; // a lista já está visível na tela
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Agenda"),
        content: const Text("Nenhuma coleta ou carga agendada pra você no momento."),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("ENTENDI"))],
      ),
    );
  }

  Widget _botaoGigante(BuildContext context, String titulo, String subtitulo, IconData icone, Color cor, VoidCallback acao) {
    return InkWell(
      onTap: acao,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 5))]),
        child: Row(
          children: [
            CircleAvatar(radius: 24, backgroundColor: cor.withOpacity(0.1), child: Icon(icone, size: 24, color: cor)),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(titulo, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)), const SizedBox(height: 3), Text(subtitulo, style: const TextStyle(color: Colors.grey, fontSize: 12.5))])),
            const Icon(Icons.arrow_forward_ios, color: Colors.grey, size: 16)
          ],
        ),
      ),
    );
  }

  Widget _botaoQuadrado(BuildContext context, String titulo, IconData icone, Color cor, VoidCallback acao) {
    return InkWell(
      onTap: acao,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 25),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 5))]),
        child: Column(
          children: [
            Icon(icone, size: 40, color: cor),
            const SizedBox(height: 10),
            Text(titulo, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87)),
          ],
        ),
      ),
    );
  }
}


