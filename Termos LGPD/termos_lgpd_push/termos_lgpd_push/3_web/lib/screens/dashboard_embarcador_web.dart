//
// DASHBOARD_EMBARCADOR_WEB.DART
//
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/api_service.dart';
import '../widgets/taclog_widgets_web.dart' show TaclogSeletorTipoAgrupado;
import 'tela_perfil_embarcador_web.dart'; // NOVO: Meus Dados (perfil da empresa)
import 'login_screen_web.dart';
import 'termos_aceite_web.dart'; // NOVO: Termos de Uso e Política de Privacidade
import 'mapa_frota_view_web.dart'; // <-- IMPORT ADICIONADO AQUI PARA RECONHECER A TELA
import 'tela_frota_embarcador_web.dart'; // Frota — agora com abas: Caminhões / Carretas / Motoristas
import 'tela_configuracoes_embarcador_web.dart'; // Tela de configurações da transportadora
import 'tela_agendamentos_embarcador_web.dart'; // NOVO: Tela de Agendamentos (cargas AGENDADA)
import 'tela_coletas_frota_embarcador_web.dart'; // NOVO: Coletas da Frota Própria
import 'tela_ofertas_mercado_embarcador_web.dart'; // NOVO: Ofertas do Mercado para a Frota
import 'tela_oferta_carga_web.dart'; // NOVO: Publicar carga em 2 passos, tema TACLOG
import 'tela_coleta_propria_web.dart'; // NOVO: Coleta Própria em 2 passos, tema TACLOG
import 'tela_funcionarios_embarcador_web.dart'; // NOVO: Gestão de Funcionários da transportadora (só o titular)
import 'tela_log_sistema_embarcador_web.dart'; // NOVO: Log do Sistema (logins) — só ADMIN

class DashboardEmbarcadorScreen extends StatefulWidget {
  const DashboardEmbarcadorScreen({super.key});

  @override
  State<DashboardEmbarcadorScreen> createState() => _DashboardEmbarcadorScreenState();
}

class _DashboardEmbarcadorScreenState extends State<DashboardEmbarcadorScreen> {
  final ApiService _api = ApiService();
  int _indiceSelecionado = 0;
  Map<String, dynamic>? _coletaParaEditar; // NOVO: qual coleta abrir em modo edição, quando vem de Agendamentos

  // NOVO: menu lateral recolhível (mesma ideia do Asaas) — colapsado, o
  // menu vira só uma faixa de ícones e a tela de conteúdo ganha o espaço
  // que sobrou.
  bool _menuColapsado = false;
  static const double _larguraMenuAberto = 220;
  static const double _larguraMenuColapsado = 76;

  final List<int> _historicoAbas = [];
  List<dynamic> _cargas = [];
  Map<String, dynamic> _resumo = {"pagar": 0, "aberto": 0};

  // NOVO: formato brasileiro de moeda — ponto de milhar, vírgula decimal
  // (22000.00 -> 22.000,00). Sem depender de nenhum pacote de i18n extra.
  String _formatarMoedaBr(dynamic valor) {
    final numero = (valor is num ? valor : double.tryParse(valor?.toString() ?? '0') ?? 0).toDouble();
    final partes = numero.toStringAsFixed(2).split('.');
    final inteiro = partes[0].replaceAll('-', '');
    final centavos = partes[1];
    final buffer = StringBuffer();
    for (int i = 0; i < inteiro.length; i++) {
      final posicaoDaDireita = inteiro.length - i;
      buffer.write(inteiro[i]);
      if (posicaoDaDireita > 1 && posicaoDaDireita % 3 == 1) buffer.write('.');
    }
    final sinal = numero < 0 ? '-' : '';
    return '$sinal${buffer.toString()},$centavos';
  }

  int _totalMotoristasAtivos = 0;
  int _totalMotoristasLivres = 0;
  List<dynamic> _listaMotoristasAtivos = [];

  bool _isTransportadora = false;
  // NOVO: ADMIN (titular ou funcionário com perfil ADMIN) vê o item de
  // menu "Log do Sistema" — OPERADOR não.
  bool _isAdmin = false;

  // NOVO: logo da própria empresa (substitui o logo padrão do TACLOG no
  // menu lateral, quando cadastrado) e nome/razão social exibido no topo.
  String _logoUrl = '';
  String _nomeEmpresa = '';

  // NOVO: se quem logou foi um FUNCIONÁRIO (e não o titular direto com
  // CNPJ), guarda o nome dele pra mostrar no cabeçalho — e esconde a
  // gestão de "Usuários" (funcionários), que só o titular pode acessar.
  String _nomeFuncionarioLogado = '';
  bool get _ehTitular => _nomeFuncionarioLogado.isEmpty;

  int _totalNotificacoesNaoLidas = 0;

  bool _expCadastros = false;
  // NOVO: rolagem do menu lateral inteiro (logo + itens + Config/Sair), pra
  // que em tela baixa os subitens de Cadastros não fiquem escondidos.
  final ScrollController _menuScroll = ScrollController();
  bool _expDocumentos = false;
  bool _expDocFrete = false;
  bool _expDocCarga = false;
  bool _expDocVeiculo = false;
  bool _expRadar = false;

  bool _isLoading = false;
  Timer? _timerMonitoramento;

  int? _editandoCargaId;

  final _descCtrl = TextEditingController();
  final _pesoCtrl = TextEditingController();
  final _valorCtrl = TextEditingController();
  final _pedagioCtrl = TextEditingController();
  final _chaveNfeCtrl = TextEditingController();
  // Classificação de mercado exigida (tabelas tipos_veiculo / tipos_carroceria)
  String? _classificacaoCarroceria;
  String? _classificacaoVeiculo;

  final _colCepCtrl = TextEditingController();
  final _colRuaCtrl = TextEditingController();
  final _colNumCtrl = TextEditingController();
  final _colBairroCtrl = TextEditingController();
  final _colCidadeCtrl = TextEditingController();
  final _colUfCtrl = TextEditingController();
  final _colNomeCtrl = TextEditingController();

  final _colLatManualCtrl = TextEditingController();
  final _colLngManualCtrl = TextEditingController();

  DateTime? _dataColetaSelecionada;
  TimeOfDay? _horaColetaSelecionada;
  int _antecedenciaMinutos = 0;
  bool _preferenciaFrotaPropria = false;

  // NOVO: designação manual de um caminhão específico da frota (em vez
  // da busca automática pelo mais próximo). caminhaoDesignado guarda o
  // mapa completo do caminhão escolhido (placa, tipo, etc.), não só o
  // ID, pra poder mostrar a placa no formulário sem precisar buscar de
  // novo.
  bool _escolherCaminhaoManualmente = false;
  Map<String, dynamic>? _caminhaoDesignado;

  final Map<int, String> _opcoesAntecedencia = const {
    0: 'Sem antecedência (disparar exatamente na hora da coleta)',
    30: '30 minutos antes',
    60: '1 hora antes',
    120: '2 horas antes',
    240: '4 horas antes',
    480: '8 horas antes',
    720: '12 horas antes',
    1440: '24 horas antes',
  };

  final _entCepCtrl = TextEditingController();
  final _entRuaCtrl = TextEditingController();
  final _entNumCtrl = TextEditingController();
  final _entBairroCtrl = TextEditingController();
  final _entCidadeCtrl = TextEditingController();
  final _entUfCtrl = TextEditingController();
  final _entNomeCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _carregarCargas();
    _carregarPerfilTransportadora();
    _carregarPerfilAcesso();
    _carregarDadosEmpresa();
    _carregarContagemNotificacoes();
    _carregarIndicadores();
    _timerMonitoramento = Timer.periodic(const Duration(seconds: 5), (timer) {
      _carregarContagemNotificacoes();
      // CORRIGIDO: antes só atualizava sozinho na aba "Match & Cargas" —
      // a tela "Início" (índice 0) nunca recebia atualização automática,
      // então os cards (Agendadas, Finalizadas, Total Publicadas etc.)
      // ficavam "congelados" no que estava na tela quando ela abriu,
      // mesmo com cargas novas entrando por outro caminho (Agendamentos,
      // por exemplo).
      if ((_indiceSelecionado == 0 || _indiceSelecionado == 1) && mounted && _editandoCargaId == null) {
        _carregarCargas(silencioso: true);
        if (_indiceSelecionado == 0) _carregarIndicadores();
      }
    });
  }

  // NOVO: indicadores do dashboard (gráficos) — uma chamada só, dados
  // agregados calculados no backend.
  Map<String, dynamic>? _indicadores;
  bool _carregandoIndicadores = false;

  Future<void> _carregarIndicadores() async {
    setState(() => _carregandoIndicadores = true);
    try {
      final headers = await _api.getHeaders();
      final res = await http.get(Uri.parse('${ApiService.baseUrl}/api/embarcador/dashboard/indicadores'), headers: headers);
      if (res.statusCode == 200 && mounted) {
        setState(() => _indicadores = jsonDecode(res.body));
      }
    } catch (e) {
      debugPrint("Erro ao carregar indicadores: $e");
    } finally {
      if (mounted) setState(() => _carregandoIndicadores = false);
    }
  }

  @override
  void dispose() {
    _timerMonitoramento?.cancel();
    _menuScroll.dispose();
    super.dispose();
  }

  Future<void> _carregarPerfilTransportadora() async {
    final flag = await _api.isTransportadora();
    if (mounted) setState(() => _isTransportadora = flag);
  }

  Future<void> _carregarPerfilAcesso() async {
    final flag = await _api.isAdmin();
    if (mounted) setState(() => _isAdmin = flag);
  }

  // NOVO: carrega o logo e o nome da empresa salvos no login (gravados
  // em SharedPreferences pelo ApiService). Chamado de novo ao voltar da
  // tela "Meus Dados", pra refletir uma troca de logo na hora.
  Future<void> _carregarDadosEmpresa() async {
    final logo = await _api.getLogoUrl();
    final nome = await _api.getNome();
    final nomeFuncionario = await _api.getFuncionarioNome();
    if (mounted) {
      setState(() {
        _logoUrl = logo;
        _nomeEmpresa = nome;
        _nomeFuncionarioLogado = nomeFuncionario;
      });
    }
  }

  Future<void> _carregarContagemNotificacoes() async {
    try {
      final total = await _api.contarNotificacoesNaoLidas();
      if (mounted) setState(() => _totalNotificacoesNaoLidas = total);
    } catch (e) {
      debugPrint("Erro ao carregar contagem de notificações: $e");
    }
  }

  void _navegarPara(int novoIndice, {VoidCallback? aoEntrar}) {
    if (novoIndice == _indiceSelecionado) return;
    setState(() {
      _historicoAbas.add(_indiceSelecionado);
      _indiceSelecionado = novoIndice;
    });
    aoEntrar?.call();
  }

  void _sair() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('jwt_token');
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginEmbarcadorScreen()));
  }

  Future<void> _buscarCep(String cep, bool isColeta) async {
    String cepLimpo = cep.replaceAll(RegExp(r'[^0-9]'), '');
    if (cepLimpo.length != 8) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("CEP inválido. Digite 8 números.")));
      return;
    }

    try {
      final response = await http.get(Uri.parse('https://viacep.com.br/ws/$cepLimpo/json/'));
      if (response.statusCode == 200) {
        final dados = jsonDecode(response.body);
        if (dados.containsKey('erro')) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("CEP não encontrado.")));
          return;
        }

        setState(() {
          if (isColeta) {
            _colRuaCtrl.text = dados['logradouro'] ?? '';
            _colBairroCtrl.text = dados['bairro'] ?? '';
            _colCidadeCtrl.text = dados['localidade'] ?? '';
            _colUfCtrl.text = dados['uf'] ?? '';

            if ((dados['logradouro'] == null || dados['logradouro'].toString().isEmpty)) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text("Este CEP é geral (sem rua). Preencha Latitude/Longitude manual abaixo para garantir a localização exata."),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 5),
              ));
            } else {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Endereço de coleta localizado!"), backgroundColor: Colors.green));
            }
          } else {
            _entRuaCtrl.text = dados['logradouro'] ?? '';
            _entBairroCtrl.text = dados['bairro'] ?? '';
            _entCidadeCtrl.text = dados['localidade'] ?? '';
            _entUfCtrl.text = dados['uf'] ?? '';
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Endereço de entrega localizado!"), backgroundColor: Colors.green));
          }
        });
      }
    } catch (e) {
      debugPrint("Erro no ViaCEP: $e");
    }
  }

  Future<void> _carregarCargas({bool silencioso = false}) async {
    if (!silencioso) setState(() => _isLoading = true);
    try {
      final cargas = await _api.buscarCargas();
      final resumo = await _api.buscarResumo();
      final ativosData = await _api.buscarMotoristasAtivos();
      if (mounted) {
        setState(() {
          _cargas = cargas;
          _resumo = resumo;
          _totalMotoristasAtivos = ativosData['total'];
          _totalMotoristasLivres = ativosData['total_livres'] ?? ativosData['total'];
          _listaMotoristasAtivos = ativosData['motoristas'];
        });
      }
    } catch (e) {
      debugPrint("Erro ao carregar dados: $e");
    } finally {
      if (!silencioso && mounted) setState(() => _isLoading = false);
    }
  }

  // NOVO: trocado o calendário padrão do Flutter pelo mesmo mini-calendário
  // simples usado em todas as outras telas do sistema.
  Future<void> _selecionarDataColeta() async {
    final data = await showDialog<DateTime>(
      context: context,
      builder: (_) => _MiniCalendarioPopup(dataInicial: _dataColetaSelecionada ?? DateTime.now()),
    );
    if (data != null) setState(() => _dataColetaSelecionada = data);
  }

  // NOVO: trocado o relógio de ponteiro padrão do Flutter pelo mesmo
  // seletor de dois menus (hora/minuto) usado em todas as outras telas.
  Future<void> _selecionarHoraColeta() async {
    final hora = await showDialog<TimeOfDay>(
      context: context,
      builder: (_) => _MiniHoraPopup(horaInicial: _horaColetaSelecionada ?? TimeOfDay.now()),
    );
    if (hora != null) setState(() => _horaColetaSelecionada = hora);
  }

  String? _dataColetaFormatadaParaApi() {
    if (_dataColetaSelecionada == null) return null;
    final d = _dataColetaSelecionada!;
    return "${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";
  }

  String? _horaColetaFormatadaParaApi() {
    if (_horaColetaSelecionada == null) return null;
    return "${_horaColetaSelecionada!.hour.toString().padLeft(2, '0')}:${_horaColetaSelecionada!.minute.toString().padLeft(2, '0')}";
  }

  void _prepararEdicao(dynamic c) {
    setState(() {
      _editandoCargaId = c['id'];

      _descCtrl.text = c['descricao']?.toString() ?? '';
      _pesoCtrl.text = c['peso_kg']?.toString() ?? '';
      _valorCtrl.text = c['valor_frete']?.toString() ?? '';
      _pedagioCtrl.text = c['valor_pedagio']?.toString() ?? '';
      _chaveNfeCtrl.text = c['chave_nfe']?.toString() ?? '';
      _classificacaoCarroceria = c['classificacao_carroceria_necessaria']?.toString();
      _classificacaoVeiculo = c['classificacao_veiculo_necessaria']?.toString();

      _colRuaCtrl.text = c['col_rua']?.toString() ?? '';
      _colNumCtrl.text = c['col_numero']?.toString() ?? '';
      _colCidadeCtrl.text = c['col_cidade']?.toString() ?? '';
      _colUfCtrl.text = c['col_uf']?.toString() ?? '';
      _colCepCtrl.text = c['col_cep']?.toString() ?? '';

      _colLatManualCtrl.text = c['lat_coleta']?.toString() ?? '';
      _colLngManualCtrl.text = c['lng_coleta']?.toString() ?? '';

      if (c['data_coleta'] != null) {
        try {
          _dataColetaSelecionada = DateTime.parse(c['data_coleta'].toString());
        } catch (_) {
          _dataColetaSelecionada = null;
        }
      } else {
        _dataColetaSelecionada = null;
      }

      if (c['hora_coleta'] != null && c['hora_coleta'].toString().isNotEmpty) {
        final partes = c['hora_coleta'].toString().split(':');
        if (partes.length >= 2) {
          _horaColetaSelecionada = TimeOfDay(
            hour: int.tryParse(partes[0]) ?? 0,
            minute: int.tryParse(partes[1]) ?? 0,
          );
        } else {
          _horaColetaSelecionada = null;
        }
      } else {
        _horaColetaSelecionada = null;
      }

      _antecedenciaMinutos = int.tryParse(c['tempo_antecedencia_minutos']?.toString() ?? '0') ?? 0;
      _preferenciaFrotaPropria = c['preferencia_frota_propria'] == true;

      if (c['caminhao_designado_id'] != null) {
        _escolherCaminhaoManualmente = true;
        _caminhaoDesignado = {
          'id': c['caminhao_designado_id'],
          'placa': c['caminhao_designado_placa'] ?? '—',
        };
      } else {
        _escolherCaminhaoManualmente = false;
        _caminhaoDesignado = null;
      }

      _entRuaCtrl.text = c['ent_rua']?.toString() ?? '';
      _entNumCtrl.text = c['ent_numero']?.toString() ?? '';
      _entCidadeCtrl.text = c['ent_cidade']?.toString() ?? '';
      _entUfCtrl.text = c['ent_uf']?.toString() ?? '';
      _entCepCtrl.text = c['ent_cep']?.toString() ?? '';
    });
  }

  void _cancelarEdicao() {
    setState(() {
      _editandoCargaId = null;
      _limparFormulario();
    });
  }

  void _limparFormulario() {
    _descCtrl.clear();
    _pesoCtrl.clear();
    _valorCtrl.clear();
    _pedagioCtrl.clear();
    _chaveNfeCtrl.clear();

    _colCepCtrl.clear(); _colRuaCtrl.clear(); _colNumCtrl.clear();
    _colBairroCtrl.clear(); _colCidadeCtrl.clear(); _colUfCtrl.clear(); _colNomeCtrl.clear();
    _colLatManualCtrl.clear(); _colLngManualCtrl.clear();
    _entCepCtrl.clear(); _entRuaCtrl.clear(); _entNumCtrl.clear();
    _entBairroCtrl.clear(); _entCidadeCtrl.clear(); _entUfCtrl.clear(); _entNomeCtrl.clear();

    _classificacaoCarroceria = null;
    _classificacaoVeiculo = null;

    _dataColetaSelecionada = null;
    _horaColetaSelecionada = null;
    _antecedenciaMinutos = 0;
    _preferenciaFrotaPropria = false;
    _escolherCaminhaoManualmente = false;
    _caminhaoDesignado = null;
  }

  // NOVO: abre a lista de caminhões da frota pra escolha manual. Só
  // mostra caminhões elegíveis: Rígido sempre aparece; Cavalo Mecânico
  // só aparece se JÁ estiver com uma carreta acoplada agora — o próprio
  // backend também valida isso de novo na hora de salvar, então aqui é
  // só pra não deixar a pessoa nem tentar escolher um caminhão inválido.
  void _abrirSeletorCaminhaoDesignado() async {
    List<dynamic> frota;
    try {
      frota = await _api.buscarFrota();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Erro ao buscar frota: $e"), backgroundColor: Colors.red),
      );
      return;
    }
    if (!mounted) return;

    final elegiveis = frota.where((c) {
      final ehCavaloMecanico = c['tipo_unidade_tratora'] == 'CAVALO_MECANICO';
      if (!ehCavaloMecanico) return true;
      return c['carreta_acoplada_id'] != null;
    }).toList();

    if (elegiveis.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Nenhum caminhão elegível. Cavalos mecânicos precisam estar com uma carreta acoplada para serem designados."),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text("Escolher Caminhão da Frota"),
        content: SizedBox(
          width: 420,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: elegiveis.length,
            itemBuilder: (itemContext, i) {
              final cam = elegiveis[i];
              final ehCavaloMecanico = cam['tipo_unidade_tratora'] == 'CAVALO_MECANICO';
              return ListTile(
                leading: Icon(ehCavaloMecanico ? Icons.rv_hookup : Icons.local_shipping, color: Colors.blue),
                title: Text(cam['placa'] ?? ''),
                subtitle: Text(
                  ehCavaloMecanico
                      ? "Cavalo Mecânico — carreta ${cam['carreta_acoplada_placa'] ?? ''} acoplada"
                      : "Rígido — ${cam['tipo_veiculo'] ?? 'N/A'}",
                ),
                onTap: () {
                  Navigator.pop(dialogCtx);
                  setState(() {
                    _caminhaoDesignado = {'id': cam['id'], 'placa': cam['placa']};
                  });
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text("CANCELAR")),
        ],
      ),
    );
  }

  Future<void> _salvarCarga() async {
    bool temRuaColeta = _colRuaCtrl.text.isNotEmpty;
    bool temCoordenadasManuais = _colLatManualCtrl.text.isNotEmpty && _colLngManualCtrl.text.isNotEmpty;
    bool temRuaEntrega = _entRuaCtrl.text.isNotEmpty;

    if (_descCtrl.text.isEmpty || _valorCtrl.text.isEmpty || (!temRuaColeta && !temCoordenadasManuais) || !temRuaEntrega) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Preencha descrição, valor e informe o local (Rua ou Mapa) de coleta e entrega!"),
        backgroundColor: Colors.orange
      ));
      return;
    }

    if (_classificacaoCarroceria == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Escolha a carroceria exigida para a carga (ex.: Baú, Sider, Graneleiro)."),
        backgroundColor: Colors.orange
      ));
      return;
    }

    if (_escolherCaminhaoManualmente && _caminhaoDesignado == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Escolha qual caminhão da frota vai atender esta carga, ou desative a opção de escolha manual."),
        backgroundColor: Colors.orange
      ));
      return;
    }

    setState(() => _isLoading = true);
    try {
      double latColeta = 0.0;
      double lngColeta = 0.0;

      final latManual = double.tryParse(_colLatManualCtrl.text.replaceAll(',', '.'));
      final lngManual = double.tryParse(_colLngManualCtrl.text.replaceAll(',', '.'));

      if (latManual != null && lngManual != null) {
        latColeta = latManual;
        lngColeta = lngManual;
      } else {
        try {
          String enderecoBusca = "${_colRuaCtrl.text}, ${_colNumCtrl.text}, ${_colCidadeCtrl.text}, ${_colUfCtrl.text}, Brasil";
          final query = Uri.encodeComponent(enderecoBusca);
          final urlGeo = Uri.parse('https://nominatim.openstreetmap.org/search?format=json&q=$query');
          final resGeo = await http.get(urlGeo, headers: {'User-Agent': 'br.com.taclog.web'});
          if (resGeo.statusCode == 200) {
            final List data = jsonDecode(resGeo.body);
            if (data.isNotEmpty) {
              latColeta = double.parse(data[0]['lat']);
              lngColeta = double.parse(data[0]['lon']);
            }
          }
        } catch (e) {
          debugPrint("Erro geocoding antes de salvar: $e");
        }
      }

      double? latEntrega;
      double? lngEntrega;
      try {
        String enderecoEntregaBusca = "${_entRuaCtrl.text}, ${_entNumCtrl.text}, ${_entCidadeCtrl.text}, ${_entUfCtrl.text}, Brasil";
        final queryEnt = Uri.encodeComponent(enderecoEntregaBusca);
        final urlGeoEnt = Uri.parse('https://nominatim.openstreetmap.org/search?format=json&q=$queryEnt');
        final resGeoEnt = await http.get(urlGeoEnt, headers: {'User-Agent': 'br.com.taclog.web'});
        if (resGeoEnt.statusCode == 200) {
          final List dataEnt = jsonDecode(resGeoEnt.body);
          if (dataEnt.isNotEmpty) {
            latEntrega = double.parse(dataEnt[0]['lat']);
            lngEntrega = double.parse(dataEnt[0]['lon']);
          }
        }
      } catch (e) {
        debugPrint("Erro geocoding entrega antes de salvar: $e");
      }

      double? distanciaKm;
      if (latColeta != 0.0 && lngColeta != 0.0 && latEntrega != null && lngEntrega != null) {
        distanciaKm = await _calcularDistanciaRota(latColeta, lngColeta, latEntrega, lngEntrega);
      }

      final payload = {
        "descricao": _descCtrl.text,
        "peso": double.tryParse(_pesoCtrl.text) ?? 0,
        "valor": double.tryParse(_valorCtrl.text) ?? 0,
        "pedagio": double.tryParse(_pedagioCtrl.text) ?? 0,
        "chave_nfe": _chaveNfeCtrl.text.isEmpty ? null : _chaveNfeCtrl.text,
        "classificacao_carroceria_necessaria": _classificacaoCarroceria,
        "classificacao_veiculo_necessaria": _classificacaoVeiculo,

        "col_cid": _colCidadeCtrl.text,
        "col_uf": _colUfCtrl.text,
        "col_cep": _colCepCtrl.text,
        "col_rua": _colRuaCtrl.text,
        "col_numero": _colNumCtrl.text,

        "ent_cid": _entCidadeCtrl.text,
        "ent_uf": _entUfCtrl.text,
        "ent_cep": _entCepCtrl.text,
        "ent_rua": _entRuaCtrl.text,
        "ent_numero": _entNumCtrl.text,

        "lat_coleta": latColeta == 0.0 ? null : latColeta,
        "lng_coleta": lngColeta == 0.0 ? null : lngColeta,
        "lat_entrega": latEntrega,
        "lng_entrega": lngEntrega,
        "distancia_km": distanciaKm != null ? double.parse(distanciaKm.toStringAsFixed(1)) : null,

        "data_coleta": _dataColetaFormatadaParaApi(),
        "hora_coleta": _horaColetaFormatadaParaApi(),
        "tempo_antecedencia_minutos": _antecedenciaMinutos,
        "preferencia_frota_propria": _isTransportadora ? (_preferenciaFrotaPropria || _escolherCaminhaoManualmente) : null,
        "caminhao_designado_id": (_isTransportadora && _escolherCaminhaoManualmente) ? (_caminhaoDesignado?['id']) : null,
      };

      final headers = await _api.getHeaders();
      http.Response res;
      if (_editandoCargaId != null) {
        res = await http.put(
          Uri.parse('${ApiService.baseUrl}/api/cargas/$_editandoCargaId'),
          headers: headers,
          body: jsonEncode(payload),
        );
      } else {
        res = await http.post(
          Uri.parse('${ApiService.baseUrl}/api/cargas/nova'),
          headers: headers,
          body: jsonEncode(payload),
        );
      }

      if (res.statusCode == 200 || res.statusCode == 201) {
        String mensagemSucesso = _editandoCargaId != null ? "Carga atualizada com sucesso!" : "Carga Publicada! Buscando motoristas...";
        try {
          final decodificado = jsonDecode(res.body);
          if (decodificado is Map && decodificado['message'] != null) {
            mensagemSucesso = decodificado['message'].toString();
          }
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensagemSucesso), backgroundColor: Colors.green));
        _cancelarEdicao();
        _carregarCargas();
      } else {
        throw Exception(_extrairMensagemErro(res.body));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro ao salvar carga: ${e.toString().replaceAll("Exception: ", "")}"), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<double?> _calcularDistanciaRota(double latOrigem, double lngOrigem, double latDestino, double lngDestino) async {
    try {
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/$lngOrigem,$latOrigem;$lngDestino,$latDestino?overview=false',
      );
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['routes'] != null && (data['routes'] as List).isNotEmpty) {
          final distanciaMetros = data['routes'][0]['distance'];
          if (distanciaMetros is num) {
            return distanciaMetros / 1000.0;
          }
        }
      }
    } catch (e) {
      debugPrint("Erro ao calcular distância de rota (OSRM): $e");
    }
    return null;
  }

  String _extrairMensagemErro(String corpoResposta) {
    try {
      final decodificado = jsonDecode(corpoResposta);
      if (decodificado is Map && decodificado['error'] != null) {
        return decodificado['error'].toString();
      }
      return corpoResposta;
    } catch (e) {
      return corpoResposta.isNotEmpty ? corpoResposta : "Erro desconhecido ao salvar a carga.";
    }
  }

  void _abrirSeletorMapa() {
    final latAtual = double.tryParse(_colLatManualCtrl.text.replaceAll(',', '.'));
    final lngAtual = double.tryParse(_colLngManualCtrl.text.replaceAll(',', '.'));
    LatLng pontoSelecionado = (latAtual != null && lngAtual != null)
        ? LatLng(latAtual, lngAtual)
        : const LatLng(-29.3, -51.5);

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            return AlertDialog(
              title: const Text(
                "Ajustar Local Exato da Coleta",
                style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
              ),
              content: SizedBox(
                width: 520,
                height: 460,
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        "Toque no mapa exatamente onde é o local de coleta. Use o zoom (scroll do mouse) para ajustar com precisão.",
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: FlutterMap(
                          options: MapOptions(
                            initialCenter: pontoSelecionado,
                            initialZoom: 13,
                            onTap: (tapPosition, point) {
                              setStateDialog(() {
                                pontoSelecionado = point;
                              });
                            },
                          ),
                          children: [
                            TileLayer(
                              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'br.com.taclog.web',
                            ),
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: pontoSelecionado,
                                  width: 40,
                                  height: 40,
                                  child: const Icon(Icons.location_pin, color: Colors.red, size: 40),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Lat: ${pontoSelecionado.latitude.toStringAsFixed(6)}  /  Lng: ${pontoSelecionado.longitude.toStringAsFixed(6)}",
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueGrey),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _colLatManualCtrl.text = pontoSelecionado.latitude.toStringAsFixed(6);
                      _colLngManualCtrl.text = pontoSelecionado.longitude.toStringAsFixed(6);
                    });
                    Navigator.pop(ctx);
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                  child: const Text("CONFIRMAR LOCAL", style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _mostrarListaMotoristas() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Motoristas Online e Livres", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
        content: SizedBox(
          width: 500,
          child: _listaMotoristasAtivos.isEmpty
            ? const Text("Nenhum motorista online no momento.", style: TextStyle(color: Colors.grey))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: _listaMotoristasAtivos.length,
                itemBuilder: (c, i) {
                  final m = _listaMotoristasAtivos[i];
                  return Card(
                    elevation: 0,
                    color: Colors.blue[50],
                    child: ListTile(
                      leading: const CircleAvatar(backgroundColor: Colors.blue, child: Icon(Icons.local_shipping, color: Colors.white)),
                      title: Text(m['nome'] ?? 'Sem Nome', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                      subtitle: Text("Veículo: ${m['tipo_veiculo'] ?? 'N/A'} - Placa: ${m['placa'] ?? 'N/A'}"),
                      trailing: IconButton(
                        icon: const Icon(Icons.map, color: Colors.blue, size: 28),
                        tooltip: "Visualizar no Mapa",
                        onPressed: () {
                          Navigator.pop(ctx);
                          setState(() => _indiceSelecionado = 9);
                        },
                      ),
                    ),
                  );
                }
              ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("FECHAR")),
        ],
      )
    );
  }

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
              _api.buscarNotificacoes().then((lista) {
                notificacoes = lista;
                carregando = false;
                setStateDialog(() {});
              }).catchError((e) {
                erro = e.toString().replaceAll("Exception: ", "");
                carregando = false;
                setStateDialog(() {});
              });
            }

            final temNaoLida = notificacoes.any((n) => n['lida'] != true);

            return AlertDialog(
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("Notificações", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                  if (temNaoLida)
                    TextButton(
                      onPressed: () async {
                        try {
                          await _api.marcarTodasNotificacoesLidas();
                          setStateDialog(() {
                            notificacoes = notificacoes.map((n) {
                              final copia = Map<String, dynamic>.from(n);
                              copia['lida'] = true;
                              return copia;
                            }).toList();
                          });
                          _carregarContagemNotificacoes();
                        } catch (e) {
                        }
                      },
                      child: const Text("Marcar todas como lidas", style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
              content: SizedBox(
                width: 480,
                child: carregando
                    ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()))
                    : erro != null
                        ? Text(erro!, style: const TextStyle(color: Colors.red))
                        : notificacoes.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 30),
                                child: Text("Nenhuma notificação por aqui.", style: TextStyle(color: Colors.grey)),
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
                                      subtitle: Text(
                                        _formatarDataHora(n['data_criacao']?.toString() ?? ''),
                                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                                      ),
                                      onTap: lida
                                          ? null
                                          : () async {
                                              try {
                                                await _api.marcarNotificacaoLida(n['id']);
                                                setStateDialog(() {
                                                  notificacoes[i] = Map<String, dynamic>.from(n)..['lida'] = true;
                                                });
                                                _carregarContagemNotificacoes();
                                              } catch (e) {
                                              }
                                            },
                                    );
                                  },
                                ),
                              ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    if (temNaoLida) {
                      try {
                        await _api.marcarTodasNotificacoesLidas();
                      } catch (e) {
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

  void _mostrarDetalhesCarga(Map<String, dynamic> carga) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Detalhes Operacionais", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _detalheLinha("Carga:", carga['descricao']),
                _detalheLinha("Valor Frete:", "R\$ ${_formatarMoedaBr(carga['valor_frete'])}"),
                _detalheLinha("Status Atual:", carga['status']),

                if (carga['data_coleta'] != null) ...[
                  const Divider(),
                  const Text("🕒 Agendamento da Coleta", style: TextStyle(fontWeight: FontWeight.bold)),
                  _detalheLinha("Data/Hora da Coleta:", _formatarDataColetaCard(carga['data_coleta'], carga['hora_coleta']) ?? 'N/A'),
                  _detalheLinha("Antecedência de disparo:", _formatarAntecedencia(carga['tempo_antecedencia_minutos'])),
                  if (carga['preferencia_frota_propria'] == true)
                    _detalheLinha("Preferência de Frota:", "Sim, buscar caminhão próprio primeiro"),
                ],

                const Divider(),
                const Text("📍 Local de Coleta", style: TextStyle(fontWeight: FontWeight.bold)),
                Text("${carga['col_rua']}, ${carga['col_numero']} - ${carga['col_cidade']} / ${carga['col_uf']}"),
                const SizedBox(height: 10),
                const Text("🏁 Local de Entrega", style: TextStyle(fontWeight: FontWeight.bold)),
                Text("${carga['ent_rua']}, ${carga['ent_numero']} - ${carga['ent_cidade']} / ${carga['ent_uf']}"),

                if (carga['motorista_nome'] != null) ...[
                  const Divider(),
                  const Text("🚛 Motorista Responsável", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: Colors.grey[300],
                        backgroundImage: (carga['motorista_foto'] != null && carga['motorista_foto'].toString().isNotEmpty)
                            ? NetworkImage(carga['motorista_foto']) : null,
                        child: (carga['motorista_foto'] == null || carga['motorista_foto'].toString().isEmpty)
                            ? const Icon(Icons.person, size: 30, color: Colors.grey) : null,
                      ),
                      const SizedBox(width: 15),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(carga['motorista_nome'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          Text("Placa: ${carga['caminhao_placa'] ?? 'N/A'}", style: const TextStyle(color: Colors.grey)),
                        ],
                      )
                    ],
                  ),
                ],

                if (carga['status'] == 'ENTREGUE' && carga['data_hora_finalizacao'] != null) ...[
                  const Divider(),
                  const Text("✅ Dados de Finalização", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.green[50], borderRadius: BorderRadius.circular(8)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _detalheLinha("Data e Hora:", _formatarDataHora(carga['data_hora_finalizacao'])),
                        _detalheLinha("Latitude:", carga['lat_finalizacao']?.toString() ?? 'N/A'),
                        _detalheLinha("Longitude:", carga['lng_finalizacao']?.toString() ?? 'N/A'),
                      ],
                    ),
                  )
                ]
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("FECHAR")),
        ],
      ),
    );
  }

  String _formatarDataHora(String isoDate) {
    try {
      DateTime data = DateTime.parse(isoDate).toLocal();
      return "${data.day.toString().padLeft(2, '0')}/${data.month.toString().padLeft(2, '0')}/${data.year} às ${data.hour.toString().padLeft(2, '0')}:${data.minute.toString().padLeft(2, '0')}";
    } catch (e) {
      return isoDate;
    }
  }

  String? _formatarDataColetaCard(dynamic dataColeta, dynamic horaColeta) {
    if (dataColeta == null) return null;
    try {
      final data = DateTime.parse(dataColeta.toString());
      final dataFormatada = "${data.day.toString().padLeft(2, '0')}/${data.month.toString().padLeft(2, '0')}/${data.year}";
      String horaFormatada = '';
      if (horaColeta != null && horaColeta.toString().isNotEmpty) {
        final partes = horaColeta.toString().split(':');
        if (partes.length >= 2) {
          horaFormatada = " às ${partes[0].padLeft(2, '0')}:${partes[1].padLeft(2, '0')}";
        }
      }
      return "$dataFormatada$horaFormatada";
    } catch (e) {
      return dataColeta.toString();
    }
  }

  String _formatarAntecedencia(dynamic minutos) {
    final min = int.tryParse(minutos?.toString() ?? '0') ?? 0;
    if (min == 0) return "Sem antecedência (na hora da coleta)";
    if (min < 60) return "$min minutos antes";
    if (min % 60 == 0) return "${min ~/ 60} hora(s) antes";
    return "$min minutos antes";
  }

  Widget _detalheLinha(String label, String valor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        children: [
          Text("$label ", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
          Expanded(child: Text(valor, style: const TextStyle(fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }

  void _confirmarAcao(String titulo, String mensagem, VoidCallback onConfirm) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo, style: const TextStyle(color: Colors.red)),
        content: Text(mensagem),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("VOLTAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(ctx);
              onConfirm();
            },
            child: const Text("CONFIRMAR", style: TextStyle(color: Colors.white))
          ),
        ],
      )
    );
  }

  void _cancelarAceiteMotorista(int idCarga) async {
    _confirmarAcao(
      "Cancelar Aceite do Motorista?",
      "Ao cancelar, o motorista será notificado e removido desta operação. A carga voltará para a fila de procura.\nDeseja continuar?",
      () async {
        try {
          await _api.cancelarAceiteMotorista(idCarga);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Aceite cancelado. Carga na fila novamente."), backgroundColor: Colors.orange));
          _carregarCargas();
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro: $e"), backgroundColor: Colors.red));
        }
      }
    );
  }

  Future<void> _excluirCarga(int id) async {
    _confirmarAcao(
      "Deletar Carga Permanentemente?",
      "Tem certeza que deseja cancelar esta oferta? Se houver um motorista em trânsito, ele será notificado. Esta ação apagará a carga do sistema.",
      () async {
        setState(() => _isLoading = true);
        try {
          await _api.deletarCarga(id);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Carga excluída com sucesso!"), backgroundColor: Colors.green));
          _carregarCargas();
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erro: $e"), backgroundColor: Colors.red));
        } finally {
          if (mounted) setState(() => _isLoading = false);
        }
      }
    );
  }

  Widget _buildSinoNotificacoes() {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const Icon(Icons.notifications, color: Colors.white, size: 26),
          onPressed: _mostrarNotificacoes,
          tooltip: "Notificações",
        ),
        if (_totalNotificacoesNaoLidas > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              child: Text(
                _totalNotificacoesNaoLidas > 9 ? '9+' : '$_totalNotificacoesNaoLidas',
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }

  Widget _sidebarItem({
    required IconData icone,
    required String label,
    required bool selecionado,
    required VoidCallback onTap,
    Color corIcone = Colors.white70,
  }) {
    // NOVO: colapsado, mostra só o ícone centralizado (com Tooltip pra
    // ainda dar pra saber o que é cada um sem precisar abrir o menu).
    if (_menuColapsado) {
      return Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            padding: const EdgeInsets.symmetric(vertical: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selecionado ? Colors.white.withOpacity(0.16) : Colors.transparent,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(icone, color: selecionado ? Colors.white : corIcone, size: 22),
          ),
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          color: selecionado ? Colors.white.withOpacity(0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Icon(icone, color: selecionado ? Colors.white : corIcone, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14.5,
                  fontWeight: selecionado ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebarGrupo({
    required IconData icone,
    required String label,
    required bool expandido,
    required VoidCallback onToggle,
    List<String> subitens = const [],
    Map<String, VoidCallback>? acoes,
    // NOVO: diz quais subitens estão "selecionados" (a tela aberta agora
    // é a dele) — sem isso, o item dentro de Cadastros nunca destacava
    // igual aos itens soltos no topo do menu.
    Map<String, bool>? selecionados,
    // NOVO: quando um grupo precisa agrupar OUTROS grupos (2º nível de
    // aninhamento, ex.: "Documentos" contendo "Frete"/"Carga"/"Veículo",
    // cada um com seus próprios subitens), passa os sub-grupos prontos
    // aqui em vez de "subitens" — eles já vêm com seu próprio InkWell de
    // expandir/recolher, só precisam do recuo extra.
    List<Widget>? filhos,
  }) {
    // NOVO: colapsado, vira um ícone só — tocar reabre o menu inteiro (e já
    // deixa esse grupo expandido), já que não dá pra mostrar os subitens
    // numa faixa estreita de ícones.
    if (_menuColapsado) {
      return Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          onTap: () => setState(() {
            _menuColapsado = false;
            if (!expandido) onToggle();
          }),
          borderRadius: BorderRadius.circular(24),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            padding: const EdgeInsets.symmetric(vertical: 12),
            alignment: Alignment.center,
            child: Icon(icone, color: Colors.white70, size: 22),
          ),
        ),
      );
    }
    return Column(
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(24),
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
            decoration: BoxDecoration(
              color: expandido ? Colors.white.withOpacity(0.10) : Colors.transparent,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              children: [
                Icon(icone, color: Colors.white70, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w500),
                  ),
                ),
                Icon(
                  expandido ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  color: Colors.white70,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        if (expandido && filhos != null)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Column(children: filhos),
          ),
        if (expandido && filhos == null)
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Column(
              children: subitens.map((s) => _sidebarSubitem(s, onTap: acoes?[s], selecionado: selecionados?[s] ?? false)).toList(),
            ),
          ),
      ],
    );
  }

  // NOVO: agora também recebe "selecionado" e fica destacado (fundo claro
  // + texto branco em negrito) igual os itens de primeiro nível do menu,
  // quando a tela aberta é a dele.
  Widget _sidebarSubitem(String label, {VoidCallback? onTap, bool selecionado = false}) {
    return InkWell(
      onTap: onTap ?? () {},
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 14),
        decoration: BoxDecoration(
          color: selecionado ? Colors.white.withOpacity(0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selecionado ? Colors.white : Colors.white60,
            fontSize: 13,
            fontWeight: selecionado ? FontWeight.w700 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _historicoAbas.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_historicoAbas.isNotEmpty) {
          setState(() {
            _indiceSelecionado = _historicoAbas.removeLast();
          });
        }
      },
      child: Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      // NOVO: Stack pra poder flutuar o botãozinho de recolher/expandir o
      // menu bem em cima da borda entre o menu e o conteúdo (mesma ideia
      // visual do Asaas).
      body: Stack(
        children: [
          Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: _menuColapsado ? _larguraMenuColapsado : _larguraMenuAberto,
            decoration: const BoxDecoration(
              // Mesmo azul mais leve do cabeçalho de cima (0xFF1976D2), pra
              // ficar tudo na mesma cor.
              color: Color(0xFF1976D2),
            ),
            // O menu inteiro rola junto: em tela alta, Configurações/Sair
            // ficam colados embaixo; em tela baixa, tudo rola e nada some.
            child: LayoutBuilder(
              builder: (menuCtx, menuConstraints) => Scrollbar(
                controller: _menuScroll,
                child: SingleChildScrollView(
                  controller: _menuScroll,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: menuConstraints.maxHeight),
                    child: IntrinsicHeight(
                      child: Column(
              children: [
                const SizedBox(height: 24),
                // NOVO: colapsado, a logo da empresa (geralmente "deitada",
                // larga) não cabe na faixa estreita de ícones — mostra só um
                // ícone genérico compacto em vez dela.
                if (_menuColapsado)
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.local_shipping, color: Color(0xFF64748B), size: 20),
                  )
                else
                  Container(
                    // Sem "width: double.infinity": a caixa agora abraça o tamanho da
                    // própria logo (Column centraliza sozinha, já que o alinhamento
                    // padrão do Column é center) em vez de forçar a largura toda do
                    // menu - isso evita a caixa ficar bem mais larga que a logo com
                    // espaço vazio sobrando nas laterais.
                    height: 64,
                    constraints: const BoxConstraints(maxWidth: 188),
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Align(
                      alignment: Alignment.center,
                      // Altura da imagem bem maior (48px de altura útil) e SEM largura
                      // fixa: o Flutter calcula a largura sozinho a partir da proporção
                      // real da logo, então funciona bem tanto para logos "deitadas"
                      // (largas, como a da Zanin) quanto para logos mais quadradas de
                      // outros clientes no futuro - BoxFit.contain garante que nunca
                      // corta nem estica.
                      child: _logoUrl.isEmpty
                          ? Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE2E8F0),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Icon(Icons.local_shipping, color: Color(0xFF64748B), size: 20),
                            )
                          : Image.network(
                              _logoUrl,
                              height: 48,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) => Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE2E8F0),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Icon(Icons.local_shipping, color: Color(0xFF64748B), size: 20),
                              ),
                            ),
                    ),
                  ),
                const SizedBox(height: 16),
                const Divider(color: Colors.white24, height: 1),
                const SizedBox(height: 8),

                Expanded(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        _sidebarItem(
                          icone: Icons.home,
                          label: 'Início',
                          selecionado: _indiceSelecionado == 0,
                          onTap: () => _navegarPara(0, aoEntrar: _carregarCargas),
                        ),

                        _sidebarItem(
                          icone: Icons.add_box,
                          label: 'Publicar Carga',
                          selecionado: _indiceSelecionado == 5,
                          onTap: () => _navegarPara(5),
                        ),

                        // NOVO: "Radar de Cargas" e "Mapa da Frota" viraram
                        // subitens "Cargas" e "Frota" dentro de um único
                        // grupo "Radar" — já dá pra entender que é "radar de
                        // cargas" e "radar de frota" pelo contexto do grupo,
                        // sem repetir "Radar" no nome de cada um.
                        _sidebarGrupo(
                          icone: Icons.radar,
                          label: "Radar",
                          expandido: _expRadar,
                          onToggle: () => setState(() => _expRadar = !_expRadar),
                          subitens: [
                            "Cargas",
                            if (_isTransportadora) "Frota",
                          ],
                          acoes: {
                            "Cargas": () => _navegarPara(1, aoEntrar: _carregarCargas),
                            if (_isTransportadora) "Frota": () => _navegarPara(9),
                          },
                          selecionados: {
                            "Cargas": _indiceSelecionado == 1,
                            if (_isTransportadora) "Frota": _indiceSelecionado == 9,
                          },
                        ),

                        _sidebarItem(
                          icone: Icons.event_available,
                          label: 'Agendamentos',
                          selecionado: _indiceSelecionado == 4,
                          onTap: () => _navegarPara(4),
                        ),

                        if (_isTransportadora)
                          _sidebarItem(
                            icone: Icons.storefront,
                            label: 'Ofertas do Mercado',
                            selecionado: _indiceSelecionado == 7,
                            onTap: () => _navegarPara(7),
                          ),

                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Divider(color: Colors.white24, height: 1),
                        ),

                        _sidebarGrupo(
                          icone: Icons.business_center,
                          label: "Cadastros",
                          expandido: _expCadastros,
                          onToggle: () => setState(() => _expCadastros = !_expCadastros),
                          // NOVO: "Usuários" (gestão de funcionários da
                          // transportadora) só aparece pro TITULAR da conta
                          // — um funcionário logado não pode cadastrar
                          // outro funcionário. "Frota" e "Clientes" foram
                          // movidos pra cá (antes eram itens soltos no topo
                          // do menu) e só aparecem pra quem é transportadora
                          // (tem frota própria) — mesma regra de antes.
                          subitens: [
                            if (_ehTitular) "Usuários",
                            if (_isTransportadora) "Frota",
                            if (_isTransportadora) "Motoristas",
                            if (_isTransportadora) "Clientes",
                          ],
                          acoes: {
                            if (_ehTitular) "Usuários": () => _navegarPara(10),
                            if (_isTransportadora) "Frota": () => _navegarPara(2),
                            if (_isTransportadora) "Motoristas": () => _navegarPara(12),
                            if (_isTransportadora) "Clientes": () => _navegarPara(6),
                          },
                          selecionados: {
                            if (_ehTitular) "Usuários": _indiceSelecionado == 10,
                            if (_isTransportadora) "Frota": _indiceSelecionado == 2,
                            if (_isTransportadora) "Motoristas": _indiceSelecionado == 12,
                            if (_isTransportadora) "Clientes": _indiceSelecionado == 6,
                          },
                        ),

                        // NOVO: as 3 entradas "Doc. Frete" / "Doc. Carga" /
                        // "Doc. Veículo" (documentos fiscais/regulatórios —
                        // CT-e, NF-e, CRLV-e, RNTRC etc., ainda placeholders
                        // pra uma futura integração) agora ficam agrupadas
                        // dentro de "Documentos", com o "Doc." removido do
                        // nome de cada uma (já fica implícito pelo grupo).
                        // Dentro de "Veículo" acrescentei um atalho pra quem
                        // quiser ver os documentos que já são anexados hoje
                        // no cadastro da Frota (CRLV do caminhão/carreta,
                        // CNH do motorista) — são fotos/anexos simples, uma
                        // coisa diferente dos documentos fiscais eletrônicos
                        // desta seção, então não misturei os dois ali, só
                        // deixei um link rápido pra quem já tem cadastrado.
                        _sidebarGrupo(
                          icone: Icons.folder_copy,
                          label: "Documentos",
                          expandido: _expDocumentos,
                          onToggle: () => setState(() => _expDocumentos = !_expDocumentos),
                          filhos: [
                            _sidebarGrupo(
                              icone: Icons.receipt_long,
                              label: "Frete",
                              expandido: _expDocFrete,
                              onToggle: () => setState(() => _expDocFrete = !_expDocFrete),
                              subitens: const ["CT-e", "MDF / DAMDFE", "CIOT / PEF"],
                            ),
                            _sidebarGrupo(
                              icone: Icons.inventory_2,
                              label: "Carga",
                              expandido: _expDocCarga,
                              onToggle: () => setState(() => _expDocCarga = !_expDocCarga),
                              subitens: const ["NF-e / DANFE", "Coleta / POD"],
                            ),
                            _sidebarGrupo(
                              icone: Icons.local_shipping,
                              label: "Veículo",
                              expandido: _expDocVeiculo,
                              onToggle: () => setState(() => _expDocVeiculo = !_expDocVeiculo),
                              subitens: [
                                "CRLV-e / CNH",
                                "RNTRC",
                                if (_isTransportadora) "Ver Documentos da Frota",
                              ],
                              acoes: {
                                if (_isTransportadora) "Ver Documentos da Frota": () => _navegarPara(2),
                              },
                              selecionados: {
                                if (_isTransportadora) "Ver Documentos da Frota": _indiceSelecionado == 2,
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                ),

                // NOVO: "Log do Sistema" — só quem é ADMIN (o titular ou um
                // funcionário com perfil ADMIN) enxerga. Por enquanto só
                // mostra os logins (quem, quando, de onde).
                if (_isAdmin) ...[
                  const Divider(color: Colors.white24, height: 1),
                  const SizedBox(height: 4),
                  _sidebarItem(
                    icone: Icons.fact_check_outlined,
                    label: 'Log do Sistema',
                    selecionado: _indiceSelecionado == 11,
                    onTap: () => _navegarPara(11),
                  ),
                ],

                if (_isTransportadora) ...[
                  const Divider(color: Colors.white24, height: 1),
                  const SizedBox(height: 4),
                  _sidebarItem(
                    icone: Icons.settings,
                    label: 'Configurações',
                    selecionado: _indiceSelecionado == 3,
                    onTap: () => _navegarPara(3),
                  ),
                ],

                const Divider(color: Colors.white24, height: 1),
                const SizedBox(height: 4),
                _sidebarItem(
                  icone: Icons.policy_outlined,
                  label: 'Termos e Privacidade',
                  selecionado: false,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TermosTextoScreen()),
                  ),
                ),
                _sidebarItem(
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
                  ),
                ),
              ),
            ),
          ),

          Expanded(
            child: Column(
              children: [
                // Cabeçalho — azul um pouco mais claro que o navy escuro
                // original (0xFF0D47A1), combinando com o azul usado nos
                // botões e destaques do resto do sistema (Colors.blue /
                // Blue 700), com uma linha fina separando do conteúdo abaixo.
                Container(
                  width: double.infinity,
                  color: const Color(0xFF1976D2),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _nomeEmpresa,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                              overflow: TextOverflow.ellipsis,
                            ),
                            // NOVO: quando quem está logado é um funcionário
                            // (não o titular), mostra o nome dele — as ações
                            // feitas por ele já ficam registradas com esse
                            // nome no backend, então faz sentido ele ver isso
                            // na tela também.
                            if (_nomeFuncionarioLogado.isNotEmpty)
                              Text(
                                _nomeFuncionarioLogado,
                                style: const TextStyle(fontSize: 12, color: Colors.white70),
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          _buildSinoNotificacoes(),
                          IconButton(
                            icon: const Icon(Icons.account_circle, color: Colors.white, size: 28),
                            tooltip: "Meus Dados",
                            onPressed: () async {
                              await Navigator.push(context, MaterialPageRoute(builder: (_) => const TelaPerfilEmbarcadorWeb()));
                              _carregarDadosEmpresa();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Container(height: 1, color: const Color(0xFFE2E8F0)),

                Expanded(
                  child: Padding(
                    // NOVO: Agendamentos e Nova Coleta Própria usam menos
                    // margem, pra caber mais coisa na tela.
                    padding: (_indiceSelecionado == 4 || _indiceSelecionado == 8)
                        ? const EdgeInsets.fromLTRB(14, 10, 16, 8)
                        : const EdgeInsets.all(24.0),
                    child: _indiceSelecionado == 0
                        ? _buildInicioEmbarcador()
                        : _indiceSelecionado == 1
                            ? _buildGestaoCargas()
                            : _indiceSelecionado == 2
                                ? const TelaFrotaEmbarcador()
                                : _indiceSelecionado == 3
                                    ? const TelaConfiguracoesEmbarcador()
                                    : _indiceSelecionado == 4
                                        ? TelaAgendamentosEmbarcador(
                                            // CORRIGIDO: passa por _navegarPara, que registra
                                            // a tela anterior no histórico — assim o botão
                                            // Voltar do navegador volta pra Agendamentos, e
                                            // não pro início do sistema.
                                            aoEscolherColetaPropria: () => _navegarPara(8),
                                            aoEscolherCargaMercado: () => _navegarPara(5),
                                            aoEditarColetaPropria: (coleta) {
                                              _coletaParaEditar = coleta;
                                              _navegarPara(8);
                                            },
                                          )
                                        : _indiceSelecionado == 5
                                            ? const TelaOfertaCargaWeb()
                                            : _indiceSelecionado == 6
                                                ? const TelaColetasFrotaEmbarcador()
                                                : _indiceSelecionado == 7
                                                    ? const TelaOfertasMercadoEmbarcador()
                                                    : _indiceSelecionado == 8
                                                        ? TelaColetaPropriaWeb(
                                                            coletaExistente: _coletaParaEditar,
                                                            aoSalvarComSucesso: () => setState(() {
                                                              _coletaParaEditar = null;
                                                              // tira do histórico a entrada de Agendamentos que
                                                              // foi empilhada ao abrir a inclusão (evita Voltar
                                                              // "parado" na mesma tela).
                                                              if (_historicoAbas.isNotEmpty && _historicoAbas.last == 4) {
                                                                _historicoAbas.removeLast();
                                                              }
                                                              _indiceSelecionado = 4;
                                                            }),
                                                          )
                                                        : _indiceSelecionado == 9
                                                            ? const MapaFrotaViewWeb()
                                                            : _indiceSelecionado == 10
                                                                ? const TelaFuncionariosEmbarcador()
                                                                : _indiceSelecionado == 11
                                                                    ? const TelaLogSistemaEmbarcador()
                                                                    : _indiceSelecionado == 12
                                                                        ? const TelaMotoristasEmbarcador()
                                                                        : const Center(child: Text("Módulo em Desenvolvimento", style: TextStyle(fontSize: 20, color: Colors.grey))),
                  ),
                ),
              ],
            ),
          )
        ],
      ),
          // NOVO: botão flutuante de recolher/expandir o menu, sempre bem
          // em cima da borda entre o menu e o conteúdo (mesma ideia do
          // Asaas) — a seta vira pro lado oposto conforme o estado.
          Positioned(
            top: 76,
            left: (_menuColapsado ? _larguraMenuColapsado : _larguraMenuAberto) - 14,
            child: Tooltip(
              message: _menuColapsado ? "Expandir menu" : "Recolher menu",
              child: InkWell(
                onTap: () => setState(() => _menuColapsado = !_menuColapsado),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 1))],
                  ),
                  child: Icon(
                    _menuColapsado ? Icons.chevron_right : Icons.chevron_left,
                    size: 18,
                    color: const Color(0xFF1976D2),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildInicioEmbarcador() {
    final totalPublicadas = _cargas.length;
    final aguardandoMotorista = _cargas.where((c) => c['status'] == 'DISPONIVEL').length;
    final agendadas = _cargas.where((c) => c['status'] == 'AGENDADA').length;
    final emOperacao = _cargas.where((c) => ['EM_ANDAMENTO', 'COLETADA'].contains(c['status'])).length;
    final finalizadas = _cargas.where((c) => c['status'] == 'ENTREGUE').length;
    final canceladas = _cargas.where((c) => c['status'] == 'CANCELADA').length;
    final rejeitadas = _indicadores?['total_ofertas_rejeitadas'] ?? 0;

    if (_isLoading && _cargas.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Início", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
          const SizedBox(height: 4),
          const Text(
            "Visão geral das suas cargas na plataforma TACLOG.",
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 18),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 5,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 2.7,
            children: [
              _inicioCard(
                "Motoristas Online / Livres",
                "$_totalMotoristasAtivos / $_totalMotoristasLivres",
                Icons.touch_app,
                Colors.blue[800]!,
                onTap: _mostrarListaMotoristas,
              ),
              _inicioCard(
                "Total em Aberto",
                "R\$ ${_formatarMoedaBr(_resumo['aberto'])}",
                Icons.hourglass_bottom,
                Colors.orange[800]!,
                fontSize: 16,
              ),
              _inicioCard(
                "Total a Pagar",
                "R\$ ${_formatarMoedaBr(_resumo['pagar'])}",
                Icons.payments,
                Colors.green[800]!,
                fontSize: 16,
              ),
              _inicioCard("Total de Cargas Publicadas", "$totalPublicadas", Icons.upload_file, Colors.blueGrey),
              _inicioCard("Aguardando Motorista", "$aguardandoMotorista", Icons.search, Colors.orange[800]!),
              _inicioCard("Agendadas (aguardando disparo)", "$agendadas", Icons.schedule, Colors.indigo[700]!),
              _inicioCard("Em Operação (Viajando)", "$emOperacao", Icons.local_shipping, Colors.blue[800]!),
              _inicioCard("Finalizadas", "$finalizadas", Icons.check_circle, Colors.green[800]!),
              _inicioCard("Canceladas", "$canceladas", Icons.cancel, Colors.red[700]!),
              _inicioCard("Rejeitadas (Motorista)", "$rejeitadas", Icons.thumb_down_alt, Colors.red[400]!),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.blue[50], borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.blue[100]!)),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue[700], size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    "\"Agendadas\" são cargas publicadas para uma data futura de coleta — ainda não foram oferecidas a nenhum motorista. Elas entram automaticamente na fila de matchmaking quando chega o horário configurado.",
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),
          const Text("Indicadores", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
          const SizedBox(height: 4),
          const Text("Uma visão mais completa da sua operação.", style: TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 16),

          if (_carregandoIndicadores && _indicadores == null)
            const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Center(child: CircularProgressIndicator()))
          else
            LayoutBuilder(
              builder: (context, constraints) {
                const espacamento = 16.0;
                final larguraCard = constraints.maxWidth > 800
                    ? (constraints.maxWidth - espacamento) / 2
                    : constraints.maxWidth;
                Widget cardComLargura(Widget child) => SizedBox(width: larguraCard, child: child);

                return Wrap(
                  spacing: espacamento,
                  runSpacing: espacamento,
                  children: [
                    cardComLargura(_cardDuasPizzasEstado()),
                    cardComLargura(_cardTempoMedioOperacao()),
                    cardComLargura(_cardEvolucaoMensal()),
                    cardComLargura(_cardCargasPorCaminhao()),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  // =========================================================================
  // INDICADORES — widgets dos cards de gráfico da tela Início
  // =========================================================================

  static final List<Color> _paletaCoresGraficos = [
    Colors.blue[700]!, Colors.orange[700]!, Colors.green[700]!, Colors.purple[700]!,
    Colors.red[700]!, Colors.teal[700]!, Colors.indigo[700]!, Colors.brown[700]!,
    Colors.pink[700]!, Colors.cyan[700]!, Colors.lime[800]!, Colors.deepOrange[700]!,
  ];

  Widget _containerCard(Widget child) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6)],
      ),
      child: child,
    );
  }

  Widget _tituloCardGrafico(String titulo, {String? subtitulo}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(titulo, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A))),
        if (subtitulo != null) ...[
          const SizedBox(height: 3),
          Text(subtitulo, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ],
    );
  }

  Widget _miniPizza(List<dynamic> dados, String chaveLabel) {
    if (dados.isEmpty) {
      return const SizedBox(
        height: 160,
        child: Center(child: Text("Sem dados ainda", style: TextStyle(color: Colors.grey, fontSize: 11.5))),
      );
    }
    final total = dados.fold<int>(0, (s, d) => s + (int.tryParse(d['total'].toString()) ?? 0));
    return Column(
      children: [
        SizedBox(
          height: 130,
          child: PieChart(PieChartData(
            sectionsSpace: 2,
            centerSpaceRadius: 26,
            sections: List.generate(dados.length, (i) {
              final valor = int.tryParse(dados[i]['total'].toString()) ?? 0;
              final pct = total > 0 ? (valor / total * 100) : 0.0;
              return PieChartSectionData(
                value: valor.toDouble(),
                title: '${pct.toStringAsFixed(0)}%',
                color: _paletaCoresGraficos[i % _paletaCoresGraficos.length],
                radius: 40,
                titleStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
              );
            }),
          )),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: List.generate(dados.length, (i) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: _paletaCoresGraficos[i % _paletaCoresGraficos.length], shape: BoxShape.circle)),
                const SizedBox(width: 4),
                Text('${dados[i][chaveLabel] ?? '?'}', style: const TextStyle(fontSize: 10.5)),
              ],
            );
          }),
        ),
      ],
    );
  }

  Widget _cardDuasPizzasEstado() {
    final coletas = (_indicadores?['coletas_por_estado'] as List?) ?? [];
    final entregas = (_indicadores?['entregas_por_estado'] as List?) ?? [];
    return _containerCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _tituloCardGrafico("Operações por Estado"),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(children: [
                  const Text("Coletas", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFF334155))),
                  const SizedBox(height: 8),
                  _miniPizza(coletas, 'uf'),
                ]),
              ),
              Container(width: 1, height: 190, color: const Color(0xFFE2E8F0), margin: const EdgeInsets.symmetric(horizontal: 10)),
              Expanded(
                child: Column(children: [
                  const Text("Entregas", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFF334155))),
                  const SizedBox(height: 8),
                  _miniPizza(entregas, 'uf'),
                ]),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cardCargasPorCaminhao() {
    final dados = (_indicadores?['cargas_por_caminhao'] as List?) ?? [];
    return _containerCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _tituloCardGrafico("Cargas Realizadas por Caminhão", subtitulo: "Só operações feitas por caminhão da sua frota"),
          const SizedBox(height: 14),
          _miniPizza(dados, 'placa'),
        ],
      ),
    );
  }

  String _formatarMesAno(String mes) {
    final partes = mes.split('-');
    if (partes.length != 2) return mes;
    const nomes = ['', 'Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez'];
    final m = int.tryParse(partes[1]) ?? 0;
    if (m < 1 || m > 12) return mes;
    return '${nomes[m]}/${partes[0].substring(2)}';
  }

  Widget _legendaLinhaGrafico(Color cor, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10, height: 10, color: cor),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 11.5, color: Color(0xFF334155))),
    ]);
  }

  Widget _cardEvolucaoMensal() {
    final dados = (_indicadores?['evolucao_mensal'] as List?) ?? [];

    if (dados.isEmpty) {
      return _containerCard(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _tituloCardGrafico("Evolução Mensal de Operações"),
            const SizedBox(height: 30),
            const Center(child: Text("Sem dados suficientes ainda", style: TextStyle(color: Colors.grey, fontSize: 12))),
            const SizedBox(height: 30),
          ],
        ),
      );
    }

    final spotsMercado = <FlSpot>[];
    final spotsFrota = <FlSpot>[];
    double maxY = 1;
    int idxMax = 0;
    int maiorTotal = -1;

    for (int i = 0; i < dados.length; i++) {
      final m = int.tryParse(dados[i]['mercado'].toString()) ?? 0;
      final f = int.tryParse(dados[i]['frota_propria'].toString()) ?? 0;
      spotsMercado.add(FlSpot(i.toDouble(), m.toDouble()));
      spotsFrota.add(FlSpot(i.toDouble(), f.toDouble()));
      if (m.toDouble() > maxY) maxY = m.toDouble();
      if (f.toDouble() > maxY) maxY = f.toDouble();
      if (m + f > maiorTotal) {
        maiorTotal = m + f;
        idxMax = i;
      }
    }

    return _containerCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _tituloCardGrafico(
            "Evolução Mensal de Operações",
            subtitulo: "Mês com mais operações: ${_formatarMesAno(dados[idxMax]['mes'])}",
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 170,
            child: LineChart(LineChartData(
              minY: 0,
              maxY: maxY + 1,
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              titlesData: FlTitlesData(
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    getTitlesWidget: (value, meta) {
                      final i = value.toInt();
                      if (i < 0 || i >= dados.length) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_formatarMesAno(dados[i]['mes']), style: const TextStyle(fontSize: 9)),
                      );
                    },
                  ),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    getTitlesWidget: (v, m) => Text(v.toInt().toString(), style: const TextStyle(fontSize: 9)),
                  ),
                ),
              ),
              borderData: FlBorderData(show: false),
              lineBarsData: [
                LineChartBarData(spots: spotsMercado, isCurved: true, color: Colors.indigo, barWidth: 2.5, dotData: const FlDotData(show: true)),
                LineChartBarData(spots: spotsFrota, isCurved: true, color: Colors.teal, barWidth: 2.5, dotData: const FlDotData(show: true)),
              ],
            )),
          ),
          const SizedBox(height: 10),
          Row(children: [
            _legendaLinhaGrafico(Colors.indigo, "Mercado"),
            const SizedBox(width: 16),
            _legendaLinhaGrafico(Colors.teal, "Frota Própria"),
          ]),
        ],
      ),
    );
  }

  Widget _cardTempoMedioOperacao() {
    final tm = _indicadores?['tempo_medio'];
    final atual = tm?['mes_atual'];
    final anterior = tm?['mes_anterior'];
    final mediaAtual = atual?['media_dias'];
    final mediaAnterior = anterior?['media_dias'];

    String fmt(dynamic v) => v == null ? '—' : '${(v as num).toStringAsFixed(1)} dias';

    bool? melhorou;
    if (mediaAtual != null && mediaAnterior != null) {
      melhorou = (mediaAtual as num) < (mediaAnterior as num);
    }

    return _containerCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _tituloCardGrafico("Tempo Médio de Operação", subtitulo: "Dias entre a coleta programada e a entrega finalizada"),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Mês Atual", style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Text(fmt(mediaAtual), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                    Text("${atual?['total'] ?? 0} operações", style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
                  ],
                ),
              ),
              if (melhorou != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(melhorou ? Icons.trending_down : Icons.trending_up, color: melhorou ? Colors.green : Colors.red, size: 30),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Mês Anterior", style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Text(fmt(mediaAnterior), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.grey)),
                    Text("${anterior?['total'] ?? 0} operações", style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _inicioCard(String titulo, String valor, IconData icone, Color cor, {VoidCallback? onTap, double fontSize = 17}) {
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 5)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: cor.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
                child: Icon(icone, color: cor, size: 12),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  titulo,
                  style: const TextStyle(fontSize: 10.5, color: Colors.grey, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onTap != null) Icon(Icons.chevron_right, color: Colors.grey[400], size: 13),
            ],
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(valor, style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.bold, color: cor)),
          ),
        ],
      ),
    );

    if (onTap == null) return card;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(12), child: card);
  }

  Widget _buildGestaoCargas() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // NOVO: "Total em Aberto", "Total a Pagar" e "Motoristas
        // Online/Livres" eram 3 cards grandes numa linha inteira só pra
        // eles. Viraram selos pequenos aqui do lado do título e do botão
        // "Publicar Nova Carga" — sobra bem mais altura pra Radar de
        // Cargas Ativas e Todas as Cargas Publicadas, que é onde o
        // trabalho de verdade acontece.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text("Radar de Cargas", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
            const SizedBox(width: 20),
            Expanded(
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  _kpiCompacto("Total em Aberto", "R\$ ${_formatarMoedaBr(_resumo['aberto'])}", Colors.orange),
                  _kpiCompacto("Total a Pagar", "R\$ ${_formatarMoedaBr(_resumo['pagar'])}", Colors.green),
                  _kpiMotoristasCompacto(),
                  ElevatedButton.icon(
                    onPressed: () => _navegarPara(5),
                    icon: const Icon(Icons.add),
                    label: const Text("Publicar Nova Carga"),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // NOVO: Radar em largura total — o formulário de cadastro saiu
        // daqui e virou a tela "Publicar Carga" (2 passos, tema TACLOG),
        // deixando essa tela só com a visão geral das cargas ativas.
        Expanded(
          flex: 2,
          child: _buildRadarCargas(),
        ),

        const SizedBox(height: 14),

        Expanded(
          flex: 1,
          child: _buildTabelaCargas(),
        ),
      ],
    );
  }

  // NOVO: versão pequena do indicador, em formato de selo/pill — usada
  // agora ao lado do título em vez do card grande de antes.
  Widget _kpiCompacto(String titulo, String valor, Color cor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(titulo, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 9)),
          Text(valor, style: TextStyle(fontSize: 13, color: cor, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // NOVO: mesma ideia do selo acima, só que clicável (abre a lista de
  // motoristas), reaproveitando o mesmo estilo azul de antes.
  Widget _kpiMotoristasCompacto() {
    return InkWell(
      onTap: _mostrarListaMotoristas,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.blue[50],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.blue[200]!, width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Motoristas Online/Livres", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 9)),
                Text("$_totalMotoristasAtivos / $_totalMotoristasLivres", style: const TextStyle(fontSize: 13, color: Color(0xFF0F172A), fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(width: 6),
            const Icon(Icons.touch_app, color: Colors.blue, size: 14),
          ],
        ),
      ),
    );
  }

  Widget _buildFormularioCarga() {
    return Card(
      shape: RoundedRectangleBorder(
        side: BorderSide(color: _editandoCargaId != null ? Colors.orange : Colors.transparent, width: 2),
        borderRadius: BorderRadius.circular(12)
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _editandoCargaId != null ? "✏️ Editando Carga #$_editandoCargaId" : "🚚 Nova Solicitação de Frete",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _editandoCargaId != null ? Colors.orange[800] : const Color(0xFF0F172A))
            ),
            const Divider(),

            _sessaoTitulo("1. Dados da Carga"),
            Row(
              children: [
                Expanded(flex: 2, child: _campoTexto("Tipo de Carga / Descrição", _descCtrl)),
                const SizedBox(width: 10),
                Expanded(child: _campoTexto("Peso (Kg)", _pesoCtrl, numerico: true)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TaclogSeletorTipoAgrupado(
                    label: "Carroceria exigida *",
                    valor: _classificacaoCarroceria,
                    carregar: _api.buscarTiposCarroceria,
                    onChanged: (v) => setState(() => _classificacaoCarroceria = v),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TaclogSeletorTipoAgrupado(
                    label: "Tipo de veículo (porte)",
                    valor: _classificacaoVeiculo,
                    carregar: _api.buscarTiposVeiculo,
                    permitirLimpar: true,
                    onChanged: (v) => setState(() => _classificacaoVeiculo = v),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(child: _campoTexto("Valor Frete (R\$)", _valorCtrl, numerico: true)),
                const SizedBox(width: 10),
                Expanded(child: _campoTexto("Valor Pedágio (R\$)", _pedagioCtrl, numerico: true)),
                const SizedBox(width: 10),
                Expanded(child: _campoTexto("Chave da NFe (Opcional)", _chaveNfeCtrl)),
              ],
            ),

            _sessaoTitulo("📍 Local de Coleta"),
            Row(
              children: [
                Expanded(child: _campoCep("CEP Coleta", _colCepCtrl, true)),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: _campoTexto("Nome do Local", _colNomeCtrl)),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: _campoTexto("Endereço (Rua, Av)", _colRuaCtrl)),
                const SizedBox(width: 10),
                Expanded(child: _campoTexto("Número", _colNumCtrl)),
              ],
            ),
            Row(
              children: [
                Expanded(child: _campoTexto("Bairro", _colBairroCtrl)),
                const SizedBox(width: 10),
                Expanded(child: _campoTexto("Cidade", _colCidadeCtrl)),
                const SizedBox(width: 10),
                Expanded(child: _campoTexto("Estado (UF)", _colUfCtrl)),
              ],
            ),

            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[100]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.my_location, size: 14, color: Colors.blueGrey),
                      const SizedBox(width: 6),
                      const Text(
                        "Ajuste fino da coleta (opcional)",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueGrey),
                      ),
                      const Spacer(),
                      OutlinedButton.icon(
                        onPressed: _abrirSeletorMapa,
                        icon: const Icon(Icons.map, size: 15),
                        label: const Text("Abrir Mapa", style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blue[800],
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 4, bottom: 6),
                    child: Text(
                      "Deixe em branco para localizar pelo endereço automaticamente. Preencha se a cidade tiver CEP geral (sem rua).",
                      style: TextStyle(fontSize: 10.5, color: Colors.black54),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(child: _campoTexto("Latitude (ex: -29.0233)", _colLatManualCtrl, numerico: true)),
                      const SizedBox(width: 10),
                      Expanded(child: _campoTexto("Longitude (ex: -51.1897)", _colLngManualCtrl, numerico: true)),
                    ],
                  ),
                ],
              ),
            ),

            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.schedule, size: 14, color: Colors.brown),
                      SizedBox(width: 6),
                      Text(
                        "Agendamento da coleta (opcional)",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.brown),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 4, bottom: 8),
                    child: Text(
                      "Deixe em branco para publicar e buscar motorista imediatamente.",
                      style: TextStyle(fontSize: 10.5, color: Colors.black54),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _selecionarDataColeta,
                          icon: const Icon(Icons.calendar_today, size: 14),
                          label: Text(
                            _dataColetaSelecionada == null
                                ? "Selecionar Data"
                                : "${_dataColetaSelecionada!.day.toString().padLeft(2, '0')}/${_dataColetaSelecionada!.month.toString().padLeft(2, '0')}/${_dataColetaSelecionada!.year}",
                            style: const TextStyle(fontSize: 12),
                          ),
                          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 8)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _selecionarHoraColeta,
                          icon: const Icon(Icons.access_time, size: 14),
                          label: Text(
                            _horaColetaSelecionada == null
                                ? "Selecionar Hora"
                                : "${_horaColetaSelecionada!.hour.toString().padLeft(2, '0')}:${_horaColetaSelecionada!.minute.toString().padLeft(2, '0')}",
                            style: const TextStyle(fontSize: 12),
                          ),
                          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 8)),
                        ),
                      ),
                      if (_dataColetaSelecionada != null || _horaColetaSelecionada != null) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.clear, size: 16, color: Colors.red),
                          tooltip: "Limpar agendamento",
                          onPressed: () => setState(() {
                            _dataColetaSelecionada = null;
                            _horaColetaSelecionada = null;
                            _antecedenciaMinutos = 0;
                          }),
                        ),
                      ],
                    ],
                  ),
                  if (_dataColetaSelecionada != null && _horaColetaSelecionada != null) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      value: _antecedenciaMinutos,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: "Disparar oferta com antecedência de",
                        labelStyle: TextStyle(fontSize: 11),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      items: _opcoesAntecedencia.entries
                          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, style: const TextStyle(fontSize: 12))))
                          .toList(),
                      onChanged: (v) => setState(() => _antecedenciaMinutos = v ?? 0),
                    ),
                  ],
                  if (_isTransportadora) ...[
                    const SizedBox(height: 6),
                    CheckboxListTile(
                      value: _preferenciaFrotaPropria || _escolherCaminhaoManualmente,
                      onChanged: (v) => setState(() {
                        _preferenciaFrotaPropria = v ?? false;
                        if (!_preferenciaFrotaPropria) {
                          _escolherCaminhaoManualmente = false;
                          _caminhaoDesignado = null;
                        }
                      }),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -4),
                      activeColor: Colors.blue,
                      title: const Text(
                        "Usar um caminhão da minha frota nesta carga",
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    if (_preferenciaFrotaPropria || _escolherCaminhaoManualmente) ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 32),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            RadioListTile<bool>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              visualDensity: const VisualDensity(vertical: -4),
                              title: const Text("Automático (caminhão da frota mais próximo)", style: TextStyle(fontSize: 12)),
                              value: false,
                              groupValue: _escolherCaminhaoManualmente,
                              onChanged: (v) => setState(() {
                                _escolherCaminhaoManualmente = false;
                                _caminhaoDesignado = null;
                              }),
                            ),
                            RadioListTile<bool>(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              visualDensity: const VisualDensity(vertical: -4),
                              title: const Text("Escolher caminhão específico da frota", style: TextStyle(fontSize: 12)),
                              value: true,
                              groupValue: _escolherCaminhaoManualmente,
                              onChanged: (v) => setState(() => _escolherCaminhaoManualmente = true),
                            ),
                            if (_escolherCaminhaoManualmente)
                              Padding(
                                padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
                                child: Row(
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: _abrirSeletorCaminhaoDesignado,
                                      icon: const Icon(Icons.local_shipping, size: 15),
                                      label: Text(
                                        _caminhaoDesignado == null ? "Selecionar caminhão" : "Caminhão: ${_caminhaoDesignado!['placa']}",
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        minimumSize: Size.zero,
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                    if (_caminhaoDesignado != null)
                                      IconButton(
                                        icon: const Icon(Icons.close, size: 16, color: Colors.red),
                                        tooltip: "Limpar seleção",
                                        onPressed: () => setState(() => _caminhaoDesignado = null),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),

            _sessaoTitulo("🏁 Local de Entrega (Destinatário)"),
            Row(
              children: [
                Expanded(child: _campoCep("CEP Entrega", _entCepCtrl, false)),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: _campoTexto("Nome do Local", _entNomeCtrl)),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: _campoTexto("Endereço (Rua, Av)", _entRuaCtrl)),
                const SizedBox(width: 10),
                Expanded(child: _campoTexto("Número", _entNumCtrl)),
              ],
            ),
            Row(
              children: [
                Expanded(child: _campoTexto("Bairro", _entBairroCtrl)),
                const SizedBox(width: 10),
                Expanded(child: _campoTexto("Cidade", _entCidadeCtrl)),
                const SizedBox(width: 10),
                Expanded(child: _campoTexto("Estado (UF)", _entUfCtrl)),
              ],
            ),

            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_editandoCargaId != null) ...[
                  TextButton(
                    onPressed: _cancelarEdicao,
                    child: const Text("CANCELAR", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))
                  ),
                  const SizedBox(width: 12),
                ],
                ElevatedButton(
                  onPressed: _isLoading ? null : _salvarCarga,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _editandoCargaId != null ? Colors.orange[800] : Colors.blue,
                  ),
                  child: _isLoading
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text(_editandoCargaId != null ? "ATUALIZAR CARGA" : "CADASTRAR E BUSCAR MOTORISTA", style: const TextStyle(color: Colors.white)),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _buildRadarCargas() {
    final cargasAtivas = _cargas.where((c) => c['status'] != 'CANCELADA').toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.radar, color: Colors.blue),
                SizedBox(width: 10),
                Text("Radar de Cargas Ativas", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
              ],
            ),
            const Divider(),
            Expanded(
              child: _isLoading && cargasAtivas.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : cargasAtivas.isEmpty
                    ? const Center(child: Text("Nenhuma carga no radar.", style: TextStyle(color: Colors.grey)))
                    : ListView.builder(
                        itemCount: cargasAtivas.length,
                        itemBuilder: (ctx, i) => _cardRadarCompacto(cargasAtivas[i]),
                      ),
            )
          ],
        ),
      ),
    );
  }

  // NOVO: card de uma linha só (antes era um bloco grande, com várias
  // informações empilhadas verticalmente) — status, ID, rota, agendamento,
  // valor e as ações, tudo numa faixa horizontal estreita. Cabe muito mais
  // carga na tela sem precisar rolar tanto — a cor da barrinha à esquerda
  // e o ícone continuam indicando o status, igual antes.
  Widget _cardRadarCompacto(Map<String, dynamic> c) {
    final cor = _corBordaPorStatus(c['status']);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: cor, width: 4)),
        borderRadius: BorderRadius.circular(6),
        color: _corPorStatus(c['status']),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: c['status'] == 'DISPONIVEL'
                ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_iconePorStatus(c['status']), color: cor, size: 16),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 150,
            child: Text(
              _textoPorStatus(c['status']),
              style: TextStyle(fontWeight: FontWeight.bold, color: cor, fontSize: 11),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: Text(
              "ID #${c['id']} - ${c['descricao']}",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 4,
            child: Text(
              "${c['col_cidade']} (${c['col_uf']}) ➔ ${c['ent_cidade']} (${c['ent_uf']}) - ${c['tipo_veiculo_necessario']}",
              style: const TextStyle(fontSize: 11.5),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          if (c['data_coleta'] != null) ...[
            const SizedBox(width: 10),
            SizedBox(
              width: 150,
              child: Text(
                "📅 ${_formatarDataColetaCard(c['data_coleta'], c['hora_coleta']) ?? ''}",
                style: const TextStyle(fontSize: 10.5, fontStyle: FontStyle.italic, color: Colors.indigo),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
          const SizedBox(width: 10),
          SizedBox(
            width: 115,
            child: Text(
              "R\$ ${_formatarMoedaBr(c['valor_frete'])}",
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green, fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.visibility, size: 16),
            onPressed: () => _mostrarDetalhesCarga(c),
            tooltip: "Detalhes",
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          ),
          if (['DISPONIVEL', 'AGENDADA'].contains(c['status']))
            IconButton(
              icon: const Icon(Icons.edit, color: Colors.blue, size: 16),
              onPressed: () => _prepararEdicao(c),
              tooltip: "Editar",
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            ),
          if (['EM_ANDAMENTO', 'COLETADA'].contains(c['status']))
            IconButton(
              icon: const Icon(Icons.person_remove, color: Colors.orange, size: 16),
              onPressed: () => _cancelarAceiteMotorista(c['id']),
              tooltip: "Cancelar aceite do motorista",
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            ),
          if (c['status'] != 'ENTREGUE')
            IconButton(
              icon: const Icon(Icons.delete_forever, color: Colors.red, size: 16),
              onPressed: () => _excluirCarga(c['id']),
              tooltip: "Excluir Carga Permanentemente",
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            ),
        ],
      ),
    );
  }

  Widget _buildTabelaCargas() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.table_chart, color: Colors.blueGrey, size: 18),
                SizedBox(width: 8),
                Text("Todas as Cargas Publicadas", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
              ],
            ),
            const Divider(),
            Expanded(
              child: _cargas.isEmpty
                  ? const Center(child: Text("Nenhuma carga cadastrada ainda.", style: TextStyle(color: Colors.grey, fontSize: 12)))
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        child: DataTable(
                          headingRowHeight: 34,
                          dataRowMinHeight: 32,
                          dataRowMaxHeight: 36,
                          columnSpacing: 22,
                          headingTextStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5, color: Color(0xFF334155)),
                          dataTextStyle: const TextStyle(fontSize: 12, color: Color(0xFF0F172A)),
                          columns: const [
                            DataColumn(label: Text("ID CARGA")),
                            DataColumn(label: Text("DESCRIÇÃO")),
                            DataColumn(label: Text("COLETA")),
                            DataColumn(label: Text("DESTINO")),
                            DataColumn(label: Text("DISTÂNCIA")),
                            DataColumn(label: Text("TIPO")),
                            DataColumn(label: Text("VALOR"), numeric: true),
                            DataColumn(label: Text("DATA COLETA")),
                            DataColumn(label: Text("STATUS")),
                          ],
                          rows: _cargas.map<DataRow>((c) {
                            return DataRow(
                              onSelectChanged: (_) => _mostrarDetalhesCarga(c),
                              cells: [
                                DataCell(Text("#${c['id']}")),
                                DataCell(SizedBox(width: 140, child: Text(c['descricao']?.toString() ?? '', overflow: TextOverflow.ellipsis))),
                                DataCell(Text("${c['col_cidade'] ?? ''}/${c['col_uf'] ?? ''}")),
                                DataCell(Text("${c['ent_cidade'] ?? ''}/${c['ent_uf'] ?? ''}")),
                                DataCell(Text(c['distancia_km'] != null ? "${c['distancia_km']} Km" : "N/D")),
                                DataCell(Text(c['tipo_veiculo_necessario']?.toString() ?? '')),
                                DataCell(Text("R\$ ${_formatarMoedaBr(c['valor_frete'])}")),
                                DataCell(Text(_formatarDataColetaCard(c['data_coleta'], c['hora_coleta']) ?? '—')),
                                DataCell(_statusChip(c['status'])),
                              ],
                            );
                          }).toList(),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _corPorStatus(status),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _corBordaPorStatus(status)),
      ),
      child: Text(
        _statusChipLabel(status),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _corBordaPorStatus(status)),
      ),
    );
  }

  String _statusChipLabel(String status) {
    switch (status) {
      case 'DISPONIVEL': return "Procurando Motorista";
      case 'AGENDADA': return "Agendada";
      case 'EM_ANDAMENTO': return "Achou Motorista";
      case 'COLETADA': return "Em Trânsito";
      case 'ENTREGUE': return "Finalizada";
      case 'CANCELADA': return "Cancelada";
      default: return status;
    }
  }

  Widget _sessaoTitulo(String titulo) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(color: const Color(0xFFE2E8F0), borderRadius: BorderRadius.circular(5)),
        child: Text(titulo, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF334155), fontSize: 13)),
      ),
    );
  }

  Widget _campoTexto(String label, TextEditingController ctrl, {bool numerico = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: ctrl,
        keyboardType: numerico ? const TextInputType.numberWithOptions(decimal: true, signed: true) : TextInputType.text,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontSize: 12),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
      ),
    );
  }

  Widget _campoCep(String label, TextEditingController ctrl, bool isColeta) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus && ctrl.text.replaceAll(RegExp(r'[^0-9]'), '').length == 8) {
            _buscarCep(ctrl.text, isColeta);
          }
        },
        child: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(fontSize: 12),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            suffixIcon: IconButton(
              icon: const Icon(Icons.search, color: Colors.blue, size: 18),
              onPressed: () => _buscarCep(ctrl.text, isColeta),
            ),
          ),
          onEditingComplete: () => _buscarCep(ctrl.text, isColeta),
        ),
      ),
    );
  }

  Color _corPorStatus(String status) {
    switch (status) {
      case 'DISPONIVEL': return const Color(0xFFFFFBEB);
      case 'AGENDADA': return const Color(0xFFEEF2FF);
      case 'EM_ANDAMENTO': return const Color(0xFFDBEAFE);
      case 'COLETADA': return const Color(0xFFF3E8FF);
      case 'ENTREGUE': return const Color(0xFFDCFCE7);
      case 'CANCELADA': return const Color(0xFFFEE2E2);
      default: return Colors.white;
    }
  }

  Color _corBordaPorStatus(String status) {
    switch (status) {
      case 'DISPONIVEL': return Colors.orange[800]!;
      case 'AGENDADA': return Colors.indigo[700]!;
      case 'EM_ANDAMENTO': return Colors.blue[800]!;
      case 'COLETADA': return Colors.purple[800]!;
      case 'ENTREGUE': return Colors.green[800]!;
      case 'CANCELADA': return Colors.red[700]!;
      default: return Colors.grey;
    }
  }

  IconData _iconePorStatus(String status) {
    switch (status) {
      case 'AGENDADA': return Icons.schedule;
      case 'EM_ANDAMENTO': return Icons.verified;
      case 'COLETADA': return Icons.local_shipping;
      case 'ENTREGUE': return Icons.flag;
      default: return Icons.info;
    }
  }

  String _textoPorStatus(String status) {
    switch (status) {
      case 'DISPONIVEL': return "PROCURANDO MOTORISTA...";
      case 'AGENDADA': return "AGENDADA - AGUARDANDO HORÁRIO DE DISPARO";
      case 'EM_ANDAMENTO': return "MOTORISTA A CAMINHO DA COLETA";
      case 'COLETADA': return "CARGA EM TRÂNSITO (COLETADA)";
      case 'ENTREGUE': return "ENTREGA FINALIZADA";
      default: return status;
    }
  }
}

// NOVO: mesmo mini-calendário usado em todas as outras telas do sistema —
// um clique no dia já escolhe (sem precisar de botão de confirmar), com
// navegação independente de mês e de ano.
class _MiniCalendarioPopup extends StatefulWidget {
  final DateTime dataInicial;

  const _MiniCalendarioPopup({required this.dataInicial});

  @override
  State<_MiniCalendarioPopup> createState() => _MiniCalendarioPopupState();
}

class _MiniCalendarioPopupState extends State<_MiniCalendarioPopup> {
  late DateTime _mesAtual;

  static const _nomesMeses = [
    'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho',
    'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro',
  ];
  static const _nomesDiasSemana = ['D', 'S', 'T', 'Q', 'Q', 'S', 'S'];

  @override
  void initState() {
    super.initState();
    _mesAtual = DateTime(widget.dataInicial.year, widget.dataInicial.month, 1);
  }

  void _mudarMes(int delta) {
    setState(() => _mesAtual = DateTime(_mesAtual.year, _mesAtual.month + delta, 1));
  }

  void _mudarAno(int delta) {
    setState(() => _mesAtual = DateTime(_mesAtual.year + delta, _mesAtual.month, 1));
  }

  bool _mesmoDia(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final primeiroDoMes = DateTime(_mesAtual.year, _mesAtual.month, 1);
    final diasNoMes = DateTime(_mesAtual.year, _mesAtual.month + 1, 0).day;
    final offsetInicial = primeiroDoMes.weekday % 7; // domingo = 0
    final hoje = DateTime.now();
    final selecionado = widget.dataInicial;

    final celulas = <Widget>[];
    for (int i = 0; i < offsetInicial; i++) {
      celulas.add(const SizedBox());
    }
    for (int dia = 1; dia <= diasNoMes; dia++) {
      final data = DateTime(_mesAtual.year, _mesAtual.month, dia);
      final ehHoje = _mesmoDia(data, hoje);
      final ehSelecionado = _mesmoDia(data, selecionado);
      celulas.add(
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => Navigator.of(context).pop(data),
          child: Container(
            margin: const EdgeInsets.all(2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: ehSelecionado ? Colors.blue : (ehHoje ? Colors.blue.withOpacity(0.12) : Colors.transparent),
              borderRadius: BorderRadius.circular(6),
              border: ehHoje && !ehSelecionado ? Border.all(color: Colors.blue, width: 1) : null,
            ),
            child: Text(
              '$dia',
              style: TextStyle(
                color: ehSelecionado ? Colors.white : Colors.black87,
                fontWeight: ehSelecionado || ehHoje ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ),
      );
    }

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(icon: const Icon(Icons.keyboard_double_arrow_left), tooltip: 'Ano anterior', onPressed: () => _mudarAno(-1)),
                Text('${_mesAtual.year}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                IconButton(icon: const Icon(Icons.keyboard_double_arrow_right), tooltip: 'Próximo ano', onPressed: () => _mudarAno(1)),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(icon: const Icon(Icons.chevron_left), tooltip: 'Mês anterior', onPressed: () => _mudarMes(-1)),
                Text(_nomesMeses[_mesAtual.month - 1], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.blue)),
                IconButton(icon: const Icon(Icons.chevron_right), tooltip: 'Próximo mês', onPressed: () => _mudarMes(1)),
              ],
            ),
            const SizedBox(height: 6),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: _nomesDiasSemana
                  .map((d) => Center(
                        child: Text(d, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueGrey)),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 2),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: celulas,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancelar'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// NOVO: seletor de horário com dois menus (dropdown) — um pra hora, outro
// pra minuto, lado a lado. Mesmo formato usado agora em todas as telas do
// sistema, no lugar do relógio de ponteiro padrão do Flutter.
class _MiniHoraPopup extends StatefulWidget {
  final TimeOfDay horaInicial;

  const _MiniHoraPopup({required this.horaInicial});

  @override
  State<_MiniHoraPopup> createState() => _MiniHoraPopupState();
}

class _MiniHoraPopupState extends State<_MiniHoraPopup> {
  late int _hora;
  late int _minuto;

  static const _minutosDisponiveis = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55];

  @override
  void initState() {
    super.initState();
    _hora = widget.horaInicial.hour;
    _minuto = ((widget.horaInicial.minute / 5).round() * 5) % 60;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 280,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Escolha o horário", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _dropdownDeHoraOuMinuto(
                  label: "HORA",
                  valor: _hora,
                  itens: List.generate(24, (i) => i),
                  onChanged: (v) => setState(() => _hora = v),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 26, left: 8, right: 8),
                  child: Text(":", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                ),
                _dropdownDeHoraOuMinuto(
                  label: "MINUTO",
                  valor: _minuto,
                  itens: _minutosDisponiveis,
                  onChanged: (v) => setState(() => _minuto = v),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancelar")),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(TimeOfDay(hour: _hora, minute: _minuto)),
                  child: const Text("Selecionar"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dropdownDeHoraOuMinuto({
    required String label,
    required int valor,
    required List<int> itens,
    required ValueChanged<int> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
        const SizedBox(height: 6),
        SizedBox(
          width: 92,
          child: DropdownButtonFormField<int>(
            value: valor,
            isExpanded: true,
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
            items: itens.map((v) => DropdownMenuItem(value: v, child: Text(v.toString().padLeft(2, '0')))).toList(),
            onChanged: (v) => onChanged(v!),
          ),
        ),
      ],
    );
  }
}


