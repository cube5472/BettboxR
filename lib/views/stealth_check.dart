import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/config/general.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:intl/intl.dart' show DateFormat;

/// Экран «Стелс-проверка»: приложение смотрит на себя глазами детектора VPN —
/// локальные порты, tun-интерфейс, TRANSPORT_VPN, DNS, DoT (Quad9), IPv6
/// и выходной IP.
class StealthCheckView extends ConsumerStatefulWidget {
  const StealthCheckView({super.key});

  @override
  ConsumerState<StealthCheckView> createState() => _StealthCheckViewState();
}

class _StealthCheckViewState extends ConsumerState<StealthCheckView> {
  static const _ok = 'ok';
  static const _warn = 'warn';
  static const _bad = 'bad';
  static const _fail = 'fail';
  static const _running = 'running';

  bool _isRunning = false;
  bool _hasRun = false;
  DateTime? _lastRun;

  String? _vPorts;
  String? _vTun;
  String? _vVpnNet;
  String? _vDns;
  String? _vIpv6;
  String? _vExit;
  String? _vDot;

  String _portsBad = '';
  String _tunNames = '';
  String _dnsIp = '';
  String _exitInfo = '';
  bool _ipv6NoV6 = false;
  bool _hasGlobalIpv6 = false;
  bool _systemOk = false;
  List<String> _physicalDns = const [];
  String _dnsError = '';
  String _exitError = '';
  String _netError = '';
  String _dotInfo = '';

  Future<void> _handleEnableVpn() async {
    try {
      await globalState.appController.updateStatus(true);
    } catch (e) {
      commonPrint.log('stealth check: enable vpn failed: $e');
    }
  }

  void _openGeneralSettings() {
    showExtend(
      context,
      builder: (_, type) => AdaptiveSheetScaffold(
        type: type,
        title: appLocalizations.general,
        body: generateListView(generalItems),
      ),
    );
  }

  Future<void> _run() async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _dnsError = '';
      _exitError = '';
      _netError = '';
      _dotInfo = '';
      _vPorts = _running;
      _vTun = _running;
      _vVpnNet = _running;
      _vDns = _running;
      _vIpv6 = _running;
      _vExit = _running;
      _vDot = _running;
    });
    await _checkPorts();
    await _checkSystem();
    await _probeBaseline();
    await _checkDns();
    await _checkDot();
    _checkIpv6();
    await _checkExit();
    if (!mounted) return;
    setState(() {
      _isRunning = false;
      _hasRun = true;
      _lastRun = DateTime.now();
    });
  }

  /// Детекторы первым делом стучатся на типичные порты прокси на localhost.
  Future<void> _checkPorts() async {
    final cfg = ref.read(patchClashConfigProvider);
    final ports = <int>{7890, 7891, 7892, 7893, 1080, 8080, 8888, 9090, 9091};
    if (cfg.mixedPort > 0) {
      ports.add(cfg.mixedPort);
    }
    final active = <int>[];
    for (final port in ports) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 700),
        );
        socket.destroy();
        active.add(port);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _vPorts = active.isEmpty ? _ok : _bad;
      _portsBad = active.join(', ');
    });
  }

  /// tun-интерфейс, TRANSPORT_VPN и DNS физической сети — через Kotlin-движок.
  /// Экран живёт в UI-процессе, где глобальный `vpn` равен null (геттер
  /// выдаёт объект только в сервисном движке), поэтому зовём канал 'vpn'
  /// напрямую: VpnPlugin прицепляется и к движку активити
  /// (configureFlutterEngine в MainActivity), а handleStealthCheck
  /// использует лишь системные API — привязка к VPN-сервису ему не нужна.
  Future<void> _checkSystem() async {
    Map<String, dynamic>? data;
    try {
      data = await const MethodChannel('vpn').invokeMapMethod<String, dynamic>(
        'stealthCheck',
      );
    } catch (e) {
      commonPrint.log('stealth check: system channel failed: $e');
    }
    // Страховка: если канал недоступен, сам tun-интерфейс всё равно виден
    // средствами Dart — таблица интерфейсов ядра общая для всех процессов.
    var dartTuns = const <String>[];
    if (data == null) {
      try {
        dartTuns = (await NetworkInterface.list())
            .map((item) => item.name)
            .where(
              (name) => name.startsWith('tun') || name.startsWith('ppp'),
            )
            .toSet()
            .toList();
      } catch (e) {
        commonPrint.log('stealth check: dart tun lookup failed: $e');
      }
    }
    final tunList = data?['tunInterfaces'];
    final tunNames = tunList is List
        ? tunList
              .map((item) => item.toString())
              .where((item) => item.isNotEmpty)
              .join(', ')
        : '';
    final isVpnNetwork = data?['isVpnNetwork'] == true;
    final hasGlobalIpv6 = data?['hasGlobalIpv6'] == true;
    final dnsList = data?['physicalDns'];
    final physicalDns = dnsList is List
        ? dnsList
              .map((item) => item.toString())
              .where((item) => item.isNotEmpty)
              .toList()
        : <String>[];
    _physicalDns = physicalDns;
    _hasGlobalIpv6 = hasGlobalIpv6;
    _systemOk = data != null;
    if (!mounted) return;
    setState(() {
      _tunNames = tunNames.isNotEmpty ? tunNames : dartTuns.join(', ');
      _vTun = data != null || dartTuns.isNotEmpty ? _warn : _fail;
      _vVpnNet = data == null ? _fail : (isVpnNetwork ? _warn : _ok);
    });
  }

  /// GET с таймаутами; [proxyPort] — локальный микс-порт mihomo: через CONNECT
  /// запрос идёт мимо tun-слоя (fake-ip, v6, системный DNS) прямо в ядро.
  Future<String> _fetchUrl(
    String url, {
    int? proxyPort,
    bool dnsJson = false,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);
    if (proxyPort != null && proxyPort > 0) {
      client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    } else {
      // BettboxHttpOverrides (main.dart) навязывает всем HttpClient приложения
      // 'PROXY localhost:<mixedPort>' — при порте 0 это коннект к :0 и
      // «Connection refused localhost:<эфемерный>» в отчёте. Прямой маршрут
      // должен быть прямым: отключаем навязанный прокси явно.
      client.findProxy = (_) => 'DIRECT';
    }
    try {
      final request = await client.getUrl(Uri.parse(url));
      if (dnsJson) {
        request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException('http ${response.statusCode}', uri: Uri.parse(url));
      }
      return body;
    } finally {
      client.close();
    }
  }

  /// Сначала в микс-порт ядра (если слушает), затем обычный путь через tun.
  /// Возвращает (тело, сводка маршрутов) — сводка идёт в отчёт при неудаче.
  Future<(String?, String)> _fetchViaTunnel(
    String url, {
    bool dnsJson = false,
  }) async {
    final port = ref.read(patchClashConfigProvider).mixedPort;
    final notes = <String>[];
    if (port > 0) {
      try {
        return (
          await _fetchUrl(url, proxyPort: port, dnsJson: dnsJson),
          'proxy:$port ok',
        );
      } catch (e) {
        commonPrint.log('stealth check: proxy 127.0.0.1:$port failed: $e');
        notes.add('proxy:$port ${_shortError(e.toString())}');
      }
    } else {
      notes.add('proxy off');
    }
    try {
      return (await _fetchUrl(url, dnsJson: dnsJson), 'direct ok');
    } catch (e) {
      commonPrint.log('stealth check: direct failed: $e');
      notes.add('direct: ${_shortError(e.toString())}');
      return (null, notes.join(' | '));
    }
  }

  String _shortError(String text, [int max = 110]) {
    final clean = text
        .replaceFirst(RegExp(r'^[A-Za-z]+Exception:\s*'), '')
        .replaceAll('\n', ' ')
        .trim();
    return clean.length <= max ? clean : clean.substring(0, max);
  }

  /// Базовая проба сети: TCP на IP-литерал отделяет «нет маршрута/сети»
  /// от «сломан DNS» — без имён и без участия туннельного стека имён.
  Future<void> _probeBaseline() async {
    final parts = <String>[];
    try {
      final socket = await Socket.connect(
        InternetAddress('1.1.1.1'),
        443,
        timeout: const Duration(seconds: 4),
      );
      socket.destroy();
      parts.add('tcp 1.1.1.1:443 ok');
    } catch (e) {
      parts.add('tcp 1.1.1.1:443 fail: ${_shortError(e.toString())}');
    }
    try {
      final list = await InternetAddress.lookup(
        'ipinfo.io',
        type: InternetAddressType.IPv4,
      );
      final ips = list.map((item) => item.address).take(2).join(',');
      parts.add('dns lookup ok: $ips');
    } catch (e) {
      parts.add('dns lookup fail: ${_shortError(e.toString())}');
    }
    if (!mounted) return;
    setState(() {
      _netError = parts.join(' | ');
    });
  }

  /// Резолвер-эхо через туннель: если виден DNS физической сети — утечка.
  /// whoami.cloudflare публичный DoH-JSON отвечает NXDOMAIN (Status 3, зона
  /// не входит в глобальное дерево), поэтому три эхо-имени: A-запись
  /// whoami.akamai.net (data = IP резолвера), TXT whoami.ds.akahelp.net
  /// («ip» «x.x.x.x») и классический whoami.cloudflare TXT (ip=x.x.x.x).
  Future<void> _checkDns() async {
    final errors = <String>[];
    const endpoints = [
      ('https://cloudflare-dns.com/dns-query', 'cloudflare-dns.com'),
      ('https://dns.google/resolve', 'dns.google'),
    ];
    const probes = [
      ('whoami.akamai.net', 'A'),
      ('whoami.ds.akahelp.net', 'TXT'),
      ('whoami.cloudflare', 'TXT'),
    ];
    final regPlain = RegExp(r'ip=([0-9a-fA-F:.]+)');
    final regQuoted = RegExp(r'"ip"\s+"([0-9a-fA-F:.]+)"');
    for (final (base, host) in endpoints) {
      for (final (name, type) in probes) {
        final (body, routeInfo) = await _fetchViaTunnel(
          '$base?name=$name&type=$type',
          dnsJson: true,
        );
        if (body == null || body.isEmpty) {
          errors.add('$host $name/$type: $routeInfo');
          continue;
        }
        final resolverIps = <String>[];
        var status = -1;
        try {
          final map = json.decode(body) as Map<String, dynamic>;
          status = (map['Status'] as num?)?.toInt() ?? -1;
          final answers = map['Answer'] as List?;
          if (answers != null) {
            for (final answer in answers) {
              if (answer is! Map) continue;
              final dataStr = answer['data']?.toString() ?? '';
              final candidates = [
                ...regPlain.allMatches(dataStr).map((m) => m.group(1)),
                ...regQuoted.allMatches(dataStr).map((m) => m.group(1)),
              ];
              // A/AAAA-ответ: data — сам IP-литерал резолвера.
              final recordType = (answer['type'] as num?)?.toInt() ?? 0;
              if (recordType == 1 || recordType == 28) {
                candidates.add(dataStr.replaceAll('"', '').trim());
              }
              for (final ip in candidates) {
                if (ip == null) continue;
                if (InternetAddress.tryParse(ip) == null) continue;
                if (!resolverIps.contains(ip)) resolverIps.add(ip);
              }
            }
          }
        } catch (e) {
          errors.add('$host $name/$type: ${_shortError(e.toString())}');
          continue;
        }
        if (resolverIps.isEmpty) {
          errors.add('$host $name/$type: no answer (status $status)');
          continue;
        }
        final leaked = _physicalDns.any(resolverIps.contains);
        if (!mounted) return;
        setState(() {
          _vDns = leaked ? _bad : _ok;
          _dnsIp = resolverIps.take(2).join(', ');
          _dnsError = '';
        });
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _vDns = _fail;
      _dnsIp = '';
      _dnsError = errors.join(' | ');
    });
  }

  /// DoT-проба по Quad9: живая DNS-over-TLS-сессия — TCP 853, TLS с проверкой
  /// сертификата и настоящий DNS-обмен в wire-формате. В отличие от DoH-пробы
  /// выше здесь проверяется именно транспорт :853, который чаще всего душат
  /// операторы и сети. Как базовая TCP-проба, идёт системным маршрутом: при
  /// активном VPN это путь через tun и ноду — ровно то, что доступно клиентам.
  Future<void> _checkDot() async {
    var info = '';
    try {
      final (ms, byIp) = await _dotProbe();
      info = '${byIp ? '9.9.9.9' : 'dns.quad9.net'}:853 · $ms ms';
    } catch (e) {
      info = _shortError(e.toString());
    }
    if (!mounted) return;
    setState(() {
      _vDot = info.isEmpty ? _bad : _ok;
      _dotInfo = info;
    });
  }

  /// TLS-соединение до Quad9: сначала по имени (SNI и проверка сертификата —
  /// dns.quad9.net), при «Failed host lookup» — по IP-литералу 9.9.9.9, чтобы
  /// проба мерила именно DoT-транспорт, а не упиралась в сломанный DNS.
  /// Возвращает (сокет, подключение по IP).
  Future<(SecureSocket, bool)> _dotConnect() async {
    try {
      return (
        await SecureSocket.connect(
          'dns.quad9.net',
          853,
        ).timeout(const Duration(seconds: 6)),
        false,
      );
    } on SocketException catch (e) {
      if (!e.message.contains('Failed host lookup')) rethrow;
    }
    try {
      return (
        await SecureSocket.connect(
          InternetAddress('9.9.9.9'),
          853,
        ).timeout(const Duration(seconds: 6)),
        true,
      );
    } catch (e) {
      throw SocketException(
        'name lookup failed; 9.9.9.9:853: ${_shortError(e.toString())}',
      );
    }
  }

  /// Одна DoT-сессия; возвращает (длительность полного обмена, мс, по IP).
  Future<(int, bool)> _dotProbe() async {
    final sw = Stopwatch()..start();
    final (tls, byIp) = await _dotConnect();
    try {
      await _dotExchange(tls).timeout(const Duration(seconds: 6));
      return (sw.elapsedMilliseconds, byIp);
    } finally {
      tls.destroy();
    }
  }

  /// Отправка A-запроса dns.quad9.net и разбор ответа (RFC 1035 4.2.2 —
  /// 2 байта длины, затем сообщение): совпадение ID, QR=1, RCODE=0, есть
  /// ответы. Любое расхождение — ошибка пробы.
  Future<void> _dotExchange(SecureSocket tls) async {
    final id = DateTime.now().microsecondsSinceEpoch & 0xFFFF;
    tls.add(_buildDotQuery(id));
    final buffer = <int>[];
    await for (final chunk in tls) {
      buffer.addAll(chunk);
      if (buffer.length < 2) continue;
      final len = (buffer[0] << 8) | buffer[1];
      if (len < 12 || len > 4096) {
        throw SocketException('dns: bad message length $len');
      }
      if (buffer.length >= 2 + len) break;
    }
    if (buffer.length < 14) {
      throw const SocketException('dns: connection closed early');
    }
    final len = (buffer[0] << 8) | buffer[1];
    if (buffer.length < 2 + len) {
      throw const SocketException('dns: connection closed early');
    }
    if (((buffer[2] << 8) | buffer[3]) != id) {
      throw const SocketException('dns: id mismatch');
    }
    if ((buffer[4] & 0x80) == 0) {
      throw const SocketException('dns: not a response');
    }
    final rcode = buffer[5] & 0x0F;
    if (rcode != 0) {
      throw SocketException('dns: rcode $rcode');
    }
    final ancount = (buffer[8] << 8) | buffer[9];
    if (ancount == 0) {
      throw const SocketException('dns: no answer records');
    }
  }

  /// Wire-формат запроса: A dns.quad9.net, класс IN, рекурсия желательна.
  List<int> _buildDotQuery(int id) {
    final qname = <int>[];
    for (final label in const ['dns', 'quad9', 'net']) {
      qname
        ..add(label.length)
        ..addAll(ascii.encode(label));
    }
    return <int>[
      (id >> 8) & 0xFF,
      id & 0xFF, // ID
      0x01, 0x00, // флаги: RD=1
      0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // QDCOUNT=1
      ...qname,
      0x00, // конец QNAME
      0x00, 0x01, // QTYPE=A
      0x00, 0x01, // QCLASS=IN
    ];
  }

  /// IPv6: если в физической сети есть глобальный v6, а туннель его не
  /// покрывает — часть трафика может уходить мимо VPN.
  void _checkIpv6() {
    final cfg = ref.read(patchClashConfigProvider);
    if (!mounted) return;
    setState(() {
      if (!_systemOk) {
        _ipv6NoV6 = false;
        _vIpv6 = _fail;
      } else if (!_hasGlobalIpv6) {
        _ipv6NoV6 = true;
        _vIpv6 = _ok;
      } else if (cfg.ipv6) {
        _ipv6NoV6 = false;
        _vIpv6 = _ok;
      } else {
        _ipv6NoV6 = false;
        _vIpv6 = _bad;
      }
    });
  }

  /// Что видит внешний мир: IP, страна и ASN узла выхода.
  Future<void> _checkExit() async {
    var ok = false;
    var info = '';
    final errors = <String>[];
    const endpoints = [
      'https://ipinfo.io/json',
      'https://api.ip.sb/geoip',
      'https://api.ipify.org',
    ];
    for (final endpoint in endpoints) {
      final (body, routeInfo) = await _fetchViaTunnel(endpoint);
      if (body == null || body.isEmpty) {
        errors.add('${Uri.parse(endpoint).host}: $routeInfo');
        continue;
      }
      try {
        final trimmed = body.trim();
        var ip = '';
        var country = '';
        var city = '';
        var org = '';
        if (trimmed.startsWith('{')) {
          final map = json.decode(trimmed) as Map<String, dynamic>;
          ip = map['ip']?.toString() ?? '';
          country = map['country']?.toString() ?? '';
          city = map['city']?.toString() ?? '';
          org = map['org']?.toString() ?? '';
          if (org.isEmpty) {
            org = map['organization']?.toString() ?? '';
          }
        } else {
          ip = trimmed;
        }
        if (ip.isEmpty) {
          errors.add('${Uri.parse(endpoint).host}: no ip in answer');
          continue;
        }
        ok = true;
        final geo = [city, country].where((item) => item.isNotEmpty).join(', ');
        final parts = <String>[ip];
        if (geo.isNotEmpty) {
          parts.add(geo);
        }
        if (org.isNotEmpty) {
          parts.add(org);
        }
        info = parts.join(' · ');
        break;
      } catch (e) {
        errors.add('${Uri.parse(endpoint).host}: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      _vExit = ok ? _ok : _fail;
      _exitInfo = info;
      _exitError = ok ? '' : errors.join(' | ');
    });
  }

  String _portsSubtitle() {
    switch (_vPorts) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _ok:
        return appLocalizations.stealthPortsOk;
      case _bad:
        return appLocalizations.stealthPortsBad(_portsBad);
    }
    return '';
  }

  String _tunSubtitle() {
    switch (_vTun) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _warn:
        return _tunNames.isNotEmpty
            ? '${appLocalizations.stealthTunWarn} · $_tunNames'
            : appLocalizations.stealthTunWarn;
      case _fail:
        return appLocalizations.stealthCheckFail;
    }
    return '';
  }

  String _vpnNetSubtitle() {
    switch (_vVpnNet) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _warn:
        return appLocalizations.stealthVpnNetWarn;
      case _fail:
        return appLocalizations.stealthCheckFail;
    }
    return '';
  }

  String _dnsSubtitle() {
    switch (_vDns) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _ok:
        return _dnsIp.isNotEmpty
            ? '${appLocalizations.stealthDnsOk} · $_dnsIp'
            : appLocalizations.stealthDnsOk;
      case _bad:
        return appLocalizations.stealthDnsLeak;
      case _fail:
        return appLocalizations.stealthDnsFail;
    }
    return '';
  }

  String _dotSubtitle() {
    switch (_vDot) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _ok:
        return _dotInfo.isNotEmpty
            ? '${appLocalizations.stealthDotOk} · $_dotInfo'
            : appLocalizations.stealthDotOk;
      case _bad:
        return _dotInfo.isNotEmpty
            ? '${appLocalizations.stealthDotBad} · $_dotInfo'
            : appLocalizations.stealthDotBad;
      case _fail:
        return appLocalizations.stealthCheckFail;
    }
    return '';
  }

  String _ipv6Subtitle() {
    switch (_vIpv6) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _ok:
        return _ipv6NoV6
            ? appLocalizations.stealthIpv6OkNoV6
            : appLocalizations.stealthIpv6OkCovered;
      case _bad:
        return appLocalizations.stealthIpv6Bad;
      case _fail:
        return appLocalizations.stealthCheckFail;
    }
    return '';
  }

  String _exitSubtitle() {
    switch (_vExit) {
      case _running:
        return appLocalizations.stealthCheckChecking;
      case _ok:
        return _exitInfo.isNotEmpty
            ? '${appLocalizations.stealthExitOk} · $_exitInfo'
            : appLocalizations.stealthExitOk;
      case _fail:
        return appLocalizations.stealthExitFail;
    }
    return '';
  }

  String _marker(String? verdict) {
    switch (verdict) {
      case _ok:
        return '[OK]';
      case _warn:
        return '[!]';
      case _bad:
        return '[X]';
      default:
        return '[?]';
    }
  }

  String _buildReport() {
    final buffer = StringBuffer('BettboxR · ${appLocalizations.stealthCheck}');
    if (_lastRun != null) {
      buffer.write(
        '\n${appLocalizations.stealthCheckedAt(DateFormat('HH:mm').format(_lastRun!))}',
      );
    }
    void addRow(String title, String subtitle, String? verdict) {
      buffer.write('\n${_marker(verdict)} $title');
      if (subtitle.isNotEmpty) {
        buffer.write(' — $subtitle');
      }
    }

    addRow(appLocalizations.stealthPortsTitle, _portsSubtitle(), _vPorts);
    addRow(appLocalizations.stealthTunTitle, _tunSubtitle(), _vTun);
    addRow(appLocalizations.stealthVpnNetTitle, _vpnNetSubtitle(), _vVpnNet);
    addRow(appLocalizations.stealthDnsTitle, _dnsSubtitle(), _vDns);
    addRow(appLocalizations.stealthDotTitle, _dotSubtitle(), _vDot);
    addRow('IPv6', _ipv6Subtitle(), _vIpv6);
    addRow(appLocalizations.stealthExitTitle, _exitSubtitle(), _vExit);
    final techNotes = <String>[];
    if (_dnsError.isNotEmpty || _exitError.isNotEmpty) {
      techNotes.add('net: ${_cropTech(_netError)}');
    }
    if (_dnsError.isNotEmpty) {
      techNotes.add('dns: ${_cropTech(_dnsError)}');
    }
    if (_exitError.isNotEmpty) {
      techNotes.add('exit: ${_cropTech(_exitError)}');
    }
    if (techNotes.isNotEmpty) {
      buffer.write('\n');
      buffer.write(techNotes.join('\n'));
    }
    return buffer.toString();
  }

  String _cropTech(String text, [int max = 220]) {
    final clean = text.replaceAll('\n', ' ').trim();
    return clean.length <= max ? clean : clean.substring(0, max);
  }

  Future<void> _copyReport() async {
    await Clipboard.setData(ClipboardData(text: _buildReport()));
    if (!mounted) return;
    globalState.showNotifier(appLocalizations.copySuccess);
  }

  Widget _divider(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      color: context.colorScheme.outlineVariant.withValues(
        alpha: context.colorScheme.brightness == Brightness.light ? 0.6 : 0.45,
      ),
    );
  }

  Widget _buildRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String? verdict,
    String subtitle = '',
    VoidCallback? onFix,
  }) {
    Widget trailing;
    switch (verdict) {
      case _running:
        trailing = SizedBox(
          width: 18,
          height: 18,
          child: SpinKitThreeBounce(
            color: context.colorScheme.primary,
            size: 12,
          ),
        );
        break;
      case _ok:
        trailing = Icon(
          Icons.check_circle,
          size: 20,
          color: const Color(0xFF4CAF50),
        );
        break;
      case _warn:
        trailing = Icon(
          Icons.warning_amber_rounded,
          size: 20,
          color: const Color(0xFFFFA000),
        );
        break;
      case _bad:
        trailing = Icon(Icons.cancel, size: 20, color: context.colorScheme.error);
        break;
      case _fail:
        trailing = Icon(
          Icons.help_outline,
          size: 20,
          color: context.colorScheme.outline,
        );
        break;
      default:
        trailing = Icon(
          Icons.radio_button_unchecked,
          size: 20,
          color: context.colorScheme.outline,
        );
    }
    if (onFix != null && verdict == _bad) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(onPressed: onFix, child: Text(appLocalizations.stealthFix)),
          const SizedBox(width: 4),
          trailing,
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: context.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: context.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: context.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: context.textTheme.bodySmall?.copyWith(
                      color: context.colorScheme.outline,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }

  Widget _buildNeedVpn(BuildContext context) {
    return CommonCard(
      type: CommonCardType.filled,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              Icons.shield_outlined,
              size: 40,
              color: context.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              appLocalizations.stealthCheckNeedVpn,
              textAlign: TextAlign.center,
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _handleEnableVpn,
              icon: const Icon(Icons.power_settings_new),
              label: Text(appLocalizations.stealthCheckEnableVpn),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    int closed,
    int total,
  ) {
    final stateText = !_hasRun && !_isRunning
        ? appLocalizations.stealthCheckRun
        : _isRunning
        ? appLocalizations.stealthCheckChecking
        : appLocalizations.stealthCheckScore('$closed', '$total');
    return CommonCard(
      type: CommonCardType.filled,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 20,
                  color: context.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(stateText, style: context.textTheme.titleSmall)),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _hasRun && total > 0 ? closed / total : null,
                minHeight: 6,
              ),
            ),
            if (_lastRun != null) ...[
              const SizedBox(height: 8),
              Text(
                appLocalizations.stealthCheckedAt(
                  DateFormat('HH:mm').format(_lastRun!),
                ),
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colorScheme.outline,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _isRunning ? null : _run,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(
                    _hasRun
                        ? appLocalizations.stealthCheckRerun
                        : appLocalizations.stealthCheckRun,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _hasRun && !_isRunning ? _copyReport : null,
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(appLocalizations.stealthCheckCopyReport),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: CommonCard(
        type: CommonCardType.filled,
        child: Column(
          children: [
            _buildRow(
              context,
              icon: Icons.lan_outlined,
              title: appLocalizations.stealthPortsTitle,
              verdict: _vPorts,
              subtitle: _portsSubtitle(),
              onFix: _vPorts == _bad ? _openGeneralSettings : null,
            ),
            _divider(context),
            _buildRow(
              context,
              icon: Icons.swap_vert,
              title: appLocalizations.stealthTunTitle,
              verdict: _vTun,
              subtitle: _tunSubtitle(),
            ),
            _divider(context),
            _buildRow(
              context,
              icon: Icons.vpn_lock_outlined,
              title: appLocalizations.stealthVpnNetTitle,
              verdict: _vVpnNet,
              subtitle: _vpnNetSubtitle(),
            ),
            _divider(context),
            _buildRow(
              context,
              icon: Icons.dns_outlined,
              title: appLocalizations.stealthDnsTitle,
              verdict: _vDns,
              subtitle: _dnsSubtitle(),
            ),
            _divider(context),
            _buildRow(
              context,
              icon: Icons.lock_outline,
              title: appLocalizations.stealthDotTitle,
              verdict: _vDot,
              subtitle: _dotSubtitle(),
            ),
            _divider(context),
            _buildRow(
              context,
              icon: Icons.travel_explore,
              title: 'IPv6',
              verdict: _vIpv6,
              subtitle: _ipv6Subtitle(),
              onFix: _vIpv6 == _bad ? _openGeneralSettings : null,
            ),
            _divider(context),
            _buildRow(
              context,
              icon: Icons.public,
              title: appLocalizations.stealthExitTitle,
              verdict: _vExit,
              subtitle: _exitSubtitle(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected =
        ref.watch(runTimeProvider) != null &&
        !ref.watch(isSmartStoppedProvider);
    if (connected && !_hasRun && !_isRunning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_hasRun && !_isRunning) {
          _run();
        }
      });
    }
    final verdicts = [_vPorts, _vTun, _vVpnNet, _vDns, _vDot, _vIpv6, _vExit];
    final closed = verdicts.where((v) => v == _ok).length;
    // Считаем честно: непроверенные пункты остаются в знаменателе,
    // иначе счётчик рискует показать «3 из 3» при трёх сбоях.
    final total = verdicts.length;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32, top: 4),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: connected
              ? _buildHeader(context, closed, total)
              : _buildNeedVpn(context),
        ),
        const SizedBox(height: 8),
        if (connected) _buildResults(context),
      ],
    );
  }
}
