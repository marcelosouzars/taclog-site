// TERMOS_ACEITE_WEB.DART
//
// Termos de Uso e Política de Privacidade (LGPD) no portal web:
//  - TermosAceiteScreen  : tela de aceite que aparece logo depois do login
//                          (uma vez por versão do texto), com as caixas
//                          "Li e aceito".
//  - TermosTextoScreen   : leitura do texto completo (também disponível no
//                          menu do app, a qualquer momento).
//  - garantirAceiteTermos: função usada pelo login — devolve true se a
//                          pessoa já aceitou ou acabou de aceitar.
//
// O texto vem do servidor (GET /api/termos), o mesmo do app e das páginas
// públicas do site, então nunca fica diferente entre app, web e site.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

const Color _corTermos = Color(0xFF5B2FA8);

// ---------------------------------------------------------------------------
// Verifica se a pessoa logada já aceitou a versão vigente; se não, abre a
// tela de aceite. Se o servidor não souber responder (ex.: função ainda não
// instalada), NÃO trava o acesso.
// ---------------------------------------------------------------------------
Future<bool> garantirAceiteTermosWeb(BuildContext context) async {
  Map<String, dynamic> status;
  try {
    status = await ApiService().statusTermos();
  } catch (e) {
    debugPrint('[TERMOS] não foi possível consultar o aceite: $e');
    return true;
  }
  if (status['precisa_aceitar'] != true) return true;
  if (!context.mounted) return false;
  final aceitou = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => TermosAceiteScreen(status: status),
    ),
  );
  return aceitou == true;
}

// ---------------------------------------------------------------------------
// Renderização do texto (negrito com **, listas e tabelas)
// ---------------------------------------------------------------------------
List<InlineSpan> _spansComNegrito(String texto, TextStyle base) {
  final partes = texto.split('**');
  final spans = <InlineSpan>[];
  for (int i = 0; i < partes.length; i++) {
    if (partes[i].isEmpty) continue;
    spans.add(TextSpan(
      text: partes[i],
      style: i.isOdd ? base.copyWith(fontWeight: FontWeight.bold) : base,
    ));
  }
  return spans;
}

Widget _blocoDoTexto(dynamic bruto) {
  final b = Map<String, dynamic>.from(bruto as Map);
  const base = TextStyle(fontSize: 14, height: 1.5, color: Color(0xFF1E293B));
  final tipo = b['tipo'];

  if (tipo == 'lista') {
    final itens = List<dynamic>.from(b['itens'] ?? []);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: itens
            .map((i) => Padding(
                  padding: const EdgeInsets.only(bottom: 4, left: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 7, right: 8),
                        child: Icon(Icons.circle, size: 5, color: _corTermos),
                      ),
                      Expanded(child: Text.rich(TextSpan(children: _spansComNegrito(i.toString(), base)))),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }

  if (tipo == 'tabela') {
    final cab = List<dynamic>.from(b['cabecalho'] ?? []);
    final linhas = List<dynamic>.from(b['linhas'] ?? []);
    final colunas = cab.length;
    Widget celula(String t, {bool cabecalho = false, bool primeira = false}) {
      final estilo = cabecalho
          ? base.copyWith(fontSize: 12.5, fontWeight: FontWeight.w800, color: const Color(0xFF3D1F73))
          : primeira
              ? base.copyWith(fontSize: 13, fontWeight: FontWeight.bold, color: const Color(0xFF3D1F73))
              : base.copyWith(fontSize: 13);
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Text.rich(TextSpan(children: _spansComNegrito(t, estilo))),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Table(
        border: TableBorder.all(color: const Color(0xFFE2E8F0)),
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: [
          TableRow(
            decoration: const BoxDecoration(color: Color(0xFFF1ECFA)),
            children: [for (final c in cab) celula(c.toString(), cabecalho: true)],
          ),
          for (final l in linhas)
            TableRow(
              children: [
                for (int i = 0; i < colunas; i++)
                  celula(
                    i < (l as List).length ? l[i].toString() : '',
                    primeira: i == 0,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text.rich(TextSpan(children: _spansComNegrito((b['texto'] ?? '').toString(), base))),
  );
}

class _TextoDosTermos extends StatelessWidget {
  final Map<String, dynamic> termos;
  const _TextoDosTermos({required this.termos});

  @override
  Widget build(BuildContext context) {
    final secoes = List<dynamic>.from(termos['secoes'] ?? []);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in secoes) ...[
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 8),
            child: Text(
              '${s['numero']}. ${s['titulo']}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF3D1F73)),
            ),
          ),
          ...List<dynamic>.from(s['blocos'] ?? []).map(_blocoDoTexto),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Leitura do texto completo
// ---------------------------------------------------------------------------
class TermosTextoScreen extends StatefulWidget {
  const TermosTextoScreen({super.key});

  @override
  State<TermosTextoScreen> createState() => _TermosTextoScreenState();
}

class _TermosTextoScreenState extends State<TermosTextoScreen> {
  Map<String, dynamic>? _termos;
  String? _erro;
  bool _carregando = true;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    setState(() {
      _carregando = true;
      _erro = null;
    });
    try {
      final t = await ApiService().buscarTermos();
      if (!mounted) return;
      setState(() {
        _termos = t;
        _carregando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = e.toString().replaceAll('Exception: ', '');
        _carregando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Termos e Privacidade'),
        backgroundColor: _corTermos,
        foregroundColor: Colors.white,
      ),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : _erro != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_erro!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        ElevatedButton(onPressed: _carregar, child: const Text('Tentar de novo')),
                      ],
                    ),
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 860),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Versão ${_termos!['versao']} · atualizada em ${_termos!['atualizado_em']}',
                            style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
                          ),
                          _TextoDosTermos(termos: _termos!),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tela de aceite
// ---------------------------------------------------------------------------
class TermosAceiteScreen extends StatefulWidget {
  final Map<String, dynamic> status;
  const TermosAceiteScreen({super.key, required this.status});

  @override
  State<TermosAceiteScreen> createState() => _TermosAceiteScreenState();
}

class _TermosAceiteScreenState extends State<TermosAceiteScreen> {
  final ApiService _api = ApiService();
  bool _aceitouTermos = false;
  bool _aceitouLocalizacao = false;
  bool _aceitouComunicacoes = false;
  bool _declarouPoderes = false;
  bool _salvando = false;
  String? _erro;

  bool get _exigeLocalizacao => widget.status['exige_localizacao'] == true;
  bool get _exigePoderes => widget.status['exige_poderes'] == true;

  bool get _podeContinuar =>
      _aceitouTermos && (!_exigeLocalizacao || _aceitouLocalizacao) && (!_exigePoderes || _declarouPoderes) && !_salvando;

  Future<void> _aceitar() async {
    setState(() {
      _salvando = true;
      _erro = null;
    });
    try {
      await _api.aceitarTermos(
        versao: widget.status['versao'].toString(),
        aceitouLocalizacao: _aceitouLocalizacao,
        aceitouComunicacoes: _aceitouComunicacoes,
        declarouPoderes: _declarouPoderes,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = e.toString().replaceAll('Exception: ', '');
        _salvando = false;
      });
    }
  }

  Future<void> _naoAceito() async {
    final sair = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sair sem aceitar?'),
        content: const Text('Sem aceitar os Termos de Uso e a Política de Privacidade não é possível usar o TACLOG. Você poderá entrar de novo quando quiser.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Voltar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sair')),
        ],
      ),
    );
    if (sair != true) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('jwt_token');
      await prefs.remove('role');
      await prefs.remove('nome');
      await prefs.remove('user_id');
      await prefs.remove('is_transportadora');
    } catch (_) {}
    if (!mounted) return;
    Navigator.pop(context, false);
  }

  Widget _caixa({required bool valor, required ValueChanged<bool> aoMudar, required String texto, bool obrigatoria = true}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: valor ? _corTermos : const Color(0xFFE2E8F0), width: valor ? 1.5 : 1),
      ),
      child: CheckboxListTile(
        value: valor,
        onChanged: _salvando ? null : (v) => aoMudar(v == true),
        controlAffinity: ListTileControlAffinity.leading,
        activeColor: _corTermos,
        dense: true,
        title: Text(
          obrigatoria ? texto : '$texto (opcional)',
          style: const TextStyle(fontSize: 13.5, height: 1.4),
        ),
      ),
    );
  }

  Widget _destaque(IconData icone, String texto) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icone, size: 18, color: _corTermos),
          const SizedBox(width: 10),
          Expanded(child: Text(texto, style: const TextStyle(fontSize: 13.5, height: 1.4))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final versao = widget.status['versao'].toString();
    return WillPopScope(
      onWillPop: () async => false, // só sai aceitando ou escolhendo "Não aceito"
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        appBar: AppBar(
          title: const Text('Termos e Privacidade'),
          backgroundColor: _corTermos,
          foregroundColor: Colors.white,
          automaticallyImplyLeading: false,
        ),
        body: Center(
         child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    const Icon(Icons.verified_user_outlined, size: 44, color: _corTermos),
                    const SizedBox(height: 8),
                    const Text(
                      'Antes de começar',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF3D1F73)),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Para usar o portal TACLOG é preciso ler e aceitar os Termos de Uso e a Política de Privacidade (versão $versao).',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: Color(0xFF475569)),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1ECFA),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('O mais importante', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF3D1F73))),
                          const SizedBox(height: 8),
                          _destaque(Icons.person_outline, 'Sua conta é pessoal e intransferível. Não empreste login nem senha.'),
                          _destaque(Icons.phonelink_erase_outlined, 'Se alguém acessar sua conta sem autorização, ou se você perder um aparelho em que ela esteja aberta, avise a TACLOG imediatamente.'),
                          _destaque(Icons.lock_outline, 'Seus dados são usados somente pela Vetix/TACLOG e pelas empresas envolvidas nas suas cargas.'),
                          if (_exigeLocalizacao)
                            _destaque(Icons.location_on_outlined, 'Sua localização é usada para ofertas e para acompanhar as coletas.'),
                          _destaque(Icons.local_shipping_outlined, 'A TACLOG é uma plataforma de tecnologia: não é transportadora nem empregadora.'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TermosTextoScreen())),
                        icon: const Icon(Icons.article_outlined),
                        label: const Text('Ler o texto completo'),
                        style: TextButton.styleFrom(foregroundColor: _corTermos),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _caixa(
                      valor: _aceitouTermos,
                      aoMudar: (v) => setState(() => _aceitouTermos = v),
                      texto:
                          'Li e concordo com os Termos de Uso e a Política de Privacidade da TACLOG. Declaro que sou o titular desta conta, que as informações que forneci são verdadeiras, que usarei o aplicativo de forma pessoal e intransferível e que avisarei a TACLOG imediatamente se perder o aparelho, se ele for furtado ou roubado, ou se a minha conta for acessada por outra pessoa.',
                    ),
                    if (_exigeLocalizacao)
                      _caixa(
                        valor: _aceitouLocalizacao,
                        aoMudar: (v) => setState(() => _aceitouLocalizacao = v),
                        texto:
                            'Autorizo a TACLOG a coletar e usar a minha localização para enviar ofertas, acompanhar coletas e mostrá-la à Transportadora e ao Embarcador responsável, conforme a cláusula 12, e que as etapas da entrega, sem minha identificação, sejam informadas ao Destinatário da carga.',
                      ),
                    if (_exigePoderes)
                      _caixa(
                        valor: _declarouPoderes,
                        aoMudar: (v) => setState(() => _declarouPoderes = v),
                        texto:
                            'Declaro que tenho poderes para representar a empresa, que os dados de funcionários que cadastrarei são tratados com base legal e que os funcionários foram informados sobre o tratamento, inclusive da localização.',
                      ),
                    _caixa(
                      valor: _aceitouComunicacoes,
                      aoMudar: (v) => setState(() => _aceitouComunicacoes = v),
                      texto: 'Aceito receber comunicações e anúncios de parceiros da TACLOG.',
                      obrigatoria: false,
                    ),
                    if (_erro != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(_erro!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _podeContinuar ? _aceitar : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _corTermos,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: _salvando
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                            : const Text('ACEITAR E CONTINUAR', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                      ),
                    ),
                    TextButton(
                      onPressed: _salvando ? null : _naoAceito,
                      child: const Text('Não aceito (sair)', style: TextStyle(color: Color(0xFF64748B))),
                    ),
                  ],
                ),
              ),
            ],
          ),
         ),
        ),
      ),
    );
  }
}
