import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flag/flag.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:singbox_mm/singbox_mm.dart';
import 'package:url_launcher/url_launcher.dart';

// Сайт оплаты.
const String kStoreUrl = 'https://store.qtunnel.ru/#plans';
const String kDashboardUrl = 'https://store.qtunnel.ru/dashboard';
const String kTelegramBotUrl = 'https://t.me/QTunnel_Bot';
const bool kPlayStoreBuild = bool.fromEnvironment('QTUNNEL_PLAY_STORE');

// Ключи локального хранилища.
const String kPrefsSubscriptionKey = 'subscription_url';
const String kPrefsServerKey = 'selected_server';
const String kPrefsSessionStartKey = 'session_start_ms';
const String kPrefsVpnDisclosureAcceptedKey = 'vpn_disclosure_accepted';

// Нативный аварийный стоп Android VpnService, если обычный stop не подтвердился.
const MethodChannel kVpnControlChannel = MethodChannel('qtunnel/vpn_control');

// Фирменные цвета QTunnel VPN.
const Color kBg = Color(0xFF0A0A0F);
const Color kViolet = Color(0xFF682ECD);
const Color kText = Color(0xFFF7EEFE);
const Color kMuted = Color(0xFFBAA7C8);
// Панели — на базе #0F0F1A (как на сайте), нейтрально-тёмные.
const Color kCard = Color(0xFF0F0F1A); // зона 3 — список / карточки
const Color kZone1 = Color(0xFF1B1B2A); // зона 1 — название (светлее)
const Color kZone2 = Color(0xFF15151F); // зона 2 — трафик (средняя)
const Color kGreenDot = Color(0xFF7DFFCF);
const Color kRedDot = Color(0xFFFF6B8A);

// Фиксированные высоты строк шапки списка серверов.
const double kToggleRowHeight = 52;
const double kTrafficRowHeight = 48;
const double kBottomTabHeight = 52;

// Человекочитаемый размер в байтах.
String fmtBytes(int b) {
  if (b <= 0) return '0 B';
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double v = b.toDouble();
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

// Хранилище логов приложения для бета-теста.
class AppLog extends ChangeNotifier {
  AppLog._();
  static final AppLog instance = AppLog._();

  final List<String> _lines = <String>[];

  List<String> get lines => List<String>.unmodifiable(_lines);
  String get text => _lines.join('\n');

  void add(String message) {
    final String ts = DateTime.now().toIso8601String().substring(11, 23);
    _lines.add('[$ts] $message');
    if (_lines.length > 1000) {
      _lines.removeRange(0, _lines.length - 1000);
    }
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }
}

// Короткий помощник для записи в лог.
void log(String message) => AppLog.instance.add(message);

void main() {
  runZonedGuarded<void>(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      // Edge-to-edge: тёмная панель приложения уходит под системную навигацию
      // (на Android 15+ прямая покраска системной панели не работает).
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: kZone1,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarContrastEnforced: false,
          systemStatusBarContrastEnforced: false,
        ),
      );
      // Перехват ошибок интерфейса в лог.
      FlutterError.onError = (FlutterErrorDetails details) {
        AppLog.instance.add('ОШИБКА UI: ${details.exceptionAsString()}');
        FlutterError.presentError(details);
      };
      log('Приложение запущено');
      runApp(const QTunnelApp());
    },
    // Перехват необработанных вылетов в лог.
    (Object error, StackTrace stack) {
      AppLog.instance.add('ВЫЛЕТ: $error');
    },
  );
}

class QTunnelApp extends StatelessWidget {
  const QTunnelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QTunnel VPN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kViolet,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// Данные подписки из заголовков ответа.
class SubscriptionInfo {
  SubscriptionInfo({
    this.expire,
    this.used = 0,
    this.total = 0,
    this.supportUrl,
    this.title,
    this.updateInterval,
  });

  final DateTime? expire;
  final int used; // использовано байт
  final int total; // лимит байт (0 = безлимит)
  final String? supportUrl; // ссылка поддержки
  final String? title; // название подписки
  final Duration? updateInterval; // интервал обновления из панели

  bool get isActive => expire != null && expire!.isAfter(DateTime.now());

  // Разбирает заголовки подписки (subscription-userinfo, support-url,
  // profile-title).
  static SubscriptionInfo? parse(Map<String, String> headers) {
    final String? userInfo = headers['subscription-userinfo'];
    int up = 0, down = 0, total = 0;
    DateTime? expire;
    if (userInfo != null && userInfo.trim().isNotEmpty) {
      for (final String part in userInfo.split(';')) {
        final List<String> kv = part.trim().split('=');
        if (kv.length != 2) continue;
        final String value = kv[1].trim();
        switch (kv[0].trim()) {
          case 'upload':
            up = int.tryParse(value) ?? 0;
          case 'download':
            down = int.tryParse(value) ?? 0;
          case 'total':
            total = int.tryParse(value) ?? 0;
          case 'expire':
            final int? ts = int.tryParse(value);
            if (ts != null && ts > 0) {
              expire = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
            }
        }
      }
    }

    // Название подписки (может быть в base64).
    String? title = headers['profile-title'];
    if (title != null && title.startsWith('base64:')) {
      try {
        title = utf8.decode(base64.decode(title.substring(7)));
      } catch (_) {
        title = null;
      }
    }

    final Duration? updateInterval = _parseUpdateInterval(headers);

    if (userInfo == null &&
        headers['support-url'] == null &&
        title == null &&
        updateInterval == null) {
      return null;
    }
    return SubscriptionInfo(
      expire: expire,
      used: up + down,
      total: total,
      supportUrl: headers['support-url'],
      title: title,
      updateInterval: updateInterval,
    );
  }

  static Duration? _parseUpdateInterval(Map<String, String> headers) {
    final String? raw =
        headers['profile-update-interval'] ??
        headers['subscription-update-interval'] ??
        headers['update-interval'];
    if (raw == null) return null;

    final int? hours = int.tryParse(raw.trim());
    if (hours == null || hours <= 0) return null;
    return Duration(hours: hours);
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final SignboxVpn _vpn = SignboxVpn();
  final AppLinks _appLinks = AppLinks();
  final TextEditingController _connectSubscriptionController =
      TextEditingController();

  StreamSubscription<VpnConnectionState>? _stateSub;
  StreamSubscription<Uri>? _linkSub;

  VpnConnectionState _state = VpnConnectionState.disconnected;
  bool _busy = false;
  bool _importingSubscription = false;
  bool _quickTileConnectCheckRunning = false;

  int _tab = 0;
  int _previousTab = 0;
  String? _subscriptionUrl;
  SubscriptionInfo? _subInfo;
  late final Future<void> _initFuture;
  bool _showStartupSplash = true;
  bool _bootstrapDone = false;

  // Серверы из подписки и выбранный сервер.
  List<VpnProfile> _servers = <VpnProfile>[];
  VpnProfile? _selectedServer;
  String? _savedServerTag;
  bool _serverPickerExpanded = false;
  bool _devicesExpanded = false;

  // Результаты пинга серверов: тег сервера → задержка в мс (null = недоступен).
  final Map<String, int?> _pingResults = <String, int?>{};
  bool _pinging = false;

  // Таймер сессии подключения.
  Timer? _ticker;
  Timer? _startupSplashTimer;
  Timer? _subscriptionRefreshTimer;
  DateTime? _sessionStart;
  Duration _sessionDuration = Duration.zero;

  // HWID-заголовки для запроса подписки (привязка к устройству).
  Map<String, String> _subHeaders = <String, String>{};

  bool get _hasSubscription =>
      _subscriptionUrl != null && _subscriptionUrl!.trim().isNotEmpty;

  String? get _activeSubscriptionUrl =>
      _hasSubscription ? _subscriptionUrl!.trim() : null;

  void _setTab(int tab) {
    if (_tab == tab) return;
    setState(() {
      _previousTab = _tab;
      _tab = tab;
    });
  }

  String? get _deviceLimitText {
    final String title = (_subInfo?.title ?? '').toLowerCase();
    if (title.contains('family')) return '5';
    if (title.contains('lite')) return '2';
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _stateSub = _vpn.stateStream.listen((VpnConnectionState s) {
      if (mounted) _onStateChanged(s);
    });

    _initFuture = _initRuntime();
    _initDeepLinks();
    _bootstrapWithSplash();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_maybeConnectFromQuickTile());
    }
  }

  // Стартовая загрузка: HWID → подписка → статус → список серверов.
  Future<void> _bootstrapWithSplash() async {
    try {
      await Future.wait<void>(<Future<void>>[
        _initFuture,
        _bootstrap(),
        _startupSplashDelay(),
      ]);
      await _pollVpnState();
    } catch (e) {
      log('Стартовая загрузка завершилась с ошибкой: $e');
    } finally {
      _bootstrapDone = true;
      if (mounted) setState(() => _showStartupSplash = false);
      unawaited(_maybeConnectFromQuickTile());
    }
  }

  Future<void> _startupSplashDelay() {
    final Completer<void> completer = Completer<void>();
    _startupSplashTimer?.cancel();
    _startupSplashTimer = Timer(const Duration(milliseconds: 1150), () {
      _startupSplashTimer = null;
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  Future<void> _bootstrap() async {
    await _loadDeviceInfo();
    await _loadSubscription();
    await _refreshSubscriptionInfo();
    await _loadServers();
  }

  // Формирует HWID-заголовки. HWID берётся из ANDROID_ID, хранится постоянно.
  Future<void> _loadDeviceInfo() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    String hwid = prefs.getString('hwid') ?? '';
    String osVer = '';
    String model = 'Android';
    try {
      final AndroidDeviceInfo a = await DeviceInfoPlugin().androidInfo;
      osVer = a.version.release;
      model = '${a.manufacturer} ${a.model}'.trim();
      if (hwid.isEmpty && a.id.isNotEmpty) hwid = a.id;
    } catch (_) {
      // Не Android или ошибка — используем запасной HWID.
    }
    if (hwid.isEmpty) {
      hwid =
          'qt-${DateTime.now().microsecondsSinceEpoch}'
          '-${Random().nextInt(1 << 30)}';
    }
    await prefs.setString('hwid', hwid);
    _subHeaders = <String, String>{
      'x-hwid': hwid,
      'x-device-os': 'Android',
      'x-ver-os': osVer,
      'x-device-model': model,
      'user-agent': 'QTunnel/1.0',
    };
    log('HWID: $hwid · $model · Android $osVer');
  }

  void _onStateChanged(VpnConnectionState s) {
    log('Состояние VPN: ${s.wireValue}');
    setState(() => _state = s);
    unawaited(_setQuickTileConnected(s == VpnConnectionState.connected));
    if (s == VpnConnectionState.connected) {
      unawaited(_restoreOrStartSessionTimer());
    } else {
      unawaited(_clearPersistedSessionStart());
      _resetSessionTimer();
    }
  }

  Future<void> _restoreOrStartSessionTimer() async {
    if (_sessionStart != null) {
      _ensureSessionTicker();
      return;
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? savedMs = prefs.getInt(kPrefsSessionStartKey);
    final DateTime now = DateTime.now();
    DateTime startedAt = now;
    if (savedMs != null) {
      final DateTime saved = DateTime.fromMillisecondsSinceEpoch(savedMs);
      if (saved.isBefore(now.add(const Duration(seconds: 5)))) {
        startedAt = saved;
      } else {
        await prefs.setInt(
          kPrefsSessionStartKey,
          startedAt.millisecondsSinceEpoch,
        );
      }
    } else {
      await prefs.setInt(
        kPrefsSessionStartKey,
        startedAt.millisecondsSinceEpoch,
      );
    }

    if (!mounted || _state != VpnConnectionState.connected) return;
    setState(() {
      _sessionStart = startedAt;
      _sessionDuration = now.difference(startedAt);
    });
    _ensureSessionTicker();
  }

  void _ensureSessionTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _sessionStart != null) {
        setState(() {
          _sessionDuration = DateTime.now().difference(_sessionStart!);
        });
      }
    });
  }

  Future<void> _clearPersistedSessionStart() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(kPrefsSessionStartKey);
  }

  Future<void> _initRuntime() async {
    try {
      await _vpn.initialize(const SingboxRuntimeOptions());
      log('Ядро VPN инициализировано');
    } catch (e) {
      _showError('Ошибка инициализации: $e');
    }
  }

  void _showError(String message) {
    log('ОШИБКА: $message');
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _ensureVpnDisclosureAccepted() async {
    if (!kPlayStoreBuild) return true;

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(kPrefsVpnDisclosureAcceptedKey) ?? false) return true;
    if (!mounted) return false;

    final bool accepted =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return AlertDialog(
              backgroundColor: kCard,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
              title: const Text(
                'VPN-подключение',
                style: TextStyle(color: kText, fontWeight: FontWeight.w900),
              ),
              content: const Text(
                'QTunnel создает системный VPN-туннель, чтобы направлять сетевой трафик через выбранный сервер. Продолжайте только если доверяете своей подписке и серверу.',
                style: TextStyle(
                  color: Color(0xFFB8ACCC),
                  fontSize: 14,
                  height: 1.35,
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(backgroundColor: kViolet),
                  child: const Text('Понятно'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (accepted) {
      await prefs.setBool(kPrefsVpnDisclosureAcceptedKey, true);
    }
    return accepted;
  }

  Future<void> _loadSubscription() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? saved = prefs.getString(kPrefsSubscriptionKey);
    _savedServerTag = prefs.getString(kPrefsServerKey);
    if (saved != null && saved.isNotEmpty && mounted) {
      setState(() => _subscriptionUrl = saved);
    }
  }

  Future<void> _saveSubscription(String url) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefsSubscriptionKey, url);
    if (mounted) setState(() => _subscriptionUrl = url);
  }

  Future<void> _importSubscriptionFromConnectInput() async {
    if (_importingSubscription) return;

    String url = _connectSubscriptionController.text.trim();
    final Uri? inputUri = Uri.tryParse(url);
    if (inputUri != null &&
        inputUri.scheme == 'qtunnel' &&
        inputUri.host == 'import') {
      url = inputUri.queryParameters['url']?.trim() ?? url;
    }

    final Uri? subscriptionUri = Uri.tryParse(url);
    if (url.isEmpty) {
      _showError('Вставьте ссылку подписки');
      return;
    }
    if (subscriptionUri == null ||
        !subscriptionUri.hasScheme ||
        (subscriptionUri.scheme != 'http' &&
            subscriptionUri.scheme != 'https')) {
      _showError('Неверная ссылка подписки');
      return;
    }

    setState(() => _importingSubscription = true);
    try {
      await _saveSubscription(url);
      await _refreshSubscriptionInfo();
      await _loadServers();
      _connectSubscriptionController.clear();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Подписка добавлена')));
      }
    } finally {
      if (mounted) setState(() => _importingSubscription = false);
    }
  }

  Future<void> _pasteSubscriptionToConnectInput() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _showError('В буфере обмена нет ссылки');
      return;
    }
    _connectSubscriptionController.text = text;
    _connectSubscriptionController.selection = TextSelection.collapsed(
      offset: text.length,
    );
  }

  // Загружает список серверов, разбирая подписку.
  Future<void> _loadServers() async {
    try {
      if (_subHeaders.isEmpty) await _loadDeviceInfo();
      final String? url = _activeSubscriptionUrl;
      if (url == null) {
        if (mounted) {
          setState(() {
            _servers = <VpnProfile>[];
            _selectedServer = null;
            _pingResults.clear();
          });
        }
        return;
      }
      final http.Response resp = await http.get(
        Uri.parse(url),
        headers: _subHeaders,
      );
      if (resp.statusCode == 404) {
        log('Подписка: 404 (лимит устройств или подписка недоступна)');
        _showError('Достигнут лимит устройств подписки');
        return;
      }
      if (resp.statusCode != 200) {
        log('Подписка: код ${resp.statusCode}');
        return;
      }
      final ParsedVpnSubscription parsed = _vpn.parseSubscription(resp.body);
      final SubscriptionInfo? info = SubscriptionInfo.parse(resp.headers);
      final List<VpnProfile> supportedProfiles = parsed.profiles
          .where((VpnProfile profile) => !_isXhttpProfile(profile))
          .toList(growable: false);
      if (!mounted) return;
      final int hiddenXhttpCount =
          parsed.profiles.length - supportedProfiles.length;
      log(
        'Загружено серверов: ${supportedProfiles.length}'
        '${hiddenXhttpCount > 0 ? ' (xHTTP скрыто: $hiddenXhttpCount)' : ''}',
      );
      setState(() {
        if (info != null) {
          _subInfo = info;
          _scheduleSubscriptionAutoRefresh(info);
        }
        _servers = supportedProfiles;
        _pingResults.clear();
        if (_servers.isNotEmpty) {
          _selectedServer = _servers.firstWhere(
            (VpnProfile p) => p.tag == _savedServerTag,
            orElse: () => _servers.first,
          );
        } else {
          _selectedServer = null;
        }
      });
    } catch (_) {
      // Молча — список просто останется пустым.
    }
  }

  // Запрашивает статус подписки (срок, трафик) из заголовка ответа.
  Future<void> _refreshSubscriptionInfo() async {
    try {
      if (_subHeaders.isEmpty) await _loadDeviceInfo();
      final String? url = _activeSubscriptionUrl;
      if (url == null) {
        if (mounted) setState(() => _subInfo = null);
        return;
      }
      final http.Response resp = await http.get(
        Uri.parse(url),
        headers: _subHeaders,
      );
      final SubscriptionInfo? info = SubscriptionInfo.parse(resp.headers);
      if (mounted) {
        setState(() => _subInfo = info);
        _scheduleSubscriptionAutoRefresh(info);
      }
    } catch (_) {}
  }

  // Обновление подписки: перезагружает серверы и статус.
  Future<void> _refreshSubscription() async {
    await _loadServers();
    await _refreshSubscriptionInfo();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Подписка обновлена')));
    }
  }

  void _scheduleSubscriptionAutoRefresh(SubscriptionInfo? info) {
    _subscriptionRefreshTimer?.cancel();
    final Duration? interval = info?.updateInterval;
    if (interval == null || !_hasSubscription) return;

    _subscriptionRefreshTimer = Timer(interval, () {
      unawaited(_autoRefreshSubscription());
    });
    log('Автообновление подписки через ${interval.inHours} ч.');
  }

  Future<void> _autoRefreshSubscription() async {
    if (!_hasSubscription || _importingSubscription) return;
    log('Автообновление подписки');
    await _loadServers();
    await _refreshSubscriptionInfo();
  }

  // Замер задержки до сервера через TCP-подключение (как в v2rayTun).
  Future<int?> _tcpPing(String host, int port) async {
    final Stopwatch sw = Stopwatch()..start();
    try {
      final Socket socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 4),
      );
      sw.stop();
      socket.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  // Пинг-тест всех серверов из списка.
  Future<void> _pingAll() async {
    if (_pinging || _servers.isEmpty) return;
    setState(() => _pinging = true);
    try {
      await Future.wait(
        _servers.map((VpnProfile s) async {
          final int? ms = await _tcpPing(s.server, s.serverPort);
          if (mounted) setState(() => _pingResults[s.tag] = ms);
        }),
      );
    } finally {
      if (mounted) setState(() => _pinging = false);
    }
  }

  void _initDeepLinks() {
    _linkSub = _appLinks.uriLinkStream.listen(
      _handleDeepLink,
      onError: (Object e) {
        _showError('Ошибка ссылки: $e');
      },
    );
  }

  Future<void> _handleDeepLink(Uri uri) async {
    if (uri.scheme != 'qtunnel' || uri.host != 'import') return;
    log('Deep link: $uri');

    final String? url = uri.queryParameters['url'];
    if (url == null || url.isEmpty) {
      _showError('Ссылка без подписки');
      return;
    }

    await _saveSubscription(url);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Подписка импортирована')));
    await _refreshSubscriptionInfo();
    await _loadServers();
    await _connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _startupSplashTimer?.cancel();
    _subscriptionRefreshTimer?.cancel();
    _connectSubscriptionController.dispose();
    _stateSub?.cancel();
    _linkSub?.cancel();
    unawaited(_vpn.dispose());
    super.dispose();
  }

  bool get _isConnected => _state == VpnConnectionState.connected;
  bool get _isConnecting => _state == VpnConnectionState.connecting;
  bool get _isDisconnecting => _state == VpnConnectionState.disconnecting;
  bool get _isRuntimeBusy => _busy || _isConnecting || _isDisconnecting;

  Future<void> _toggle() async {
    if (_busy) return;
    if (_isDisconnecting) return;
    // Тап во время «подключения» тоже отключает — кнопка не залипает.
    if (_isConnected || _isConnecting) {
      await _disconnect();
    } else {
      await _connect();
    }
  }

  Future<VpnConnectionState?> _pollVpnState() async {
    try {
      final VpnConnectionState state = await _vpn.getState().timeout(
        const Duration(seconds: 2),
      );
      if (mounted) _onStateChanged(state);
      return state;
    } catch (e) {
      log('Не удалось прочитать состояние VPN: $e');
      return null;
    }
  }

  Future<bool> _waitForVpnStopped(Duration timeout) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final VpnConnectionState? state = await _pollVpnState();
      if (state == VpnConnectionState.disconnected ||
          state == VpnConnectionState.error) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    return false;
  }

  Future<void> _forceStopVpnService() async {
    try {
      await kVpnControlChannel
          .invokeMethod<void>('forceStopVpn')
          .timeout(const Duration(seconds: 3));
      log('Отправлен принудительный стоп VpnService');
    } catch (e) {
      log('Принудительный стоп VpnService недоступен: $e');
    }
  }

  Future<void> _setQuickTileConnected(bool connected) async {
    try {
      await kVpnControlChannel.invokeMethod<void>('setQuickTileConnected', {
        'connected': connected,
      });
    } catch (e) {
      log('Quick Settings tile update is unavailable: $e');
    }
  }

  Future<bool> _consumeQuickTileConnectRequest() async {
    try {
      return await kVpnControlChannel.invokeMethod<bool>(
            'consumeQuickTileConnectRequest',
          ) ??
          false;
    } catch (e) {
      log('Quick Settings tile request is unavailable: $e');
      return false;
    }
  }

  Future<void> _maybeConnectFromQuickTile() async {
    if (!_bootstrapDone ||
        _quickTileConnectCheckRunning ||
        _busy ||
        _isConnected ||
        _isConnecting) {
      return;
    }
    _quickTileConnectCheckRunning = true;
    try {
      final bool requested = await _consumeQuickTileConnectRequest();
      if (!requested) return;
      await _initFuture;
      if (!_hasSubscription) {
        _showError('Добавьте подписку, чтобы подключиться');
        if (mounted) _setTab(0);
        return;
      }
      await _connect();
    } finally {
      _quickTileConnectCheckRunning = false;
    }
  }

  // Сброс таймера сессии (UI сразу показывает 00:00:00).
  void _resetSessionTimer() {
    _ticker?.cancel();
    _ticker = null;
    _sessionStart = null;
    _sessionDuration = Duration.zero;
  }

  Future<void> _connect() async {
    if (_busy) return;
    if (!_hasSubscription) {
      _showError('Добавьте подписку через сайт');
      if (mounted) _setTab(1);
      return;
    }
    setState(() => _busy = true);
    await _clearPersistedSessionStart();
    _resetSessionTimer();
    try {
      await _initFuture;

      final bool disclosureOk = await _ensureVpnDisclosureAccepted();
      if (!disclosureOk) return;

      final bool vpnOk = await _vpn.requestVpnPermission();
      if (!vpnOk) throw 'Разрешение на VPN не выдано';
      await _vpn.requestNotificationPermission();

      if (_servers.isEmpty) await _loadServers();
      final VpnProfile? server =
          _selectedServer ?? (_servers.isNotEmpty ? _servers.first : null);
      if (server == null) throw 'В подписке нет серверов';

      log('Подключение к серверу: ${server.tag}');
      // Таймаут — чтобы зависший вызов ядра не оставил кнопку залипшей.
      if (_isXhttpProfile(server)) {
        final GfwPresetPack preset = GfwPresetPack.fromMode(
          GfwPresetMode.balanced,
        );
        final SingboxFeatureSettings settings = _withXrayFallback(
          preset.featureSettings,
        );
        final ManualConnectResult result = await _vpn
            .connectManualProfile(
              profile: server,
              bypassPolicy: preset.bypassPolicy,
              throttlePolicy: preset.throttlePolicy,
              featureSettings: settings,
            )
            .timeout(const Duration(seconds: 35));
        for (final String warning in result.warnings) {
          log('VPN: $warning');
        }
        await _ensureXhttpConnectivity();
      } else {
        await _vpn
            .connectManualWithPreset(
              profile: server,
              preset: GfwPresetPack.fromMode(GfwPresetMode.balanced),
            )
            .timeout(const Duration(seconds: 25));
      }
    } on TimeoutException {
      _showError('Превышено время подключения');
    } catch (e) {
      _showError('Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ensureXhttpConnectivity() async {
    try {
      final probe = await _vpn.probeConnectivity(
        timeout: const Duration(seconds: 6),
      );
      if (probe.success) return;

      await _vpn.stop().timeout(const Duration(seconds: 5));
      final String reason = probe.error?.trim().isNotEmpty == true
          ? ': ${probe.error}'
          : '';
      throw 'xHTTP подключился, но трафик не проходит$reason';
    } on TimeoutException {
      await _forceStopVpnService();
      throw 'xHTTP подключился, но проверка интернета зависла';
    }
  }

  bool _isXhttpProfile(VpnProfile profile) {
    final Object? alias = profile.extra['_sbmm_transport_alias'];
    if (alias is String && alias.toLowerCase() == 'xhttp') return true;
    return profile.transport == VpnTransport.http &&
        (profile.tls.realityPublicKey?.isNotEmpty ?? false);
  }

  SingboxFeatureSettings _withXrayFallback(SingboxFeatureSettings source) {
    final MiscOptions misc = source.misc;
    return SingboxFeatureSettings(
      advanced: source.advanced,
      route: source.route,
      dns: source.dns,
      inbound: source.inbound,
      tlsTricks: source.tlsTricks,
      warp: source.warp,
      rawConfigPatch: source.rawConfigPatch,
      misc: MiscOptions(
        connectionTestUrl: misc.connectionTestUrl,
        urlTestInterval: misc.urlTestInterval,
        clashApiPort: misc.clashApiPort,
        useXrayCoreWhenPossible: true,
      ),
    );
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    log('Отключение VPN');
    setState(() => _busy = true);
    try {
      await _vpn.stop().timeout(const Duration(seconds: 5));
      final bool stopped = await _waitForVpnStopped(const Duration(seconds: 8));
      if (!stopped) {
        log('Обычный stop не подтвердил отключение, пробуем force stop');
        await _forceStopVpnService();
        final bool forceStopped = await _waitForVpnStopped(
          const Duration(seconds: 5),
        );
        if (!forceStopped) {
          _onStateChanged(VpnConnectionState.disconnected);
          _showError('VPN остановлен принудительно');
        }
      }
    } on TimeoutException {
      log('Таймаут обычного stop, пробуем force stop');
      await _forceStopVpnService();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      _onStateChanged(VpnConnectionState.disconnected);
    } catch (e) {
      _showError('Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Выбор сервера пользователем.
  Future<void> _selectServer(VpnProfile server) async {
    setState(() {
      _selectedServer = server;
      _serverPickerExpanded = false;
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPrefsServerKey, server.tag);
    _savedServerTag = server.tag;
    // Если VPN активен — переподключаемся к новому серверу напрямую.
    // Ядро само корректно меняет сервер; _connect сразу сбрасывает таймер.
    if ((_isConnected || _isConnecting) && !_busy) {
      await _connect();
    }
  }

  // Разворачивает/сворачивает список серверов прямо на экране.
  Future<void> _toggleServerPicker() async {
    if (!_serverPickerExpanded && _servers.isEmpty) {
      await _loadServers();
      if (!mounted) return;
      if (_servers.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось загрузить серверы')),
        );
        return;
      }
    }
    setState(() => _serverPickerExpanded = !_serverPickerExpanded);
  }

  Future<void> _openStore() async {
    if (kPlayStoreBuild) {
      _setTab(0);
      return;
    }
    final bool ok = await launchUrl(
      Uri.parse(kStoreUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Не удалось открыть сайт')));
    }
  }

  Future<void> _openDashboard() async {
    final bool ok = await launchUrl(
      Uri.parse(kDashboardUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Не удалось открыть сайт')));
    }
  }

  // Открывает ссылку поддержки из подписки.
  Future<void> _openSupport() async {
    final String? url = _subInfo?.supportUrl;
    if (url == null) return;
    final bool ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) _showError('Не удалось открыть поддержку');
  }

  Future<void> _openBot() async {
    final String url = _subInfo?.supportUrl ?? kTelegramBotUrl;
    final bool ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) _showError('Не удалось открыть бота');
  }

  static String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  static String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Scaffold(
          body: Stack(
            children: <Widget>[
              const Positioned.fill(child: _AmbientBackground()),
              SafeArea(
                child: ClipRect(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 340),
                    reverseDuration: const Duration(milliseconds: 300),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (Widget child, Animation<double> anim) {
                      final int childTab =
                          (child.key as ValueKey<int>?)?.value ?? _tab;
                      final double direction = _tab >= _previousTab
                          ? 1.0
                          : -1.0;
                      final bool incoming = childTab == _tab;
                      final Animation<Offset> offset = Tween<Offset>(
                        begin: Offset(
                          0.04 * (incoming ? direction : -direction),
                          0,
                        ),
                        end: Offset.zero,
                      ).animate(anim);
                      return FadeTransition(
                        opacity: anim,
                        child: SlideTransition(position: offset, child: child),
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey<int>(_tab),
                      child: _tab == 0
                          ? _buildConnectTab()
                          : _buildSubscriptionTab(),
                    ),
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: Container(
            color: const Color(0xFF0F0F1A),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: kBottomTabHeight,
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: _TabButton(
                        icon: Icons.power_settings_new,
                        label: 'Подключение',
                        selected: _tab == 0,
                        onTap: () => _setTab(0),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _TabButton(
                        icon: Icons.workspace_premium,
                        label: 'Подписка',
                        selected: _tab == 1,
                        onTap: () {
                          _setTab(1);
                          _refreshSubscriptionInfo();
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_showStartupSplash,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _showStartupSplash
                  ? const _StartupSplash(key: ValueKey<String>('splash'))
                  : const SizedBox.shrink(key: ValueKey<String>('empty')),
            ),
          ),
        ),
      ],
    );
  }

  // ВКЛАДКА 1 — подключение.
  Widget _buildConnectTab() {
    final bool hasSub = _hasSubscription;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        children: <Widget>[
          // ── Фиксированная верхняя часть ──
          _AppHeader(
            action: _LogButton(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => const LogsScreen(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
          const SizedBox(height: 18),
          _ConnectButton(
            connected: _isConnected && !_busy,
            busy: _isRuntimeBusy,
            statusLabel: _isDisconnecting
                ? 'ОТКЛЮЧЕНИЕ'
                : (_busy && _isConnected ? 'ОТКЛЮЧЕНИЕ' : null),
            sessionTime: (_isConnected && !_busy)
                ? _formatDuration(_sessionDuration)
                : null,
            onTap: _toggle,
          ),
          const SizedBox(height: 16),
          // ── Список серверов — занимает оставшееся место ──
          Expanded(
            child: hasSub
                ? LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      // Точная высота шапки → список никогда не переполняет.
                      final double headerH =
                          kToggleRowHeight +
                          (_subInfo != null ? kTrafficRowHeight : 0.0);
                      final double maxList =
                          (constraints.maxHeight - headerH - 5).clamp(
                            80.0,
                            600.0,
                          );
                      return Align(
                        alignment: Alignment.topCenter,
                        child: _ServerDropdown(
                          selectedName:
                              _selectedServer?.tag ?? 'Сервер не выбран',
                          servers: _servers,
                          selected: _selectedServer,
                          expanded: _serverPickerExpanded,
                          maxListHeight: maxList,
                          pinging: _pinging,
                          pingResults: _pingResults,
                          subInfo: _subInfo,
                          onToggle: _isRuntimeBusy ? null : _toggleServerPicker,
                          onSelect: _selectServer,
                          onRefresh: _refreshSubscription,
                          onPing: _pingAll,
                          onSupport: _subInfo?.supportUrl != null
                              ? _openSupport
                              : null,
                        ),
                      );
                    },
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: _NoSubscriptionConnectCard(
                        controller: _connectSubscriptionController,
                        importing: _importingSubscription,
                        onImport: _importSubscriptionFromConnectInput,
                        onPaste: _pasteSubscriptionToConnectInput,
                        onStoreTap: kPlayStoreBuild ? null : _openStore,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ВКЛАДКА 2 — подписка.
  Widget _buildSubscriptionTab() {
    final SubscriptionInfo? info = _subInfo;
    final bool hasSub = _hasSubscription;

    if (!hasSub) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
        children: <Widget>[
          _AppHeader(
            subtitle: 'Подписка',
            action: _HeaderIcon(
              icon: Icons.refresh,
              tooltip: 'Обновить подписку',
              onTap: _refreshSubscription,
            ),
          ),
          const SizedBox(height: 26),
          _NoSubscriptionStoreCard(
            onStoreTap: kPlayStoreBuild ? null : _openStore,
            onConnectTap: () => _setTab(0),
          ),
        ],
      );
    }

    final Color dotColor;
    final String statusText;
    if (info != null && info.isActive) {
      dotColor = kGreenDot;
      statusText = 'Подписка активна';
    } else if (info != null && !info.isActive) {
      dotColor = kRedDot;
      statusText = 'Подписка истекла';
    } else if (hasSub) {
      dotColor = kViolet;
      statusText = 'Подписка импортирована';
    } else {
      dotColor = kRedDot;
      statusText = 'Подписка не активна';
    }

    final bool active = info?.isActive ?? false;
    final bool expired = info != null && !info.isActive;
    final DateTime? expire = info?.expire;
    final bool expiresSoon =
        active &&
        expire != null &&
        expire.difference(DateTime.now()) <= const Duration(days: 3);
    final bool showPlans = !kPlayStoreBuild && !active && !expired;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
      children: <Widget>[
        _AppHeader(
          subtitle: 'Личный кабинет',
          action: _HeaderIcon(
            icon: Icons.refresh,
            tooltip: 'Обновить подписку',
            onTap: _refreshSubscription,
          ),
        ),
        const SizedBox(height: 24),
        _SubscriptionCabinetCard(
          dotColor: dotColor,
          statusText: statusText,
          expireText: info?.expire != null ? _formatDate(info!.expire!) : null,
          serversText: '${_servers.length}',
          subscriptionUrl: _activeSubscriptionUrl,
          showDevices: active,
          devicesExpanded: _devicesExpanded,
          deviceLimitText: _deviceLimitText,
          onDevicesToggle: () {
            setState(() => _devicesExpanded = !_devicesExpanded);
          },
          onManageDevices: _openDashboard,
          onBotTap: kPlayStoreBuild ? null : _openBot,
          title: info?.title,
        ),
        if (!active && !expired) const SizedBox(height: 18),
        if (!active && !expired)
          _SubscriptionHint(
            icon: Icons.lock_outline,
            title: 'Подписка не активна',
            text: kPlayStoreBuild
                ? 'Если у вас уже есть ключ подписки, добавьте его на экране подключения.'
                : 'Выберите тариф на сайте. После оплаты нажмите '
                      '«Открыть в приложении», и ключ подключится автоматически.',
          ),
        const SizedBox(height: 24),
        if (expired) ...<Widget>[
          const Text(
            'Подписка закончилась',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: Color(0xFF4A4A68),
            ),
          ),
          const SizedBox(height: 12),
          _RenewSubscriptionCard(
            daysLeft: 0,
            expired: true,
            playStoreBuild: kPlayStoreBuild,
            onTap: _openStore,
          ),
        ] else if (expiresSoon) ...<Widget>[
          const Text(
            'Скоро закончится',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: Color(0xFF4A4A68),
            ),
          ),
          const SizedBox(height: 12),
          _RenewSubscriptionCard(
            daysLeft: expire.difference(DateTime.now()).inDays.clamp(0, 3),
            playStoreBuild: kPlayStoreBuild,
            onTap: _openStore,
          ),
        ] else if (showPlans) ...<Widget>[
          Text(
            'Купить подписку',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: Color(0xFF4A4A68),
            ),
          ),
          const SizedBox(height: 12),
          _PlanTile(
            name: 'Family',
            details: '5 устройств · 30 дней',
            price: '₽599',
            highlighted: true,
            onTap: _openStore,
          ),
          const SizedBox(height: 10),
          _PlanTile(
            name: 'Lite',
            details: '2 устройства · 30 дней',
            price: '₽299',
            onTap: _openStore,
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              'Покупка откроется на store.qtunnel.ru',
              style: TextStyle(fontSize: 12, color: Color(0xFF4A4A68)),
            ),
          ),
        ] else if (!kPlayStoreBuild)
          _OpenStoreButton(onTap: _openStore),
      ],
    );
  }
}

class _NoSubscriptionStoreCard extends StatelessWidget {
  const _NoSubscriptionStoreCard({
    required this.onStoreTap,
    required this.onConnectTap,
  });

  final VoidCallback? onStoreTap;
  final VoidCallback onConnectTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kCard,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: kRedDot,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Подписка не активна',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: kText,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              onStoreTap == null
                  ? 'Если у вас уже есть ключ подписки, добавьте его на экране подключения.'
                  : 'Купите подписку на сайте или вставьте уже готовый ключ на экране подключения.',
              style: TextStyle(
                color: Color(0xFF7B7397),
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 18),
            if (onStoreTap != null) ...<Widget>[
              _LargeStoreButton(onTap: onStoreTap!),
              const SizedBox(height: 10),
            ],
            Center(
              child: TextButton(
                onPressed: onConnectTap,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFA78BFA),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                child: const Text('Уже есть ключ? Перейти к подключению'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RenewSubscriptionCard extends StatelessWidget {
  const _RenewSubscriptionCard({
    required this.daysLeft,
    required this.onTap,
    this.expired = false,
    this.playStoreBuild = false,
  });

  final int daysLeft;
  final VoidCallback onTap;
  final bool expired;
  final bool playStoreBuild;

  @override
  Widget build(BuildContext context) {
    final String dayWord = switch (daysLeft) {
      1 => 'день',
      2 || 3 || 4 => 'дня',
      _ => 'дней',
    };

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: kViolet.withValues(alpha: 0.32),
            blurRadius: 28,
            spreadRadius: 1,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: kCard,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: kViolet.withValues(alpha: 0.82), width: 1.3),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    expired
                        ? Icons.lock_clock_outlined
                        : Icons.hourglass_bottom,
                    color: const Color(0xFFA78BFA),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      expired
                          ? 'Подписка закончилась'
                          : (playStoreBuild
                                ? 'Срок подписки заканчивается'
                                : 'Пора продлить подписку'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kText,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    color: Color(0xFF7B7397),
                    fontSize: 13,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                  children: <InlineSpan>[
                    if (expired) ...<InlineSpan>[
                      const TextSpan(
                        text: 'Подписка закончилась',
                        style: TextStyle(
                          color: Color(0xFFA78BFA),
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      TextSpan(
                        text: playStoreBuild
                            ? '. Добавьте новый ключ подписки на экране подключения.'
                            : '. Продлите ее, чтобы снова подключиться к VPN.',
                      ),
                    ] else ...<InlineSpan>[
                      const TextSpan(text: 'До конца подписки '),
                      TextSpan(
                        text: 'осталось $daysLeft $dayWord',
                        style: const TextStyle(
                          color: Color(0xFFA78BFA),
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const TextSpan(
                        text: '. Продлите подписку, чтобы доступ не прервался.',
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (playStoreBuild)
                _LargeStoreButton(
                  label: 'Добавить ключ',
                  icon: Icons.add_link,
                  onTap: onTap,
                )
              else
                _LargeStoreButton(
                  label: 'Продлить подписку',
                  icon: Icons.autorenew,
                  onTap: onTap,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LargeStoreButton extends StatelessWidget {
  const _LargeStoreButton({
    required this.onTap,
    this.label = 'Купить подписку',
    this.icon = Icons.shopping_cart_outlined,
  });

  final VoidCallback onTap;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kViolet,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        splashColor: Colors.white.withValues(alpha: 0.08),
        highlightColor: Colors.white.withValues(alpha: 0.04),
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(
              colors: <Color>[Color(0xFF9D4DF5), Color(0xFF6D28D9)],
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: kViolet.withValues(alpha: 0.28),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, color: kText, size: 20),
              const SizedBox(width: 9),
              Text(
                label,
                style: const TextStyle(
                  color: kText,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StartupSplash extends StatelessWidget {
  const _StartupSplash({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kBg,
      child: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.88, end: 1.0),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          builder: (BuildContext context, double scale, Widget? child) {
            final double opacity = ((scale - 0.88) / 0.12).clamp(0.0, 1.0);
            return Opacity(
              opacity: opacity,
              child: Transform.scale(scale: scale, child: child),
            );
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(
                  'assets/icon/logo.png',
                  width: 90,
                  height: 90,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'QTUNNEL VPN',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: Color(0xFF4A4A68),
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                width: 120,
                height: 2,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A2E),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 1050),
                  curve: Curves.easeInOutCubic,
                  builder: (BuildContext context, double value, Widget? child) {
                    return FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: value,
                      child: child,
                    );
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: const LinearGradient(
                        colors: <Color>[Color(0xFF6D28D9), Color(0xFFA78BFA)],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Фоновые радиальные свечения по углам экрана.
class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      children: <Widget>[
        Positioned(
          top: -200,
          left: -200,
          child: _Glow(
            color: Color(0xFF682ECD),
            maxOpacity: 0.15,
            diameter: 620,
          ),
        ),
        Positioned(
          bottom: -220,
          right: -200,
          child: _Glow(
            color: Color(0xFF5A2BB8),
            maxOpacity: 0.11,
            diameter: 600,
          ),
        ),
      ],
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({
    required this.color,
    required this.maxOpacity,
    required this.diameter,
  });

  final Color color;
  final double maxOpacity;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: <Color>[
              color.withValues(alpha: maxOpacity),
              color.withValues(alpha: 0.0),
            ],
          ),
        ),
      ),
    );
  }
}

// Кнопка открытия логов в шапке.
class _LogButton extends StatelessWidget {
  const _LogButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kZone1,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: const Icon(Icons.receipt_long, size: 20, color: kMuted),
        ),
      ),
    );
  }
}

// Экран просмотра и экспорта логов.
class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key});

  Future<void> _export() async {
    final Directory dir = await getTemporaryDirectory();
    final File file = File('${dir.path}/qtunnel-logs.txt');
    await file.writeAsString(AppLog.instance.text);
    await Share.shareXFiles(<XFile>[
      XFile(file.path),
    ], subject: 'QTunnel — логи');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kZone1,
        foregroundColor: kText,
        title: const Text('Логи'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Очистить',
            icon: const Icon(Icons.delete_outline),
            onPressed: AppLog.instance.clear,
          ),
          IconButton(
            tooltip: 'Экспорт файлом',
            icon: const Icon(Icons.ios_share),
            onPressed: _export,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: AppLog.instance,
        builder: (BuildContext context, Widget? child) {
          final List<String> lines = AppLog.instance.lines;
          if (lines.isEmpty) {
            return const Center(
              child: Text('Логи пусты', style: TextStyle(color: kMuted)),
            );
          }
          return SingleChildScrollView(
            reverse: true,
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              lines.join('\n'),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                color: kText,
                height: 1.5,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.26),
      child: Image.asset(
        'assets/icon/logo.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}

class _AppHeader extends StatelessWidget {
  const _AppHeader({required this.action, this.subtitle});

  final Widget action;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final String? caption = subtitle;
    return Row(
      children: <Widget>[
        const _Logo(size: 30),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                'QTunnel VPN',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: kText,
                ),
              ),
              if (caption != null && caption.isNotEmpty) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Color(0xFF4A4A68),
                  ),
                ),
              ],
            ],
          ),
        ),
        action,
      ],
    );
  }
}

// Кнопка-вкладка в нижней панели.
class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color fg = selected ? Colors.white : kMuted;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          height: kBottomTabHeight,
          width: double.infinity,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: selected
                ? kViolet.withValues(alpha: 0.28)
                : Colors.white.withValues(alpha: 0.04),
            border: Border.all(
              color: selected
                  ? kViolet.withValues(alpha: 0.7)
                  : Colors.transparent,
              width: 1.4,
            ),
            boxShadow: selected
                ? <BoxShadow>[
                    BoxShadow(
                      color: kViolet.withValues(alpha: 0.28),
                      blurRadius: 16,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 20, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Компактная иконка в шапке списка серверов.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      iconSize: 25,
      color: kMuted,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 46, minHeight: 46),
      icon: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: kViolet),
            )
          : Icon(icon),
    );
  }
}

// Кнопка поддержки рядом со шкалой трафика.
class _SupportButton extends StatelessWidget {
  const _SupportButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kViolet.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.support_agent, size: 16, color: kViolet),
              SizedBox(width: 5),
              Text(
                'Поддержка',
                style: TextStyle(
                  fontSize: 12,
                  color: kViolet,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoSubscriptionConnectCard extends StatelessWidget {
  const _NoSubscriptionConnectCard({
    required this.controller,
    required this.importing,
    required this.onImport,
    required this.onPaste,
    required this.onStoreTap,
  });

  final TextEditingController controller;
  final bool importing;
  final VoidCallback onImport;
  final VoidCallback onPaste;
  final VoidCallback? onStoreTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kCard,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: kRedDot,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Подписка не добавлена',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: kText,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Добавьте ключ подписки, чтобы выбрать сервер и подключиться.',
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: Color(0xFF7B7397),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              enabled: !importing,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => onImport(),
              style: const TextStyle(
                color: kText,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                hintText: 'https://sub.qtunnel.ru/...',
                hintStyle: const TextStyle(
                  color: Color(0xFF5D5578),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                filled: true,
                fillColor: Colors.black.withValues(alpha: 0.22),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                suffixIcon: IconButton(
                  onPressed: importing ? null : onPaste,
                  tooltip: 'Вставить из буфера',
                  icon: const Icon(
                    Icons.content_paste,
                    color: kViolet,
                    size: 21,
                  ),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.07),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.07),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: kViolet.withValues(alpha: 0.72),
                    width: 1.2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: _InlineActionButton(
                icon: Icons.add_link,
                label: importing ? 'Добавляем...' : 'Добавить подписку',
                onTap: importing ? null : onImport,
              ),
            ),
            if (onStoreTap != null) ...<Widget>[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: _InlineActionButton(
                  icon: Icons.shopping_cart_outlined,
                  label: 'Купить',
                  primary: true,
                  onTap: onStoreTap,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InlineActionButton extends StatelessWidget {
  const _InlineActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onTap == null
          ? kZone1.withValues(alpha: 0.55)
          : (primary ? kViolet : kZone1),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        splashColor: Colors.white.withValues(alpha: 0.08),
        highlightColor: Colors.white.withValues(alpha: 0.04),
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: primary
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.white.withValues(alpha: 0.06),
            ),
            boxShadow: primary
                ? <BoxShadow>[
                    BoxShadow(
                      color: kViolet.withValues(alpha: 0.24),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                size: 18,
                color: kText.withValues(alpha: onTap == null ? 0.62 : 1),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: kText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Селектор сервера: строка + плавно разворачивающийся вниз список.
class _ServerDropdown extends StatefulWidget {
  const _ServerDropdown({
    required this.selectedName,
    required this.servers,
    required this.selected,
    required this.expanded,
    required this.maxListHeight,
    required this.pinging,
    required this.pingResults,
    required this.subInfo,
    required this.onToggle,
    required this.onSelect,
    required this.onRefresh,
    required this.onPing,
    required this.onSupport,
  });

  final String selectedName;
  final List<VpnProfile> servers;
  final VpnProfile? selected;
  final bool expanded;
  final double maxListHeight;
  final bool pinging;
  final Map<String, int?> pingResults;
  final SubscriptionInfo? subInfo;
  final VoidCallback? onToggle;
  final ValueChanged<VpnProfile> onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onPing;
  final VoidCallback? onSupport;

  @override
  State<_ServerDropdown> createState() => _ServerDropdownState();
}

class _ServerDropdownState extends State<_ServerDropdown>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: widget.expanded ? 1.0 : 0.0,
  );
  late final Animation<double> _anim = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );

  @override
  void didUpdateWidget(_ServerDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Шкала трафика: заполняется при лимите, цифры по центру шкалы.
  Widget _trafficBar(SubscriptionInfo info) {
    final bool limited = info.total > 0;
    final double frac = limited
        ? (info.used / info.total).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final String text = limited
        ? '${fmtBytes(info.used)} / ${fmtBytes(info.total)}'
        : '${fmtBytes(info.used)} / ∞';

    return Container(
      height: 26,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Stack(
        children: <Widget>[
          // Заполнение шкалы (только при лимите).
          if (limited)
            FractionallySizedBox(
              widthFactor: frac,
              alignment: Alignment.centerLeft,
              child: Container(color: kViolet.withValues(alpha: 0.5)),
            ),
          Center(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: kText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Высота раскрытого списка: по числу серверов, но не больше доступного.
    final double listHeight = (widget.servers.length * 48.0).clamp(
      48.0,
      widget.maxListHeight,
    );

    return Material(
      color: kCard,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Зона 1 — название и переключатель списка.
          Container(
            color: kZone1,
            height: kToggleRowHeight,
            child: InkWell(
              onTap: widget.onToggle,
              splashColor: kViolet.withValues(alpha: 0.14),
              highlightColor: kViolet.withValues(alpha: 0.07),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: <Widget>[
                    RotationTransition(
                      turns: Tween<double>(begin: 0.0, end: 0.5).animate(_anim),
                      child: const Icon(
                        Icons.keyboard_arrow_down,
                        color: kMuted,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.selectedName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16.5,
                          color: kText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _HeaderIcon(
                      icon: Icons.refresh,
                      tooltip: 'Обновить подписку',
                      onTap: widget.onRefresh,
                    ),
                    _HeaderIcon(
                      icon: Icons.speed,
                      tooltip: 'Пинг-тест',
                      busy: widget.pinging,
                      onTap: widget.pinging ? null : widget.onPing,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Зона 2 — шкала трафика и кнопка поддержки.
          if (widget.subInfo != null)
            Container(
              color: kZone2,
              height: kTrafficRowHeight,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: <Widget>[
                  Expanded(child: _trafficBar(widget.subInfo!)),
                  if (widget.onSupport != null) ...<Widget>[
                    const SizedBox(width: 10),
                    _SupportButton(onTap: widget.onSupport!),
                  ],
                ],
              ),
            ),
          // Плавно раскрывающийся список серверов.
          SizeTransition(
            sizeFactor: _anim,
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: listHeight,
              child: Column(
                children: <Widget>[
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: widget.servers.length,
                      itemBuilder: (BuildContext context, int i) {
                        final VpnProfile s = widget.servers[i];
                        return _ServerTile(
                          profile: s,
                          selected: s.tag == widget.selected?.tag,
                          pingMs: widget.pingResults[s.tag],
                          pinged: widget.pingResults.containsKey(s.tag),
                          onTap: () => widget.onSelect(s),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Один сервер в списке.
class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.profile,
    required this.selected,
    required this.pingMs,
    required this.pinged,
    required this.onTap,
  });

  final VpnProfile profile;
  final bool selected;
  final int? pingMs; // задержка в мс (null = недоступен)
  final bool pinged; // выполнялся ли пинг для этого сервера
  final VoidCallback onTap;

  // Цвет задержки: зелёный/жёлтый/красный.
  static Color _pingColor(int ms) {
    if (ms < 120) return const Color(0xFF7DFFCF);
    if (ms < 280) return const Color(0xFFFFC868);
    return const Color(0xFFFF6B8A);
  }

  // Отделяет ведущий emoji-флаг от названия сервера.
  // Возвращает (код страны ISO или '', название без флага).
  static (String, String) _splitFlag(String tag) {
    final List<int> runes = tag.runes.toList();
    bool isFlagRune(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;
    if (runes.length >= 2 && isFlagRune(runes[0]) && isFlagRune(runes[1])) {
      // Региональные индикаторы → буквы кода страны.
      final String code =
          String.fromCharCode(runes[0] - 0x1F1E6 + 0x61) +
          String.fromCharCode(runes[1] - 0x1F1E6 + 0x61);
      final String name = String.fromCharCodes(runes.skip(2)).trim();
      return (code, name.isEmpty ? tag : name);
    }
    return ('', tag);
  }

  // Строка протокола: VLESS / TCP / REALITY.
  static String _protocolLine(VpnProfile p) {
    final List<String> parts = <String>[
      p.protocol.wireValue.toUpperCase(),
      p.transport.wireValue.toUpperCase(),
    ];
    final String? reality = p.tls.realityPublicKey;
    if (reality != null && reality.isNotEmpty) {
      parts.add('REALITY');
    } else if (p.tls.enabled) {
      parts.add('TLS');
    }
    return parts.join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    final (String code, String name) = _splitFlag(profile.tag);

    return InkWell(
      onTap: onTap,
      splashColor: kViolet.withValues(alpha: 0.14),
      highlightColor: kViolet.withValues(alpha: 0.07),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? kViolet.withValues(alpha: 0.12) : null,
          border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
          ),
        ),
        child: Row(
          children: <Widget>[
            // Флаг страны — картинка со скруглением.
            SizedBox(
              width: 31,
              height: 31,
              child: code.isEmpty
                  ? Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(Icons.public, color: kMuted, size: 18),
                    )
                  : Flag.fromString(
                      code,
                      flagSize: FlagSize.size_1x1,
                      fit: BoxFit.cover,
                      borderRadius: 9,
                      replacement: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Icon(
                          Icons.public,
                          color: kMuted,
                          size: 18,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: kText,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    _protocolLine(profile),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 0.5,
                      color: kMuted.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
            // Результат пинга.
            if (pinged) ...<Widget>[
              const SizedBox(width: 8),
              Text(
                pingMs != null ? '$pingMs мс' : '—',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: pingMs != null
                      ? _pingColor(pingMs!)
                      : const Color(0xFFFF6B8A),
                ),
              ),
            ],
            const SizedBox(width: 8),
            if (selected)
              const Icon(Icons.check_circle, color: kViolet, size: 22)
            else
              Icon(
                Icons.chevron_right,
                color: kMuted.withValues(alpha: 0.6),
                size: 22,
              ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionCabinetCard extends StatelessWidget {
  const _SubscriptionCabinetCard({
    required this.dotColor,
    required this.statusText,
    required this.serversText,
    required this.subscriptionUrl,
    required this.showDevices,
    required this.devicesExpanded,
    required this.onDevicesToggle,
    required this.onManageDevices,
    required this.onBotTap,
    this.deviceLimitText,
    this.expireText,
    this.title,
  });

  final Color dotColor;
  final String statusText;
  final String? expireText;
  final String serversText;
  final String? subscriptionUrl;
  final bool showDevices;
  final bool devicesExpanded;
  final String? deviceLimitText;
  final VoidCallback onDevicesToggle;
  final VoidCallback onManageDevices;
  final VoidCallback? onBotTap;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1A1A2E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: dotColor.withValues(alpha: 0.55),
                      blurRadius: 10,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: kText,
                  ),
                ),
              ),
              if (onBotTap != null) ...<Widget>[
                const SizedBox(width: 10),
                _BotPillButton(onTap: onBotTap!),
              ],
            ],
          ),
          if (title != null && title!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              title!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: kMuted),
            ),
          ],
          const SizedBox(height: 18),
          Wrap(
            spacing: 24,
            runSpacing: 14,
            children: <Widget>[
              if (expireText != null)
                _CabinetMeta(label: 'До', value: expireText!),
              _CabinetMeta(label: 'Серверов', value: serversText),
            ],
          ),
          if (subscriptionUrl != null &&
              subscriptionUrl!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 18),
            Container(height: 1, color: const Color(0xFF131320)),
            const SizedBox(height: 16),
            const Text(
              'Ключ подписки',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
                color: Color(0xFF3A3A58),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: Container(
                    height: 40,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0A12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF1A1A28)),
                    ),
                    child: Text(
                      subscriptionUrl!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF8878E8),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: const Color(0xFF111118),
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    onTap: () async {
                      await Clipboard.setData(
                        ClipboardData(text: subscriptionUrl!),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Ссылка скопирована')),
                      );
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF1A1A28)),
                      ),
                      child: const Icon(
                        Icons.copy,
                        size: 18,
                        color: Color(0xFF5A5A80),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (showDevices)
            _SubscriptionDevicesSection(
              expanded: devicesExpanded,
              deviceLimitText: deviceLimitText,
              onToggle: onDevicesToggle,
              onManageDevices: onManageDevices,
            ),
        ],
      ),
    );
  }
}

class _SubscriptionDevicesSection extends StatelessWidget {
  const _SubscriptionDevicesSection({
    required this.expanded,
    required this.onToggle,
    required this.onManageDevices,
    this.deviceLimitText,
  });

  final bool expanded;
  final String? deviceLimitText;
  final VoidCallback onToggle;
  final VoidCallback onManageDevices;

  @override
  Widget build(BuildContext context) {
    final String countText = deviceLimitText != null
        ? 'до $deviceLimitText'
        : 'сайт';

    return Column(
      children: <Widget>[
        const SizedBox(height: 18),
        Container(height: 1, color: const Color(0xFF131320)),
        const SizedBox(height: 14),
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Подключённые устройства',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF8080A8),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: kViolet.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: kViolet.withValues(alpha: 0.28),
                      ),
                    ),
                    child: Text(
                      countText,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFA78BFA),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: const Icon(
                      Icons.keyboard_arrow_down,
                      color: Color(0xFF4A4A68),
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              children: <Widget>[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0A14),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF14142A)),
                  ),
                  child: const Row(
                    children: <Widget>[
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0xFF14142A),
                            borderRadius: BorderRadius.all(Radius.circular(9)),
                          ),
                          child: Icon(
                            Icons.devices,
                            size: 20,
                            color: Color(0xFF9D6EF8),
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Управление устройствами',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFD0D0E8),
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Полный список и отключение доступны в кабинете',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.25,
                                color: Color(0xFF4A4A68),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 38,
                  child: OutlinedButton.icon(
                    onPressed: onManageDevices,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Управлять на сайте'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFA78BFA),
                      side: const BorderSide(color: Color(0xFF2A1854)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          crossFadeState: expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 180),
          firstCurve: Curves.easeOut,
          secondCurve: Curves.easeOut,
          sizeCurve: Curves.easeOut,
        ),
      ],
    );
  }
}

class _BotPillButton extends StatelessWidget {
  const _BotPillButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kViolet.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: kViolet.withValues(alpha: 0.32)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.support_agent, size: 15, color: Color(0xFFA78BFA)),
              SizedBox(width: 5),
              Text(
                'Бот',
                style: TextStyle(
                  color: Color(0xFFD8CCFF),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CabinetMeta extends StatelessWidget {
  const _CabinetMeta({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.9,
              color: Color(0xFF3A3A58),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: kText,
            ),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionHint extends StatelessWidget {
  const _SubscriptionHint({
    required this.icon,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A1854)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: const Color(0xFFA78BFA), size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    color: kText,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: const TextStyle(
                    color: Color(0xFF4A4A68),
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OpenStoreButton extends StatelessWidget {
  const _OpenStoreButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: const Color(0xFF111118),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2A1854)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.open_in_new, size: 17, color: Color(0xFFA78BFA)),
                SizedBox(width: 8),
                Text(
                  'Открыть сайт',
                  style: TextStyle(
                    color: Color(0xFFD8CCFF),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
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

class _PlanTile extends StatefulWidget {
  const _PlanTile({
    required this.name,
    required this.details,
    required this.price,
    required this.onTap,
    this.highlighted = false,
  });

  final String name;
  final String details;
  final String price;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  State<_PlanTile> createState() => _PlanTileState();
}

class _PlanTileState extends State<_PlanTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _borderSpin;

  @override
  void initState() {
    super.initState();
    _borderSpin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    if (widget.highlighted) _borderSpin.repeat();
  }

  @override
  void didUpdateWidget(_PlanTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlighted && !_borderSpin.isAnimating) {
      _borderSpin.repeat();
    } else if (!widget.highlighted && _borderSpin.isAnimating) {
      _borderSpin.stop();
    }
  }

  @override
  void dispose() {
    _borderSpin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final BoxShadow buttonShadow = widget.highlighted
        ? BoxShadow(
            color: Colors.white.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 6),
          )
        : BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 12,
            offset: const Offset(0, 5),
          );

    final Widget content = Material(
      color: const Color(0xFF0B0B14),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 112),
          padding: const EdgeInsets.fromLTRB(18, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: widget.highlighted
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Color(0xFF10101D), Color(0xFF090912)],
                  )
                : null,
            border: widget.highlighted
                ? null
                : Border.all(color: const Color(0xFF1A1A2E)),
            boxShadow: widget.highlighted
                ? <BoxShadow>[
                    BoxShadow(
                      color: kViolet.withValues(alpha: 0.12),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.34),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.24),
                      blurRadius: 14,
                      offset: const Offset(0, 7),
                    ),
                  ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kText,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  if (widget.highlighted) ...<Widget>[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: kViolet.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: kViolet.withValues(alpha: 0.34),
                        ),
                      ),
                      child: const Text(
                        'Популярный',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFFA78BFA),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                widget.details,
                style: const TextStyle(
                  color: Color(0xFF4A4A68),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Text(
                    widget.price,
                    style: const TextStyle(
                      color: kText,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 112,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: widget.highlighted
                          ? const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: <Color>[Colors.white, Color(0xFFF1F1F8)],
                            )
                          : const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: <Color>[
                                Color(0xFF11111C),
                                Color(0xFF0B0B13),
                              ],
                            ),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: widget.highlighted
                            ? Colors.white
                            : const Color(0xFF1E1E30),
                      ),
                      boxShadow: <BoxShadow>[buttonShadow],
                    ),
                    child: Text(
                      'Купить',
                      style: TextStyle(
                        color: widget.highlighted
                            ? const Color(0xFF111111)
                            : kMuted,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (!widget.highlighted) return content;

    return AnimatedBuilder(
      animation: _borderSpin,
      builder: (BuildContext context, Widget? child) {
        return Container(
          padding: const EdgeInsets.all(1.4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13.4),
            gradient: SweepGradient(
              transform: GradientRotation(_borderSpin.value * pi * 2),
              colors: <Color>[
                kViolet.withValues(alpha: 0.9),
                const Color(0xFFB991FF),
                const Color(0xFFA78BFA),
                kViolet.withValues(alpha: 0.9),
                const Color(0xFF7B2CFF),
                kViolet.withValues(alpha: 0.9),
              ],
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: kViolet.withValues(alpha: 0.45),
                blurRadius: 28,
                spreadRadius: 1.5,
              ),
              BoxShadow(
                color: kViolet.withValues(alpha: 0.2),
                blurRadius: 44,
                spreadRadius: 4,
              ),
            ],
          ),
          child: child,
        );
      },
      child: content,
    );
  }
}

// Главная кнопка подключения: многослойная, с объёмными кольцами.
class _ConnectButton extends StatefulWidget {
  const _ConnectButton({
    required this.connected,
    required this.busy,
    required this.statusLabel,
    required this.sessionTime,
    required this.onTap,
  });

  final bool connected;
  final bool busy;
  final String? statusLabel;
  final String? sessionTime;
  final VoidCallback onTap;

  @override
  State<_ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<_ConnectButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);
  double _activity = 0.0;

  @override
  void initState() {
    super.initState();
    _activity = (widget.connected || widget.busy) ? 1.0 : 0.0;
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool connected = widget.connected;
    final bool busy = widget.busy;
    final bool active = connected || busy;

    return GestureDetector(
      onTap: busy ? null : widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: _activity, end: active ? 1.0 : 0.0),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        onEnd: () => _activity = active ? 1.0 : 0.0,
        builder: (BuildContext context, double activity, Widget? child) {
          return AnimatedBuilder(
            animation: _pulse,
            builder: (BuildContext context, Widget? child) {
              final double t = _pulse.value * activity;

              return SizedBox(
                width: 250,
                height: 250,
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    Container(
                      width: 210,
                      height: 210,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const RadialGradient(
                          center: Alignment(-0.4, -0.5),
                          colors: <Color>[Color(0xFF221D37), Color(0xFF131120)],
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.6),
                            blurRadius: 36,
                            offset: const Offset(0, 20),
                          ),
                          BoxShadow(
                            color: kViolet.withValues(alpha: 0.14 + 0.28 * t),
                            blurRadius: 42 + 26 * t,
                            spreadRadius: 2 + 2 * t,
                          ),
                        ],
                      ),
                    ),
                    CustomPaint(
                      size: const Size(210, 210),
                      painter: _RingPainter(brightness: 0.62 + 0.46 * t),
                    ),
                    Container(
                      width: 172,
                      height: 172,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const RadialGradient(
                          center: Alignment(-0.4, -0.5),
                          colors: <Color>[Color(0xFF2C2747), Color(0xFF1A1730)],
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            blurRadius: 14,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 132,
                      height: 132,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: connected
                            ? const RadialGradient(
                                radius: 0.95,
                                colors: <Color>[
                                  Color(0xFF7E44D6),
                                  Color(0xFF45209A),
                                ],
                              )
                            : const RadialGradient(
                                center: Alignment(-0.35, -0.45),
                                colors: <Color>[
                                  Color(0xFF302A4E),
                                  Color(0xFF1E1A33),
                                ],
                              ),
                        boxShadow: connected
                            ? <BoxShadow>[
                                BoxShadow(
                                  color: kViolet.withValues(
                                    alpha: 0.42 + 0.28 * t,
                                  ),
                                  blurRadius: 22 + 14 * t,
                                  spreadRadius: 1 + 1.5 * t,
                                ),
                              ]
                            : null,
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              Icons.power_settings_new,
                              size: 44,
                              color: connected
                                  ? Colors.white
                                  : const Color(0xFF6E6796),
                            ),
                            if (active) ...<Widget>[
                              const SizedBox(height: 2),
                              Text(
                                widget.statusLabel ??
                                    (busy ? 'ПОДКЛЮЧЕНИЕ' : 'ПОДКЛЮЧЕН'),
                                style: TextStyle(
                                  fontSize: 9.5,
                                  letterSpacing: 1.4,
                                  fontWeight: FontWeight.w600,
                                  color: connected
                                      ? Colors.white.withValues(alpha: 0.88)
                                      : kMuted,
                                ),
                              ),
                            ],
                            if (connected && widget.sessionTime != null) ...[
                              const SizedBox(height: 1),
                              Text(
                                widget.sessionTime!,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.brightness});

  final double brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = size.width / 2 - 1.2;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..shader = SweepGradient(
        colors: <Color>[
          kViolet.withValues(alpha: 0.05),
          kViolet.withValues(alpha: 0.45 * brightness),
          const Color(0xFFCBB6FF).withValues(alpha: 0.55 * brightness),
          kViolet.withValues(alpha: 0.45 * brightness),
          kViolet.withValues(alpha: 0.05),
        ],
        stops: const <double>[0.0, 0.25, 0.5, 0.75, 1.0],
      ).createShader(rect);
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.brightness != brightness;
}
