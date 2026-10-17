//
// API_SERVICE.DART (WEB EMBARCADOR)
//
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// Lançada quando o login falha especificamente porque o e-mail do
// embarcador ainda não foi verificado. Carrega o e-mail para a tela de
// login poder mandar direto para a tela de verificação, sem o usuário
// precisar redigitar nada.
class EmailNaoVerificadoException implements Exception {
  final String email;
  EmailNaoVerificadoException(this.email);
}

// Lançada quando quem tenta logar é um funcionário da transportadora cujo
// acesso está INATIVO ou SUSPENSO (o administrador desativou o cadastro,
// ou marcou como "de férias"). Carrega a mensagem específica que o
// backend já manda pronta pra exibir.
class FuncionarioInativoException implements Exception {
  final String mensagem;
  FuncionarioInativoException(this.mensagem);
}

class ApiService {
  // Mantemos a URL oficial do nosso núcleo no Render
  static const String baseUrl = 'https://taclog-backend.onrender.com';

  // ==========================================
  // 1. UTILITÁRIOS E CABEÇALHOS
  // ==========================================
  Future<Map<String, String>> getHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    String? token = prefs.getString('jwt_token');
    return {
      "Content-Type": "application/json",
      if (token != null) "Authorization": "Bearer $token"
    };
  }

  // ==========================================
  // 2. AUTENTICAÇÃO — LOGIN ÚNICO (EMBARCADOR OU MOTORISTA TAC)
  // O backend usa a mesma rota /api/login para os dois perfis: ele
  // procura primeiro em `motoristas` (por CPF) e, se não achar, em
  // `embarcadores` (por usuário/CNPJ). A resposta traz `role`
  // ('motorista' ou 'embarcador'), que a tela de login usa para decidir
  // pra qual dashboard mandar a pessoa.
  // ==========================================
  Future<Map<String, dynamic>> loginEmbarcador(String loginUser, String senha) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/login'),
      headers: {"Content-Type": "application/json"},
      // NOVO: "origem" identifica pro Log do Sistema que este login veio
      // da web — tanto o dashboard do embarcador quanto o painel web do
      // motorista TAC autônomo passam por aqui.
      body: jsonEncode({"usuario": loginUser.trim(), "senha": senha.trim(), "origem": "WEB"}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('jwt_token', data['token']);
      await prefs.setString('role', data['role'] ?? 'embarcador');
      await prefs.setString('nome', data['nome'] ?? '');
      await prefs.setInt('user_id', data['motorista_id'] ?? 0);
      // Guarda se o embarcador é transportadora, para o dashboard decidir
      // se mostra os menus "Frota" e "Configurações" no sidebar.
      await prefs.setBool('is_transportadora', data['is_transportadora'] ?? false);
      await prefs.setString('logo_url', data['logo_url'] ?? '');
      // NOVO: perfil de acesso (ADMIN/OPERADOR) — o titular sempre vem
      // como ADMIN; um funcionário vem com o perfil que o administrador
      // atribuiu a ele. Usado pra esconder ações de excluir e a tela de
      // Log do Sistema de quem é OPERADOR.
      await prefs.setString('perfil', data['perfil'] ?? 'OPERADOR');
      // NOVO: quando quem logou é um funcionário (e não o titular direto
      // com CNPJ), o backend manda o nome dele à parte — usamos pra
      // mostrar "Olá, <nome do funcionário>" em vez de só o nome da
      // empresa, e pra saber se deve esconder a tela de "Funcionários"
      // (só o titular pode gerenciar). Vem vazio/ausente pro login do
      // titular.
      await prefs.setString('funcionario_nome', data['funcionario_nome'] ?? '');
      // NOVO: senha provisória — se true, a tela de login manda a pessoa
      // direto pra tela de trocar senha antes de qualquer outra coisa.
      await prefs.setBool('senha_provisoria', data['senha_provisoria'] ?? false);
      return data;
    } else {
      String msgErro = 'Erro no login. Verifique seus dados.';
      try {
        final erroJson = jsonDecode(response.body);
        // Caso especial: login e senha corretos, mas o e-mail ainda não foi
        // confirmado. O backend devolve 403 com error='EMAIL_NAO_VERIFICADO'.
        if (erroJson['error'] == 'EMAIL_NAO_VERIFICADO') {
          throw EmailNaoVerificadoException(erroJson['email'] ?? loginUser.trim());
        }
        // Caso especial: funcionário com acesso INATIVO ou SUSPENSO.
        if (erroJson['error'] == 'FUNCIONARIO_INATIVO') {
          throw FuncionarioInativoException(erroJson['message'] ?? 'Seu acesso não está mais ativo.');
        }
        msgErro = erroJson['message'] ?? erroJson['error'] ?? msgErro;
      } on EmailNaoVerificadoException {
        rethrow;
      } on FuncionarioInativoException {
        rethrow;
      } catch (e) {
        msgErro = 'Erro no servidor (Status: ${response.statusCode})';
      }
      throw Exception(msgErro);
    }
  }

  // Chamada logo após o login quando `senha_provisoria` vem true — troca a
  // senha temporária que o administrador gerou por uma definitiva. O
  // backend devolve um token NOVO (sem a marca de senha provisória), que
  // precisa substituir o token antigo salvo localmente, senão a pessoa
  // fica travada pra sempre nesta mesma tela.
  Future<void> trocarSenhaFuncionario(String novaSenha, String confirmarSenha) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/funcionario/trocar-senha'),
      headers: headers,
      body: jsonEncode({"nova_senha": novaSenha, "confirmar_senha": confirmarSenha}),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('jwt_token', data['token']);
      await prefs.setBool('senha_provisoria', false);
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao trocar a senha.');
    }
  }

  // ==========================================
  // TERMOS DE USO E POLÍTICA DE PRIVACIDADE (LGPD)
  // O texto vem do servidor (o mesmo do app e das páginas públicas do site).
  // ==========================================
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

  // Registra o aceite (data, versão, IP e navegador ficam gravados no servidor).
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
        'origem': 'WEB',
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

  // Nome do funcionário logado (vazio se quem logou foi o titular direto
  // com CNPJ) — usado pra saudação e pra esconder a gestão de funcionários.
  Future<String> getFuncionarioNome() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('funcionario_nome') ?? '';
  }

  Future<bool> getSenhaProvisoria() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('senha_provisoria') ?? false;
  }

  // NOVO: o próprio motorista TAC autônomo desativando a conta dele —
  // ver tela de confirmação em 3 passos. Depois de chamar isso com
  // sucesso, quem chamou é responsável por limpar o SharedPreferences e
  // levar de volta pro login (a conta já não serve mais pra nada).
  Future<void> desativarContaMotorista() async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/motorista/desativar-conta'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao desativar a conta.');
    }
  }

  // ==========================================
  // 2b. GESTÃO DE FUNCIONÁRIOS DA TRANSPORTADORA (só o titular acessa)
  // ==========================================
  Future<List<dynamic>> listarFuncionarios() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/embarcador/funcionarios'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao buscar funcionários.');
    }
  }

  // Retorna o Map completo devolvido pelo backend, que inclui
  // `senha_provisoria_texto` — a ÚNICA vez que a senha em texto puro fica
  // disponível; a tela precisa mostrar isso uma vez só, num diálogo, e
  // avisar pra copiar/repassar, porque não vai aparecer de novo.
  // NOVO: "perfil" — 'ADMIN' (mesmo poder operacional do titular) ou
  // 'OPERADOR' (não exclui motorista/caminhão/carreta, nem cancela carga
  // já finalizada). Fica 'OPERADOR' se não for informado.
  // NOVO: "recebeAvisosApp" — marca a pessoa como GESTORA: ela entra no app
  // do celular com o próprio CPF e recebe uma cópia de todos os avisos de
  // coleta (e alertas, como "falta caminhão").
  Future<Map<String, dynamic>> criarFuncionario({required String nome, required String cpf, String? email, String perfil = 'OPERADOR', bool recebeAvisosApp = false}) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/embarcador/funcionarios'),
      headers: headers,
      body: jsonEncode({"nome": nome, "cpf": cpf, "email": email, "perfil": perfil, "recebe_avisos_app": recebeAvisosApp}),
    );
    if (response.statusCode == 201) {
      return jsonDecode(response.body);
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao cadastrar funcionário.');
    }
  }

  Future<void> editarFuncionario(int id, {String? nome, String? email, String? status, String? perfil, bool? recebeAvisosApp}) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/embarcador/funcionarios/$id'),
      headers: headers,
      body: jsonEncode({"nome": nome, "email": email, "status": status, "perfil": perfil, "recebe_avisos_app": recebeAvisosApp}),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao atualizar funcionário.');
    }
  }

  // Gera e devolve uma nova senha provisória (também só aparece uma vez).
  Future<String> resetarSenhaFuncionario(int id) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/embarcador/funcionarios/$id/resetar-senha'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body)['senha_provisoria_texto'] ?? '';
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao resetar senha.');
    }
  }

  // ==========================================
  // NOVO: LOG DO SISTEMA — por enquanto só os logins (quem, quando, de
  // onde). Só quem é ADMIN enxerga essa tela.
  // ==========================================
  Future<List<dynamic>> buscarLogsAtividade() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/embarcador/logs-atividade'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao buscar o log do sistema.');
    }
  }

  // Consulta local (SharedPreferences) se o embarcador logado é uma
  // transportadora com frota própria. Usado pelo dashboard para decidir
  // se exibe os itens de menu "Frota" e "Configurações".
  Future<bool> isTransportadora() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('is_transportadora') ?? false;
  }

  // Retorna 'motorista' ou 'embarcador' — usado pela tela de login para
  // decidir para qual dashboard navegar após autenticar.
  Future<String> getRole() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('role') ?? 'embarcador';
  }

  Future<String> getNome() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('nome') ?? '';
  }

  Future<String> getLogoUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('logo_url') ?? '';
  }

  // NOVO: 'ADMIN' ou 'OPERADOR' — usado pelas telas pra esconder botões de
  // excluir e o item de menu "Log do Sistema" de quem é OPERADOR. A
  // segurança de verdade é sempre no backend; isso aqui é só pra não
  // mostrar uma ação que o servidor vai recusar de qualquer jeito.
  Future<String> getPerfil() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('perfil') ?? 'OPERADOR';
  }

  Future<bool> isAdmin() async {
    return (await getPerfil()) == 'ADMIN';
  }

  // ==========================================
  // 3. GESTÃO DE CARGAS E FINANCEIRO
  // ==========================================
  Future<List<dynamic>> buscarCargas() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/cargas/listar'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar as cargas.');
    }
  }

  Future<void> criarCarga(Map<String, dynamic> cargaData) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/cargas/nova'),
      headers: headers,
      body: jsonEncode(cargaData),
    );
    if (response.statusCode != 201) throw Exception('Erro ao criar carga');
  }

  Future<void> cancelarAceiteMotorista(int idCarga) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/cargas/cancelar-aceite'),
      headers: headers,
      body: jsonEncode({"id": idCarga}),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao cancelar aceite do motorista.');
    }
  }

  Future<void> deletarCarga(int idCarga) async {
    final headers = await getHeaders();
    final response = await http.delete(
      Uri.parse('$baseUrl/api/cargas/$idCarga'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao deletar a carga.');
    }
  }

  // NOVO: troca só data/hora/antecedência de uma carga do Mercado — usa a
  // rota enxuta de reagendar, que não mexe em mais nenhum outro campo.
  Future<void> reagendarCarga(int idCarga, Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/cargas/$idCarga/reagendar'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao reagendar a carga.');
    }
  }

  Future<Map<String, dynamic>> buscarResumo() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/financeiro/resumo'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      return {"pagar": 0.0, "aberto": 0.0};
    }
  }

  // ==========================================
  // 4. MOTORISTAS E MAPA (FUNÇÃO RESTAURADA)
  // ==========================================
  Future<Map<String, dynamic>> buscarMotoristasAtivos() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/motoristas/ativos'), headers: headers);

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      // Retorno seguro padrão caso a tabela esteja vazia ou a rota falhe
      return {"total": 0, "motoristas": []};
    }
  }

  // NOVO: mapa ao vivo só da frota da transportadora logada (com
  // vermelho/verde de ocupado/livre) — diferente do buscarMotoristasAtivos
  // acima, que é global.
  Future<List<dynamic>> buscarMapaAoVivoFrota() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/embarcador/frota/mapa-ao-vivo'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao buscar mapa da frota.');
    }
  }

  // ==========================================
  // 5. FROTA PRÓPRIA — EMBARCADOR TRANSPORTADORA (CAMINHÕES)
  // ==========================================
  Future<List<dynamic>> buscarFrota() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/embarcador/frota'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar a frota.');
    }
  }

  Future<void> cadastrarCaminhaoFrota(Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/embarcador/frota/cadastro'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 201) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao cadastrar caminhão.');
    }
  }

  Future<void> editarCaminhaoFrota(int id, Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/embarcador/frota/$id'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao atualizar caminhão.');
    }
  }

  Future<void> excluirCaminhaoFrota(int id) async {
    final headers = await getHeaders();
    final response = await http.delete(
      Uri.parse('$baseUrl/api/embarcador/frota/$id'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao excluir caminhão.');
    }
  }

  // NOVO: transportadora atribui (motoristaId != null) ou desatribui
  // (motoristaId == null) um motorista FUNCIONÁRIO a um caminhão da frota.
  Future<void> atribuirMotoristaCaminhao(int caminhaoId, int? motoristaId) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/embarcador/frota/$caminhaoId/atribuir-motorista'),
      headers: headers,
      body: jsonEncode({"motorista_id": motoristaId}),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao atribuir motorista.');
    }
  }

  // ==========================================
  // 5C. FROTA PRÓPRIA — MOTORISTAS FUNCIONÁRIOS
  // Cadastrados diretamente pela transportadora — nascem vinculados
  // (vinculo='FUNCIONARIO'), sem verificação de e-mail. Cargas dessa
  // mesma transportadora são designadas direto pra eles, sem etapa de
  // Aceitar/Recusar.
  // ==========================================
  Future<List<dynamic>> buscarMotoristasFuncionarios() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/embarcador/motoristas'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar motoristas.');
    }
  }

  Future<void> cadastrarMotoristaFuncionario(Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/embarcador/motoristas/cadastrar'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 201) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao cadastrar motorista.');
    }
  }

  // NOVO: editar dados (nome, telefone, e-mail, endereço) de um
  // motorista funcionário já cadastrado.
  Future<void> editarMotoristaFuncionario(int id, Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/embarcador/motoristas/$id'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao editar motorista.');
    }
  }

  Future<void> removerMotoristaFuncionario(int id) async {
    final headers = await getHeaders();
    final response = await http.delete(
      Uri.parse('$baseUrl/api/embarcador/motoristas/$id'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao remover motorista.');
    }
  }

  // ==========================================
  // 5B. FROTA PRÓPRIA — CARRETAS (CADASTRO V2)
  // ==========================================
  Future<List<dynamic>> buscarFrotaCarretas() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/embarcador/frota/carretas'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar as carretas da frota.');
    }
  }

  Future<void> cadastrarCarretaFrota(Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/embarcador/frota/carreta/cadastro'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 201) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao cadastrar carreta.');
    }
  }

  Future<void> editarCarretaFrota(int id, Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/embarcador/frota/carreta/$id'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao atualizar carreta.');
    }
  }

  Future<void> excluirCarretaFrota(int id) async {
    final headers = await getHeaders();
    final response = await http.delete(
      Uri.parse('$baseUrl/api/embarcador/frota/carreta/$id'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao excluir carreta.');
    }
  }

  // ==========================================
  // 6. CAMINHÕES E CARRETAS PRÓPRIOS — MOTORISTA TAC NA WEB
  // Mesmas rotas usadas pelo app mobile do motorista; aqui é só a versão
  // web do mesmo fluxo (até 3 caminhões próprios, carretas próprias,
  // acoplamento). Reaproveita getHeaders() com o token do TAC logado.
  // ==========================================
  Future<List<dynamic>> buscarMeusCaminhoes() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/motorista/meus-caminhoes'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar seus caminhões.');
    }
  }

  Future<void> cadastrarCaminhao(Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/caminhao/cadastro'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 201) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao cadastrar caminhão.');
    }
  }

  Future<void> atualizarCaminhao(int id, Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/caminhao/$id'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao atualizar caminhão.');
    }
  }

  Future<List<dynamic>> buscarMinhasCarretas() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/motorista/minhas-carretas'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar suas carretas.');
    }
  }

  Future<void> cadastrarCarreta(Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/carreta/cadastro'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 201) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao cadastrar carreta.');
    }
  }

  Future<void> atualizarCarreta(int id, Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/carreta/$id'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao atualizar carreta.');
    }
  }

  Future<void> excluirCarreta(int id) async {
    final headers = await getHeaders();
    final response = await http.delete(
      Uri.parse('$baseUrl/api/carreta/$id'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao excluir carreta.');
    }
  }

  // ==========================================
  // 7. ACOPLAMENTO CAMINHÃO + CARRETA (CADASTRO V2)
  // Vale tanto para o TAC autônomo quanto para a transportadora
  // acoplando um caminhão e uma carreta da própria frota.
  // ==========================================
  Future<void> acoplarCarreta(int caminhaoId, int carretaId) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/motorista/acoplar-carreta'),
      headers: headers,
      body: jsonEncode({"caminhao_id": caminhaoId, "carreta_id": carretaId}),
    );
    if (response.statusCode != 201) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao acoplar carreta.');
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
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao desacoplar carreta.');
    }
  }

  Future<Map<String, dynamic>?> buscarAcoplamentoAtivo(int caminhaoId) async {
    final headers = await getHeaders();
    final response = await http.get(
      Uri.parse('$baseUrl/api/caminhao/$caminhaoId/acoplamento-ativo'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data == null ? null : Map<String, dynamic>.from(data);
    } else {
      throw Exception('Erro ao buscar acoplamento ativo.');
    }
  }

  // NOVO: histórico completo de acoplamentos/desacoplamentos de um
  // caminhão — quem acoplou, quando começou e quando terminou cada
  // vínculo com uma carreta.
  Future<List<dynamic>> buscarHistoricoAcoplamentos(int caminhaoId) async {
    final headers = await getHeaders();
    final response = await http.get(
      Uri.parse('$baseUrl/api/caminhao/$caminhaoId/historico-acoplamentos'),
      headers: headers,
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar histórico de acoplamentos.');
    }
  }

  // ==========================================
  // 8. CONFIGURAÇÕES — EMBARCADOR TRANSPORTADORA
  // ==========================================
  Future<double> buscarDistanciaMaximaFrota() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/embarcador/configuracoes'), headers: headers);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final valor = data['distancia_maxima_frota_km'];
      return valor == null ? 0.0 : double.tryParse(valor.toString()) ?? 0.0;
    } else {
      throw Exception('Erro ao buscar configurações.');
    }
  }

  Future<void> salvarDistanciaMaximaFrota(double distanciaKm) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/embarcador/configuracoes'),
      headers: headers,
      body: jsonEncode({"distancia_maxima_frota_km": distanciaKm}),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao salvar configurações.');
    }
  }

  // ==========================================
  // 9. NOTIFICAÇÕES DO EMBARCADOR (ícone de sino)
  // ==========================================
  Future<List<dynamic>> buscarNotificacoes() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/embarcador/notificacoes'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar notificações.');
    }
  }

  Future<int> contarNotificacoesNaoLidas() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/embarcador/notificacoes/contagem'), headers: headers);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['total_nao_lidas'] ?? 0;
    } else {
      return 0;
    }
  }

  Future<void> marcarNotificacaoLida(int id) async {
    final headers = await getHeaders();
    final response = await http.put(Uri.parse('$baseUrl/api/embarcador/notificacoes/$id/marcar-lida'), headers: headers);
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao marcar notificação como lida.');
    }
  }

  Future<void> marcarTodasNotificacoesLidas() async {
    final headers = await getHeaders();
    final response = await http.put(Uri.parse('$baseUrl/api/embarcador/notificacoes/marcar-todas-lidas'), headers: headers);
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao marcar notificações como lidas.');
    }
  }

  // ==========================================
  // 10. CLIENTES DA TRANSPORTADORA (remetente/destinatário reutilizável)
  // ==========================================
  Future<List<dynamic>> buscarClientes({String? busca}) async {
    final headers = await getHeaders();
    final uri = Uri.parse('$baseUrl/api/transportadora/clientes').replace(
      queryParameters: (busca != null && busca.trim().isNotEmpty) ? {'busca': busca.trim()} : null,
    );
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar clientes.');
    }
  }

  // NOVO: busca de clientes PAGINADA e filtrada no servidor (tela de
  // Clientes). Devolve { itens, total, pagina, limite, total_paginas } com
  // só uma página de clientes por vez - assim a tela continua rápida mesmo
  // com dezenas de milhares de cadastros. As datas vão como "AAAA-MM-DD".
  Future<Map<String, dynamic>> buscarClientesPaginado({
    String? busca,
    String? cidade,
    String? uf,
    String? operacaoDe,
    String? operacaoAte,
    int pagina = 1,
    int limite = 50,
  }) async {
    final headers = await getHeaders();
    final parametros = <String, String>{
      'pagina': pagina.toString(),
      'limite': limite.toString(),
      if (busca != null && busca.trim().isNotEmpty) 'busca': busca.trim(),
      if (cidade != null && cidade.trim().isNotEmpty) 'cidade': cidade.trim(),
      if (uf != null && uf.trim().isNotEmpty) 'uf': uf.trim(),
      if (operacaoDe != null && operacaoDe.isNotEmpty) 'operacao_de': operacaoDe,
      if (operacaoAte != null && operacaoAte.isNotEmpty) 'operacao_ate': operacaoAte,
    };
    final uri = Uri.parse('$baseUrl/api/transportadora/clientes').replace(queryParameters: parametros);
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      return Map<String, dynamic>.from(jsonDecode(response.body));
    } else {
      throw Exception('Erro ao buscar clientes.');
    }
  }

  // NOVO: agora devolve o cliente recém-criado (com o "id" que o banco
  // gerou) — precisamos dele pra já deixar o cliente "selecionado" na
  // hora, sem precisar recarregar a lista inteira. Quem já chamava esse
  // método sem usar o retorno continua funcionando normalmente.
  Future<Map<String, dynamic>> cadastrarCliente(Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/transportadora/clientes'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 201) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao cadastrar cliente.');
    }
    return jsonDecode(response.body);
  }

  Future<void> editarCliente(int id, Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/transportadora/clientes/$id'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao atualizar cliente.');
    }
  }

  Future<void> excluirCliente(int id) async {
    final headers = await getHeaders();
    final response = await http.delete(Uri.parse('$baseUrl/api/transportadora/clientes/$id'), headers: headers);
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao excluir cliente.');
    }
  }

  // ==========================================
  // 11. COLETAS DA FROTA PRÓPRIA
  // ==========================================
  Future<List<dynamic>> buscarColetas({String? dataInicio, String? dataFim, String? status, int? caminhaoId}) async {
    final headers = await getHeaders();
    final Map<String, String> params = {};
    if (dataInicio != null) params['data_inicio'] = dataInicio;
    if (dataFim != null) params['data_fim'] = dataFim;
    if (status != null) params['status'] = status;
    if (caminhaoId != null) params['caminhao_id'] = caminhaoId.toString();
    final uri = Uri.parse('$baseUrl/api/transportadora/coletas').replace(queryParameters: params.isEmpty ? null : params);
    final response = await http.get(uri, headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar coletas.');
    }
  }

  Future<void> cadastrarColeta(Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/transportadora/coletas'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 201) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao cadastrar coleta.');
    }
  }

  Future<void> editarColeta(int id, Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/transportadora/coletas/$id'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao atualizar coleta.');
    }
  }

  Future<void> mudarStatusColeta(int id, String status) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/transportadora/coletas/$id/status'),
      headers: headers,
      body: jsonEncode({"status": status}),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao atualizar status da coleta.');
    }
  }

  Future<void> cancelarColeta(int id) async {
    final headers = await getHeaders();
    final response = await http.delete(Uri.parse('$baseUrl/api/transportadora/coletas/$id'), headers: headers);
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao cancelar coleta.');
    }
  }

  // NOVO: busca a última posição conhecida do motorista/caminhão
  // designado para esta coleta — reaproveita a mesma tabela de
  // localização já usada em "Motoristas Online e Livres".
  Future<Map<String, dynamic>> buscarLocalizacaoColeta(int coletaId) async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/transportadora/coletas/$coletaId/localizacao'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Localização não disponível.');
    }
  }

  // ==========================================
  // 12. PERFIL DO EMBARCADOR (consultar/editar cadastro, CNPJ é fixo)
  // ==========================================
  Future<Map<String, dynamic>> buscarPerfilEmbarcador() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/embarcador/perfil'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao buscar perfil.');
    }
  }

  Future<void> atualizarPerfilEmbarcador(Map<String, dynamic> dados) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/embarcador/perfil'),
      headers: headers,
      body: jsonEncode(dados),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao atualizar perfil.');
    }
  }

  // Envia os bytes da imagem (funciona tanto no Web quanto no mobile,
  // já que não depende de dart:io File — só de bytes em memória).
  Future<String> enviarLogoEmpresa(List<int> bytes, String nomeArquivo) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');

    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/embarcador/logo'));
    request.headers['Authorization'] = 'Bearer $token';
    request.files.add(http.MultipartFile.fromBytes('logo', bytes, filename: nomeArquivo));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final novoLogoUrl = data['logo_url'] ?? '';
      await prefs.setString('logo_url', novoLogoUrl);
      return novoLogoUrl;
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao enviar o logo.');
    }
  }

  // ==========================================
  // 13. OFERTAS DO MERCADO PARA A FROTA (mercado aberto → aprovação da
  // transportadora antes de chegar no motorista funcionário)
  // ==========================================

  // Lê se esta transportadora deixa os caminhões ociosos da frota
  // concorrerem também no mercado aberto (cargas de outros embarcadores).
  Future<bool> buscarPermiteOfertasMercado() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/embarcador/configuracoes'), headers: headers);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['permite_ofertas_mercado_frota'] == true;
    } else {
      throw Exception('Erro ao buscar configurações.');
    }
  }

  Future<void> salvarPermiteOfertasMercado(bool valor) async {
    final headers = await getHeaders();
    final response = await http.put(
      Uri.parse('$baseUrl/api/embarcador/configuracoes'),
      headers: headers,
      body: jsonEncode({"permite_ofertas_mercado_frota": valor}),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao salvar configurações.');
    }
  }

  // Lista as ofertas do mercado aberto que o sistema já pré-selecionou
  // para caminhões desta frota e que estão aguardando a transportadora
  // aprovar ou recusar (o motorista ainda não sabe dessas).
  Future<List<dynamic>> buscarOfertasMercadoFrota() async {
    final headers = await getHeaders();
    final response = await http.get(Uri.parse('$baseUrl/api/transportadora/ofertas-mercado'), headers: headers);
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('Erro ao buscar ofertas do mercado.');
    }
  }

  // aceitou = true  → a oferta é enviada pro motorista (fluxo normal de
  //                   Aceitar/Recusar, como já funciona hoje).
  // aceitou = false → a oferta é recusada e liberada pro próximo
  //                   candidato do mercado; o motorista nunca fica
  //                   sabendo que ela existiu.
  Future<void> responderOfertaMercado(int ofertaId, bool aceitou) async {
    final headers = await getHeaders();
    final response = await http.post(
      Uri.parse('$baseUrl/api/transportadora/ofertas-mercado/$ofertaId/responder'),
      headers: headers,
      body: jsonEncode({"aceitou": aceitou}),
    );
    if (response.statusCode != 200) {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Erro ao responder oferta.');
    }
  }

  // ==========================================
  // TIPOS DE VEÍCULO / CARROCERIA (nomenclatura de mercado)
  // Retorno: [{ grupo: 'PESADO', itens: [{codigo, nome}, ...] }, ...]
  // ==========================================
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
}
