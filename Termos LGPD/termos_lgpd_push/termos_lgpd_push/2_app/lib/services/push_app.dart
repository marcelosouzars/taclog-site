// PUSH_APP.DART
//
// Notificações push (Firebase Cloud Messaging) no aplicativo Android:
// o aviso de carga chega no celular mesmo com a tela bloqueada e o app
// fechado. O servidor (push_fcm.js) manda; este arquivo:
//   - prepara o Firebase quando o app abre            -> PushApp.iniciar()
//   - pede a permissão e cadastra o aparelho no servidor
//                                                      -> PushApp.registrar()
//   - descadastra o aparelho quando a pessoa sai       -> PushApp.desregistrar()
//   - botão "Testar notificação"                       -> PushApp.testar()
//
// Tudo aqui é "à prova de falha": se o Firebase não estiver configurado, ou
// se rodar no navegador (PWA do iPhone), o app continua funcionando normal,
// só sem push.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service_app.dart';

// Mensagens que chegam com o app fechado: o próprio Android já mostra a
// notificação (o servidor manda título e texto), então aqui não precisa
// fazer nada. A função existe porque o Firebase exige um tratador registrado.
@pragma('vm:entry-point')
Future<void> _tratadorSegundoPlano(RemoteMessage mensagem) async {}

class PushApp {
  PushApp._();

  // Mesmo nome de canal que o servidor usa (android.notification.channel_id).
  static const String _canalId = 'taclog_avisos';

  static bool _firebaseOk = false;
  static bool _escutandoRenovacao = false;

  static bool get _suportado => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  // Chamar no main(), depois de WidgetsFlutterBinding.ensureInitialized().
  static Future<void> iniciar() async {
    if (!_suportado) return;
    try {
      await Firebase.initializeApp(); // lê o google-services.json do Android
      _firebaseOk = true;
      FirebaseMessaging.onBackgroundMessage(_tratadorSegundoPlano);
      await _criarCanal();
    } catch (e) {
      _firebaseOk = false;
      debugPrint('[PUSH] Firebase não iniciou (push desligado): $e');
    }
  }

  // Canal de importância ALTA: faz a notificação aparecer na tela, com som,
  // mesmo com o celular bloqueado.
  static Future<void> _criarCanal() async {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _canalId,
      'Avisos TACLOG',
      description: 'Avisos de carga, coleta e entrega',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    ));
  }

  // Chamar quando a pessoa estiver logada (entrada nos dashboards).
  static Future<void> registrar() async {
    if (!_suportado || !_firebaseOk) return;
    try {
      final fcm = FirebaseMessaging.instance;
      final permissao = await fcm.requestPermission(alert: true, badge: true, sound: true);
      if (permissao.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('[PUSH] permissão de notificação negada pelo usuário.');
        return;
      }
      final token = await fcm.getToken();
      if (token != null && token.isNotEmpty) await _enviarAoServidor(token);

      // O Firebase às vezes troca o endereço do aparelho: cadastra de novo.
      if (!_escutandoRenovacao) {
        _escutandoRenovacao = true;
        fcm.onTokenRefresh.listen((novo) async {
          final prefs = await SharedPreferences.getInstance();
          if ((prefs.getString('jwt_token') ?? '').isNotEmpty) await _enviarAoServidor(novo);
        });
      }
    } catch (e) {
      debugPrint('[PUSH] falha ao registrar o aparelho: $e');
    }
  }

  static Future<void> _enviarAoServidor(String token) async {
    await ApiService().registrarAparelhoPush(token, 'android');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('push_token', token);
  }

  // Chamar ANTES de apagar o jwt_token no logout (o servidor precisa do login
  // para saber de quem é o aparelho). Assim o celular deixa de receber avisos
  // da conta de quem saiu.
  static Future<void> desregistrar() async {
    if (!_suportado) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('push_token');
      if (token != null && token.isNotEmpty) {
        await ApiService().removerAparelhoPush(token);
        await prefs.remove('push_token');
      }
    } catch (e) {
      debugPrint('[PUSH] falha ao descadastrar o aparelho: $e');
    }
  }

  // Botão "Testar notificação": o servidor manda um aviso de teste para os
  // aparelhos desta conta. Útil para conferir se o celular está recebendo.
  static Future<void> testar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_suportado) {
      messenger.showSnackBar(const SnackBar(content: Text('Notificações com o app fechado funcionam no aplicativo Android.')));
      return;
    }
    if (!_firebaseOk) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Notificações ainda não estão ativas neste aparelho. Atualize o aplicativo.'),
        backgroundColor: Colors.orange,
      ));
      return;
    }
    await registrar(); // garante que este aparelho está cadastrado
    try {
      final msg = await ApiService().testarPush();
      messenger.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 6)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não foi possível testar agora: $e'), backgroundColor: Colors.red));
    }
  }
}
