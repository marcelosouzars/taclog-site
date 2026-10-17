// API_SERVICE_APP.DART (APP MOTORISTA)

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';

// Lançada quando login/senha estão corretos mas o e-mail do motorista
// ainda não foi confirmado. Carrega o e-mail para a tela de login poder
// mandar direto para a VerificacaoScreen.
class EmailNaoVerificadoException implements Exception {
  final String email;
  EmailNaoVerificadoException(this.email);
}

// NOVO (GESTORA): lançada quando a pessoa logada no app como gestora não
// tem (mais) acesso — conta inativa/suspensa, marca de gestora retirada ou
// sessão inválida. Quem captura volta pra tela de login.
class GestoraSemAcessoException implements Exception {
  final String mensagem;
  GestoraSemAcessoException(this.mensagem);
  @override
  String toString() => mensagem;
}

// NOVO (GESTORA): senha provisória ainda não trocada — o servidor só deixa
// a pessoa chamar a troca de senha até ela definir uma senha definitiva.
class SenhaProvisoriaException implements Exception {}

class ApiService {
  // URL Oficial de Produção
  static const String baseUrl = 'https://taclog-backend.onrender.com';
  
  static String? _token;
  static String? get token => _token; 

  static Future<void> carregarToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('jwt_token');
  }

  static Future<Map<String, String>> getHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    String? token = prefs.getString('jwt_token');
    return {
      "Content-Type": "application/json",
      "Authorization": "Bearer $token"
    };
  }

  // NOVO: tenta captar a localização atual pra gravar junto do login no
  // Log do Sistema. NUNCA pede permissão aqui — só usa se ela já tiver
  // sido concedida antes (na tela de permissão logo após o primeiro
  // login); pedir agora, antes da pessoa nem ter entrado no app,
  // atropelaria aquela explicação. Por isso o primeiro login de cada
  // motorista fica sem coordenada, e os próximos já vêm com ela. Nunca
  // deixa o login mais lento por causa disso nem falha se não conseguir.
  Future<Position?> _tentarObterLocalizacaoAtual() async {
    try {
      final servicoAtivo = await Geolocator.isLocationServiceEnabled();
      if (!servicoAtivo) return null;

      final permissao = await Geolocator.checkPermission();
      if (permissao != LocationPermission.always && permissao != LocationPermission.whileInUse) {
        return null;
      }

      try {
        return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium, timeLimit: const Duration(seconds: 5));
      } catch (_) {
        return await Geolocator.getLastKnownPosition();
      }
    } catch (_) {
      return null;
    }
  }

  // --- LOGIN ORIGINAL INTACTO ---
  Future<Map<String, dynamic>> login(String cpf, String senha) async {
    final url = Uri.parse('$baseUrl/api/login');

    try {
      final posicao = await _tentarObterLocalizacaoAtual();
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        // NOVO: "origem": "APP" identifica pro Log do Sistema que este
        // login veio do aplicativo do celular (TAC ou motorista de frota).
        // "lat"/"lng" só vão quando dá pra captar (ver acima).
        body: jsonEncode({
          "cpf": cpf,
          "senha": senha,
          "origem": "APP",
          if (posicao != null) "lat": posicao.latitude,
          if (posicao != null) "lng": posicao.longitude,
        }),
      );

      if (response.statusCode == 200) {
        final responseBody = jsonDecode(response.body);
        _token = responseBody['token'];
        
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('jwt_token', _token!);
        await prefs.setString('usuario_nome', responseBody['nome'] ?? 'Motorista');
        await prefs.setString('foto_url', responseBody['foto_url'] ?? '');
        
        return responseBody;
      } else if (response.statusCode == 403) {
        // Login e senha corretos, mas conta com e-mail não confirmado
        // (ou, NOVO, conta desativada pelo próprio motorista).
        final erroJson = jsonDecode(response.body);
        if (erroJson['error'] == 'EMAIL_NAO_VERIFICADO') {
          throw EmailNaoVerificadoException(erroJson['email'] ?? cpf);
        }
        // Prefere a mensagem pronta do backend (mais amigável) — CPF ou
        // senha corretos, mas algo impede o login (ex.: CONTA_DESATIVADA).
        throw Exception(erroJson['message'] ?? erroJson['error'] ?? 'Acesso negado.');
      } else {
        String msgErro = "Erro desconhecido";
        try {
          msgErro = jsonDecode(response.body)['error'];
        } catch (e) {
          msgErro = "Erro de conexão (Status ${response.statusCode}). Verifique se o servidor está online.";
        }
        throw Exception(msgErro);
      }
    } on EmailNaoVerificadoException {
      rethrow;
    } catch (e) {
      throw Exception("Falha ao conectar no servidor: $e");
    }
  }

  // NOVO: o próprio motorista desativando a conta dele — ver tela de
  // confirmação em 3 passos (desativar_conta_screen_app.dart). Depois de
  // chamar isso com sucesso, quem chamou é responsável por limpar o
  // SharedPreferences e levar de volta pro login.
  Future<void> desativarConta() async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/motorista/desativar-conta'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      final msg = jsonDecode(response.body)['error'] ?? 'Erro ao desativar a conta.';
      throw Exception(msg);
    }
  }

  // --- LOCALIZAÇÃO ORIGINAL ---
  Future<void> enviarLocalizacao(double lat, double long) async {
    final headers = await getHeaders();
    await http.post(
      Uri.parse('$baseUrl/api/motorista/localizacao'),
      headers: headers,
      body: jsonEncode({"latitude": lat, "longitude": long}),
    );
  }

  // --- GESTÃO DE FROTA — CAMINHÕES ---
  Future<List<dynamic>> getMeusCaminhoes() async {
    final headers = await getHeaders();
    final response = await http.get(
      Uri.parse('$baseUrl/api/motorista/meus-caminhoes'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar frota');
    }
  }

  Future<void> selecionarCaminhao(int caminhaoId) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/motorista/selecionar-caminhao'),
      headers: headers,
      body: jsonEncode({"caminhao_id": caminhaoId}),
    );
    if (response.statusCode != 200) {
      final msg = jsonDecode(response.body)['error'] ?? 'Erro ao selecionar caminhão';
      throw Exception(msg);
    }
  }

  Future<void> cadastrarCaminhao(Map<String, dynamic> dadosCaminhao) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/caminhao/cadastro'),
      headers: headers,
      body: jsonEncode(dadosCaminhao),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      final msg = jsonDecode(response.body)['error'] ?? 'Erro ao cadastrar caminhão';
      throw Exception(msg);
    }
  }

  Future<void> atualizarCaminhao(int caminhaoId, Map<String, dynamic> dadosCaminhao) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/caminhao/$caminhaoId'),
      headers: headers,
      body: jsonEncode(dadosCaminhao),
    );
    if (response.statusCode != 200) {
      final msg = jsonDecode(response.body)['error'] ?? 'Erro ao atualizar caminhão';
      throw Exception(msg);
    }
  }

  // --- TIPOS DE VEÍCULO / CARROCERIA (nomenclatura de mercado) ---
  // Retorno: [{ grupo: 'PESADO', itens: [{codigo, nome}, ...] }, ...]
  Future<List<dynamic>> buscarTiposVeiculo() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/tipos-veiculo'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    throw Exception('Erro ao buscar os tipos de veículo.');
  }

  Future<List<dynamic>> buscarTiposCarroceria() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/tipos-carroceria'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    throw Exception('Erro ao buscar os tipos de carroceria.');
  }

  // --- GESTÃO DE FROTA — CARRETAS (CADASTRO V2) ---
  Future<List<dynamic>> getMinhasCarretas() async {
    final headers = await getHeaders();
    final response = await http.get(
      Uri.parse('$baseUrl/api/motorista/minhas-carretas'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar carretas');
    }
  }

  Future<void> cadastrarCarreta(Map<String, dynamic> dadosCarreta) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/carreta/cadastro'),
      headers: headers,
      body: jsonEncode(dadosCarreta),
    );
    if (response.statusCode != 201 && response.statusCode != 200) {
      final msg = jsonDecode(response.body)['error'] ?? 'Erro ao cadastrar carreta';
      throw Exception(msg);
    }
  }

  Future<void> atualizarCarreta(int carretaId, Map<String, dynamic> dadosCarreta) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/carreta/$carretaId'),
      headers: headers,
      body: jsonEncode(dadosCarreta),
    );
    if (response.statusCode != 200) {
      final msg = jsonDecode(response.body)['error'] ?? 'Erro ao atualizar carreta';
      throw Exception(msg);
    }
  }

  Future<void> excluirCarreta(int carretaId) async {
    final headers = await getHeaders();
    final response = await http.delete(
      Uri.parse('$baseUrl/api/carreta/$carretaId'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      final msg = jsonDecode(response.body)['error'] ?? 'Erro ao excluir carreta';
      throw Exception(msg);
    }
  }

  // --- ACOPLAMENTO CAMINHÃO + CARRETA (CADASTRO V2) ---
  Future<void> acoplarCarreta(int caminhaoId, int carretaId) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/motorista/acoplar-carreta'),
      headers: headers,
      body: jsonEncode({"caminhao_id": caminhaoId, "carreta_id": carretaId}),
    );
    if (response.statusCode != 201) {
      final msg = jsonDecode(response.body)['error'] ?? 'Erro ao acoplar carreta';
      throw Exception(msg);
    }
  }

  Future<void> desacoplarCarreta(int caminhaoId) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/motorista/desacoplar-carreta'),
      headers: headers,
      body: jsonEncode({"caminhao_id": caminhaoId}),
    );
    if (response.statusCode != 200) {
      final msg = jsonDecode(response.body)['error'] ?? 'Erro ao desacoplar carreta';
      throw Exception(msg);
    }
  }

  Future<Map<String, dynamic>?> getAcoplamentoAtivo(int caminhaoId) async {
    final headers = await getHeaders();
    final response = await http.get(
      Uri.parse('$baseUrl/api/caminhao/$caminhaoId/acoplamento-ativo'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data == null ? null : Map<String, dynamic>.from(data);
    } else {
      throw Exception('Erro ao buscar acoplamento ativo');
    }
  }

  // NOVO: histórico completo de acoplamentos/desacoplamentos de um
  // caminhão — quem acoplou, quando começou e quando terminou cada
  // vínculo com uma carreta.
  Future<List<dynamic>> getHistoricoAcoplamentos(int caminhaoId) async {
    final headers = await getHeaders();
    final response = await http.get(
      Uri.parse('$baseUrl/api/caminhao/$caminhaoId/historico-acoplamentos'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar histórico de acoplamentos');
    }
  }

  // --- REGRAS DE CANCELAMENTO E VALIDAÇÃO DA CARGA ---
  Future<void> cancelarViagemMotorista(int cargaId) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/cargas/cancelar-motorista'),
      headers: headers,
      body: jsonEncode({"id": cargaId}),
    );
    if (response.statusCode != 200) {
      throw Exception('Erro ao cancelar viagem.');
    }
  }

  Future<Map<String, dynamic>> verificarStatusCargaAtual(int cargaId) async {
    final headers = await getHeaders();
    final response = await http.get(
      Uri.parse('$baseUrl/api/motorista/carga-atual/$cargaId'),
      headers: headers,
    );
    
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else if (response.statusCode == 404) {
      throw Exception('CARGA_EXCLUIDA');
    } else if (response.statusCode == 403) {
      throw Exception('MOTORISTA_ALTERADO');
    } else {
      throw Exception('Erro ao verificar status da carga');
    }
  }

  // NOVO: Finalizar entrega enviando as coordenadas exatas
  Future<void> finalizarEntregaOperacional(int cargaId, double lat, double lng) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/cargas/finalizar'),
      headers: headers,
      body: jsonEncode({"id": cargaId, "lat": lat, "lng": lng}),
    );
    if (response.statusCode != 200) {
      throw Exception('Erro ao finalizar a entrega.');
    }
  }

  // --- NOTIFICAÇÕES DO MOTORISTA (avisos de coleta da frota, quando ele
  // dirige um caminhão de uma transportadora) ---
  Future<List<dynamic>> getNotificacoesMotorista() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/motorista/notificacoes'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar notificações.');
    }
  }

  Future<int> contarNotificacoesMotoristaNaoLidas() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/motorista/notificacoes/contagem'), headers: headers);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['total_nao_lidas'] ?? 0;
    } else {
      return 0;
    }
  }

  Future<void> marcarNotificacaoMotoristaLida(int id) async {
    final headers = await getHeaders();
    final response = await http.put(Uri.parse('$baseUrl/api/motorista/notificacoes/$id/marcar-lida'), headers: headers);
    if (response.statusCode != 200) {
      throw Exception('Erro ao marcar notificação como lida.');
    }
  }

  Future<void> marcarTodasNotificacoesMotoristaLidas() async {
    final headers = await getHeaders();
    final response = await http.put(Uri.parse('$baseUrl/api/motorista/notificacoes/marcar-todas-lidas'), headers: headers);
    if (response.statusCode != 200) {
      throw Exception('Erro ao marcar notificações como lidas.');
    }
  }

  // ==========================================
  // GESTORA — avisos de coleta no celular
  // (funcionária de escritório marcada como "gestora" na tela Usuários)
  // ==========================================
  void _conferirRespostaGestora(http.Response response) {
    if (response.statusCode == 200) return;
    String? codigo;
    String? mensagem;
    try {
      final corpo = jsonDecode(response.body);
      codigo = corpo['error']?.toString();
      mensagem = corpo['message']?.toString();
    } catch (_) {}
    if (codigo == 'SENHA_PROVISORIA') throw SenhaProvisoriaException();
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw GestoraSemAcessoException(mensagem ?? 'Sua sessão expirou. Entre de novo.');
    }
    throw Exception(mensagem ?? codigo ?? 'Erro ao falar com o servidor.');
  }

  Future<List<dynamic>> getNotificacoesGestor() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/gestor/notificacoes'), headers: headers);
    _conferirRespostaGestora(response);
    return jsonDecode(response.body);
  }

  Future<void> marcarNotificacaoGestorLida(int id) async {
    final headers = await getHeaders();
    final response = await http.put(Uri.parse('$baseUrl/api/gestor/notificacoes/$id/marcar-lida'), headers: headers);
    _conferirRespostaGestora(response);
  }

  Future<void> marcarTodasNotificacoesGestorLidas() async {
    final headers = await getHeaders();
    final response = await http.put(Uri.parse('$baseUrl/api/gestor/notificacoes/marcar-todas-lidas'), headers: headers);
    _conferirRespostaGestora(response);
  }

  // Troca da senha provisória (mesma rota usada pelo painel web). O servidor
  // devolve um token novo, já sem a marca de provisória — guardamos ele.
  Future<void> trocarSenhaFuncionario(String novaSenha, String confirmarSenha) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/funcionario/trocar-senha'),
      headers: headers,
      body: jsonEncode({"nova_senha": novaSenha, "confirmar_senha": confirmarSenha}),
    );
    if (response.statusCode != 200) {
      String msg = 'Erro ao trocar a senha.';
      try {
        msg = jsonDecode(response.body)['error']?.toString() ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }
    final corpo = jsonDecode(response.body);
    if (corpo['token'] != null) {
      _token = corpo['token'];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('jwt_token', _token!);
    }
  }

  // --- FOTOS DO VEÍCULO (caminhão e carreta) ---
  // Caminhão que o motorista está usando agora + carreta acoplada, com as
  // fotos já enviadas. Resposta: {caminhao: {...}|null, carreta: {...}|null}
  Future<Map<String, dynamic>> getVeiculoAtual() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/motorista/veiculo-atual'), headers: headers);
    if (response.statusCode != 200) {
      throw Exception('Erro ao buscar o veículo atual.');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body));
  }

  // Envia uma foto do veículo. [tipo]: 'caminhao' ou 'carreta'.
  // [posicao]: 'lateral' ou 'diagonal'. Devolve a URL da foto salva.
  Future<String> enviarFotoVeiculo({
    required String tipo,
    required dynamic id,
    required String posicao,
    required List<int> bytes,
    required String nomeArquivo,
  }) async {
    final headers = await getHeaders();
    headers.remove('Content-Type');
    final rota = tipo == 'carreta' ? 'carretas' : 'caminhoes';

    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/motorista/$rota/$id/foto/$posicao'));
    request.headers.addAll(headers);
    request.files.add(http.MultipartFile.fromBytes(
      'arquivo',
      bytes,
      filename: nomeArquivo.isNotEmpty ? nomeArquivo : 'foto_veiculo.jpg',
    ));

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200) {
      return (jsonDecode(response.body)['foto_url'] ?? '').toString();
    }
    String msg = 'Erro ao enviar a foto.';
    try {
      msg = jsonDecode(response.body)['error']?.toString() ?? msg;
    } catch (_) {}
    throw Exception(msg);
  }

  // ---------------------------------------------------------------------
  // TERMOS DE USO E POLÍTICA DE PRIVACIDADE (aceite — LGPD)
  // ---------------------------------------------------------------------

  // Texto completo dos termos (público, não precisa de login).
  Future<Map<String, dynamic>> buscarTermos() async {
    final response = await http.get(Uri.parse('$baseUrl/api/termos'));
    if (response.statusCode != 200) {
      throw Exception('Não foi possível carregar os termos. Tente de novo.');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body));
  }

  // A pessoa logada já aceitou a versão vigente dos termos?
  Future<Map<String, dynamic>> statusTermos() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/termos/status'), headers: headers);
    if (response.statusCode != 200) {
      throw Exception('Erro ao consultar o aceite dos termos.');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body));
  }

  // Registra o aceite dos termos (data, versão, IP e aparelho ficam gravados
  // no servidor).
  Future<void> aceitarTermos({
    required String versao,
    bool aceitouLocalizacao = false,
    bool aceitouComunicacoes = false,
    bool declarouPoderes = false,
  }) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/termos/aceitar'),
      headers: headers,
      body: jsonEncode({
        'versao': versao,
        'aceitou_termos': true,
        'aceitou_localizacao': aceitouLocalizacao,
        'aceitou_comunicacoes': aceitouComunicacoes,
        'declarou_poderes': declarouPoderes,
        'origem': 'APP',
      }),
    );
    if (response.statusCode != 200) {
      String msg = 'Erro ao registrar o aceite.';
      try {
        final j = jsonDecode(response.body);
        msg = (j['message'] ?? j['error'] ?? msg).toString();
      } catch (_) {}
      throw Exception(msg);
    }
  }

  // ---------------------------------------------------------------------
  // NOTIFICAÇÕES PUSH (aparelho do motorista / da gestora)
  // ---------------------------------------------------------------------

  // Guarda no servidor o "endereço" deste celular para receber avisos
  // mesmo com o app fechado.
  Future<void> registrarAparelhoPush(String token, String plataforma) async {
    final headers = await getHeaders();
    await http.post(
      Uri.parse('$baseUrl/api/push/registrar'),
      headers: headers,
      body: jsonEncode({'token': token, 'plataforma': plataforma}),
    );
  }

  Future<void> removerAparelhoPush(String token) async {
    final headers = await getHeaders();
    await http.post(
      Uri.parse('$baseUrl/api/push/remover'),
      headers: headers,
      body: jsonEncode({'token': token}),
    );
  }

  // Pede ao servidor um push de teste para os aparelhos desta conta.
  Future<String> testarPush() async {
    final headers = await getHeaders();
    final response = await http.post(Uri.parse('$baseUrl/api/push/teste'), headers: headers);
    try {
      return (jsonDecode(response.body)['message'] ?? 'Sem resposta do servidor.').toString();
    } catch (_) {
      return 'Sem resposta do servidor (código ${response.statusCode}).';
    }
  }
}
