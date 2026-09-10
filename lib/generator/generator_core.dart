// Ядро генератора BettboxR — порт веб-генератора "РКН ОФФЛАЙН" (index.html).
// Чистый Dart без внешних зависимостей: парсеры ссылок и WG/AWG-конфигов,
// дедупликация, сборка mihomo YAML с собственным детерминированным эмиттером.
import 'dart:convert';
import 'dart:math';

import 'package:yaml/yaml.dart';

import 'generator_data.dart';

// ---------------- JSON-данные ----------------

Map<String, dynamic> _m(String key) =>
    jsonDecode(kGeneratorJson[key]!) as Map<String, dynamic>;

List<dynamic> _l(String key) => jsonDecode(kGeneratorJson[key]!) as List<dynamic>;

final Map<String, dynamic> kDefaultDnsValues = _m('defaultDnsValues');
final Map<String, dynamic> kStaticObj = _m('staticObj');
final Map<String, dynamic> kRuleProvidersDavoyan = _m('ruleProvidersDavoyan');
final Map<String, dynamic> kRuleProvidersLegiz = _m('ruleProvidersLegiz');
final Map<String, dynamic> kRuleProvidersRoscomvpn = _m('ruleProvidersRoscomvpn');
final List<dynamic> kProxyGroups = _l('proxyGroups');
final List<dynamic> kRulesBase = _l('rulesBase');
final List<dynamic> kUnblockRules = _l('unblockRules');
final Map<String, dynamic> kServiceRules = _m('serviceRules');
final Map<String, dynamic> kCdnRules = _m('cdnRules');

final Map<String, Map<String, dynamic>> kProviderSets = {
  'roscomvpn': kRuleProvidersRoscomvpn,
  'davoyan': kRuleProvidersDavoyan,
  'legiz': kRuleProvidersLegiz,
};

final Map<String, String> kPresetLabels = {
  'telegram': 'Telegram',
  'discord': 'Discord',
  'youtube': 'YouTube',
  'ai': 'AI-сервисы',
  'twitter': 'Twitter / X',
  'instagram': 'Instagram',
  'facebook': 'Facebook',
  'whatsapp': 'WhatsApp',
  'ghostline': 'Ghostline (push без блокировок)',
};

final Map<String, String> kCdnLabels = {
  'cloudflare': 'Cloudflare',
  'akamai': 'Akamai',
  'aws': 'Amazon AWS',
  'fastly': 'Fastly',
};

// ---------------- Утилиты ----------------

final Random _random = Random();

String generateRandomPassword([int length = 16]) {
  const charset =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final result = StringBuffer();
  for (var i = 0; i < length; i++) {
    result.write(charset[_random.nextInt(charset.length)]);
  }
  return result.toString();
}

String _randomSuffix([int length = 4]) {
  const charset = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final result = StringBuffer();
  for (var i = 0; i < length; i++) {
    result.write(charset[_random.nextInt(charset.length)]);
  }
  return result.toString();
}

String cleanSni(String? sni) {
  if (sni == null || sni.isEmpty) return '';
  final parts = sni.split(':');
  if (parts.length > 1 && RegExp(r'^\d+$').hasMatch(parts.last)) {
    return parts.sublist(0, parts.length - 1).join(':');
  }
  return sni;
}

/// URLSearchParams-совместимый разбор query ('+' = пробел, %XX декодируется,
/// берётся первое значение ключа).
class QueryMap {
  final Map<String, String> _map = {};
  final Set<String> _keys = {};

  QueryMap(String query) {
    for (final part in query.split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      String rawKey, rawValue;
      if (eq == -1) {
        rawKey = part;
        rawValue = '';
      } else {
        rawKey = part.substring(0, eq);
        rawValue = part.substring(eq + 1);
      }
      final key = _decode(rawKey);
      _keys.add(key);
      if (!_map.containsKey(key)) {
        _map[key] = _decode(rawValue);
      }
    }
  }

  static String _decode(String s) {
    final withSpaces = s.replaceAll('+', ' ');
    try {
      return Uri.decodeComponent(withSpaces);
    } on Object {
      return withSpaces;
    }
  }

  String? get(String key) => _map[key];
  bool has(String key) => _keys.contains(key);
}

String? _decodeFragment(String fragment) {
  if (fragment.isEmpty) return null;
  try {
    return Uri.decodeComponent(fragment);
  } on Object {
    return fragment;
  }
}

Never _throwMissing() => throw Exception('Не хватает данных');

/// Пробует декодировать base64 (стандартный и URL-safe, с паддингом или без).
/// Возвращает null, если строка не является base64.
String? tryDecodeBase64(String input) {
  var s = input.trim().replaceAll(RegExp(r'\s+'), '');
  if (s.isEmpty || s.contains(':')) return null;
  s = s.replaceAll('-', '+').replaceAll('_', '/');
  final pad = (4 - (s.length % 4)) % 4;
  s += '=' * pad;
  try {
    return utf8.decode(base64Decode(s), allowMalformed: true);
  } on Object {
    return null;
  }
}

/// Разбирает "host:port", включая IPv6 вида [::1]:443.
Map<String, dynamic> _parseHostPort(String value) {
  final v = value.trim();
  if (v.startsWith('[')) {
    final m = RegExp(r'^\[(.+)\]:(\d+)$').firstMatch(v);
    if (m != null) {
      return <String, dynamic>{
        'host': m.group(1)!,
        'port': int.parse(m.group(2)!),
      };
    }
    return <String, dynamic>{'host': v, 'port': 0};
  }
  final idx = v.lastIndexOf(':');
  if (idx != -1) {
    final p = int.tryParse(v.substring(idx + 1));
    if (p != null) {
      return <String, dynamic>{'host': v.substring(0, idx), 'port': p};
    }
  }
  return <String, dynamic>{'host': v, 'port': 0};
}

// ---------------- Парсеры ссылок ----------------

Map<String, dynamic> parseVless(String url) {
  final parsed = Uri.parse(url);
  final uuid = parsed.userInfo;
  final host = parsed.host;
  final port = parsed.port;
  final name = _decodeFragment(parsed.fragment) ?? 'VLESS';
  if (uuid.isEmpty || host.isEmpty || port <= 0) _throwMissing();
  final params = QueryMap(parsed.query);
  final proxy = <String, dynamic>{
    'name': name,
    'type': 'vless',
    'server': host,
    'port': port,
    'uuid': uuid,
    'encryption': 'none',
    'flow': params.get('flow') ?? '',
    'client-fingerprint': params.get('fp') ?? 'chrome',
    'network': params.get('type') ?? 'tcp',
    'udp': true,
    'xudp': true,
    'skip-cert-verify': true,
  };
  if (params.get('insecure') == '0' || params.get('allowInsecure') == '0') {
    proxy['skip-cert-verify'] = false;
  }
  final cleanSniValue = cleanSni(params.get('sni') ?? '');
  if (params.get('security') == 'reality') {
    proxy['reality-opts'] = {
      'public-key': params.get('pbk') ?? '',
      'short-id': params.get('sid') ?? '',
    };
    proxy['tls'] = true;
    if (cleanSniValue.isNotEmpty) proxy['servername'] = cleanSniValue;
  } else {
    if (cleanSniValue.isNotEmpty) proxy['servername'] = cleanSniValue;
    if (params.get('security') == 'tls') proxy['tls'] = true;
    if (cleanSniValue.isNotEmpty && !params.has('security')) {
      proxy['tls'] = true;
    }
  }
  if (params.get('type') == 'ws') {
    proxy['network'] = 'ws';
    final wsOpts = <String, dynamic>{};
    final path = params.get('path');
    final wsHost = params.get('host');
    if (path != null) wsOpts['path'] = path;
    if (wsHost != null) wsOpts['headers'] = {'Host': wsHost};
    if (wsOpts.isNotEmpty) proxy['ws-opts'] = wsOpts;
    if (!params.has('alpn')) proxy['alpn'] = ['h2', 'http/1.1'];
  }
  if (params.get('type') == 'grpc' && params.has('path')) {
    proxy['grpc-opts'] = {'grpc-service-name': params.get('path')};
  }
  final alpn = params.get('alpn');
  if (alpn != null) {
    final alpnArr = alpn
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (alpnArr.isNotEmpty) proxy['alpn'] = alpnArr;
  }
  return proxy;
}

Map<String, dynamic> parseTrojan(String url) {
  final parsed = Uri.parse(url);
  var password = parsed.userInfo;
  final host = parsed.host;
  final port = parsed.port;
  final name = _decodeFragment(parsed.fragment) ?? 'Trojan';
  if (host.isEmpty || port <= 0) _throwMissing();
  if (password.isEmpty) password = generateRandomPassword();
  final params = QueryMap(parsed.query);
  final sni = cleanSni(params.get('sni') ?? '');
  final proxy = <String, dynamic>{
    'name': name,
    'type': 'trojan',
    'server': host,
    'port': port,
    'password': password,
    'sni': sni,
    'client-fingerprint': params.get('fp') ?? 'chrome',
    'network': params.get('type') ?? 'tcp',
    'skip-cert-verify': true,
  };
  if (params.get('insecure') == '0' || params.get('allowInsecure') == '0') {
    proxy['skip-cert-verify'] = false;
  }
  if (params.get('security') == 'reality') {
    proxy['reality-opts'] = {
      'public-key': params.get('pbk') ?? '',
      'short-id': params.get('sid') ?? '',
    };
    proxy['tls'] = true;
    if (sni.isNotEmpty) proxy['servername'] = sni;
  } else {
    if (sni.isNotEmpty) {
      proxy['servername'] = sni;
      proxy['tls'] = true;
    }
    if (params.get('security') == 'tls') proxy['tls'] = true;
  }
  if (params.get('type') == 'ws') {
    proxy['network'] = 'ws';
    final wsOpts = <String, dynamic>{};
    final path = params.get('path');
    final wsHost = params.get('host');
    if (path != null) wsOpts['path'] = path;
    if (wsHost != null) wsOpts['headers'] = {'Host': wsHost};
    if (wsOpts.isNotEmpty) proxy['ws-opts'] = wsOpts;
    if (!params.has('alpn')) proxy['alpn'] = ['h2', 'http/1.1'];
  }
  if (params.get('type') == 'grpc' && params.has('path')) {
    proxy['grpc-opts'] = {'grpc-service-name': params.get('path')};
  }
  final alpn = params.get('alpn');
  if (alpn != null) {
    final alpnArr = alpn
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (alpnArr.isNotEmpty) proxy['alpn'] = alpnArr;
  }
  return proxy;
}

Map<String, dynamic> parseHysteria2(String url) {
  final parsed = Uri.parse(url);
  var password = parsed.userInfo;
  final host = parsed.host;
  final port = parsed.port;
  final name = _decodeFragment(parsed.fragment) ?? 'Hysteria2';
  if (host.isEmpty || port <= 0) _throwMissing();
  if (password.isEmpty) password = generateRandomPassword();
  final params = QueryMap(parsed.query);
  final proxy = <String, dynamic>{
    'name': name,
    'type': 'hysteria2',
    'server': host,
    'port': port,
    'password': password,
    'sni': cleanSni(params.get('sni') ?? ''),
    'skip-cert-verify': true,
    'up': '',
    'down': '',
    'fingerprint': '',
  };
  if (params.get('insecure') == '0' || params.get('allowInsecure') == '0') {
    proxy['skip-cert-verify'] = false;
  }
  final alpn = params.get('alpn');
  if (alpn != null) {
    final alpnArr = alpn
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (alpnArr.isNotEmpty) proxy['alpn'] = alpnArr;
  }
  final up = params.get('up');
  if (up != null) {
    final upVal = int.tryParse(up);
    proxy['up'] = upVal ?? up;
  }
  final down = params.get('down');
  if (down != null) {
    final downVal = int.tryParse(down);
    proxy['down'] = downVal ?? down;
  }
  final obfs = params.get('obfs');
  if (obfs != null) {
    proxy['obfs'] = obfs;
    final obfsPassword = params.get('obfs-password');
    if (obfsPassword != null) proxy['obfs-password'] = obfsPassword;
  }
  final fmRaw = params.get('fm');
  if (fmRaw != null && !proxy.containsKey('obfs-password')) {
    try {
      final fm = jsonDecode(Uri.decodeComponent(fmRaw)) as Map<String, dynamic>;
      final udp = fm['udp'];
      if (udp is List) {
        for (final u in udp) {
          if (u is Map<String, dynamic> &&
              u['type'] == 'salamander' &&
              u['settings'] is Map &&
              (u['settings'] as Map)['password'] != null) {
            proxy['obfs'] ??= 'salamander';
            proxy['obfs-password'] = (u['settings'] as Map)['password'];
            break;
          }
        }
      }
    } on Object {}
  }
  return proxy;
}

Map<String, dynamic> parseSS(String url) {
  // Форматы:
  //  1) SIP002:      ss://base64(method:pass)@host:port#name  (или открытым текстом)
  //  2) Legacy:      ss://base64(method:pass@host:port)#name
  //  3) SIP003:      ?plugin=obfs-local;obfs=http;obfs-host=...
  final hashIdx = url.indexOf('#');
  final bodyAndQuery =
      hashIdx == -1 ? url.substring(5) : url.substring(5, hashIdx);
  final name = hashIdx == -1
      ? 'SS'
      : (_decodeFragment(url.substring(hashIdx + 1)) ?? 'SS');
  final qIdx = bodyAndQuery.indexOf('?');
  final body = qIdx == -1 ? bodyAndQuery : bodyAndQuery.substring(0, qIdx);
  final query = qIdx == -1 ? '' : bodyAndQuery.substring(qIdx + 1);

  var method = '';
  var password = '';
  var host = '';
  var port = 0;

  final at = body.lastIndexOf('@');
  if (at != -1) {
    // SIP002: userinfo@host:port
    final userInfo = body.substring(0, at);
    final hostPort = _parseHostPort(body.substring(at + 1));
    host = hostPort['host'] as String;
    port = hostPort['port'] as int;
    if (userInfo.contains(':')) {
      // открытым текстом method:password (возможно percent-encoded)
      final colon = userInfo.indexOf(':');
      method = _decodeFragment(userInfo.substring(0, colon)) ??
          userInfo.substring(0, colon);
      password = _decodeFragment(userInfo.substring(colon + 1)) ??
          userInfo.substring(colon + 1);
    } else {
      final decoded = tryDecodeBase64(Uri.decodeComponent(userInfo));
      if (decoded != null) {
        final colon = decoded.indexOf(':');
        if (colon != -1) {
          method = decoded.substring(0, colon);
          password = decoded.substring(colon + 1);
        }
      }
    }
  } else {
    // Legacy: всё тело — base64 от method:password@host:port
    final decoded = tryDecodeBase64(Uri.decodeComponent(body));
    if (decoded != null) {
      final at2 = decoded.lastIndexOf('@');
      final colon = decoded.indexOf(':');
      if (at2 != -1 && colon != -1 && colon < at2) {
        method = decoded.substring(0, colon);
        password = decoded.substring(colon + 1, at2);
        final hostPort = _parseHostPort(decoded.substring(at2 + 1));
        host = hostPort['host'] as String;
        port = hostPort['port'] as int;
      }
    }
  }

  if (method.isEmpty || password.isEmpty || host.isEmpty || port <= 0) {
    _throwMissing();
  }

  final proxy = <String, dynamic>{
    'name': name,
    'type': 'ss',
    'server': host,
    'port': port,
    'cipher': method,
    'password': password,
    'skip-cert-verify': true,
  };

  // SIP003 plugin
  final pluginRaw = QueryMap(query).get('plugin');
  if (pluginRaw != null && pluginRaw.isNotEmpty) {
    final parts = pluginRaw.split(';');
    final pluginName = parts.first.trim().toLowerCase();
    final opts = <String, String>{};
    for (final part in parts.skip(1)) {
      final eq = part.indexOf('=');
      if (eq == -1) continue;
      opts[part.substring(0, eq).trim()] = part.substring(eq + 1).trim();
    }
    if (pluginName.contains('obfs')) {
      proxy['plugin'] = 'obfs';
      proxy['plugin-opts'] = {
        'mode': opts['obfs'] ?? 'http',
        if (opts['obfs-host'] != null) 'host': opts['obfs-host'],
      };
    } else if (pluginName.contains('v2ray-plugin')) {
      proxy['plugin'] = 'v2ray-plugin';
      proxy['plugin-opts'] = {
        'mode': 'websocket',
        if (opts['host'] != null) 'host': opts['host'],
        if (opts['path'] != null) 'path': opts['path'],
        if (opts.containsKey('tls')) 'tls': true,
      };
    }
  }
  return proxy;
}

Map<String, dynamic> parseTUIC(String url) {
  final parsed = Uri.parse(url);
  final uuid = parsed.userInfo;
  var password = '';
  final colon = uuid.indexOf(':');
  String uuidPart;
  if (colon != -1) {
    uuidPart = uuid.substring(0, colon);
    password = uuid.substring(colon + 1);
  } else {
    uuidPart = uuid;
  }
  final host = parsed.host;
  final port = parsed.port;
  final name = _decodeFragment(parsed.fragment) ?? 'TUIC';
  if (host.isEmpty || port <= 0) _throwMissing();
  final params = QueryMap(parsed.query);
  final skipCert =
      (params.get('insecure') == '0' || params.get('allowInsecure') == '0')
          ? false
          : true;
  final proxy = <String, dynamic>{
    'name': name,
    'type': 'tuic',
    'server': host,
    'port': port,
    'sni': cleanSni(params.get('sni') ?? ''),
    'skip-cert-verify': skipCert,
  };
  if (uuidPart.isNotEmpty && password.isNotEmpty) {
    proxy['uuid'] = uuidPart;
    proxy['password'] = password;
    proxy['token'] = '$uuidPart:$password';
  } else if (uuidPart.isNotEmpty) {
    proxy['token'] = uuidPart;
  }
  final cc = params.get('congestion_control');
  if (cc != null) proxy['congestion-controller'] = cc;
  final urm = params.get('udp_relay_mode');
  if (urm != null) proxy['udp-relay-mode'] = urm;
  final alpn = params.get('alpn');
  if (alpn != null) {
    final alpnArr = alpn
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (alpnArr.isNotEmpty) proxy['alpn'] = alpnArr;
  }
  return proxy;
}

Map<String, dynamic> parseAnytls(String url) {
  final parsed = Uri.parse(url);
  var password = parsed.userInfo;
  final host = parsed.host;
  final port = parsed.port;
  final name = _decodeFragment(parsed.fragment) ?? 'Anytls';
  if (host.isEmpty || port <= 0) _throwMissing();
  if (password.isEmpty) password = generateRandomPassword();
  final params = QueryMap(parsed.query);
  final proxy = <String, dynamic>{
    'name': name,
    'type': 'anytls',
    'server': host,
    'port': port,
    'password': password,
    'sni': cleanSni(params.get('sni') ?? ''),
    'udp': true,
  };
  final insecure =
      params.get('insecure') == '1' || params.get('allowInsecure') == '1';
  if (insecure) proxy['skip-cert-verify'] = true;
  final alpn = params.get('alpn');
  if (alpn != null) {
    final alpnArr = alpn
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (alpnArr.isNotEmpty) proxy['alpn'] = alpnArr;
  }
  return proxy;
}

Map<String, dynamic> parseMasque(String url) {
  final parsed = Uri.parse(url);
  final host = parsed.host;
  final port = parsed.port;
  final name = _decodeFragment(parsed.fragment) ?? 'MASQUE';
  if (host.isEmpty || port <= 0) _throwMissing();
  final params = QueryMap(parsed.query);
  final proxy = <String, dynamic>{
    'name': name,
    'type': 'masque',
    'server': host,
    'port': port,
    'private-key': params.get('private-key') ?? '',
    'public-key': params.get('public-key') ?? '',
    'ip': params.get('ip') ?? '',
    'ipv6': params.get('ipv6') ?? '',
    'mtu': int.tryParse(params.get('mtu') ?? '') ?? 1280,
    'udp': true,
    'sni': params.get('sni') ?? '',
    'network': params.get('network') ?? 'masque',
  };
  final insecure =
      params.get('insecure') == '1' || params.get('allowInsecure') == '1';
  if (insecure) proxy['skip-cert-verify'] = true;
  if (params.has('remote-dns-resolve')) {
    proxy['remote-dns-resolve'] = params.get('remote-dns-resolve') == 'true';
  }
  final dns = params.get('dns');
  if (dns != null) {
    proxy['dns'] =
        dns.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  } else {
    proxy['dns'] = ['1.1.1.1', '1.0.0.1'];
  }
  for (final key in ['private-key', 'public-key', 'ip', 'ipv6', 'sni']) {
    final v = proxy[key];
    if (v == null || (v is String && v.isEmpty)) {
      proxy.remove(key);
    }
  }
  return proxy;
}

Map<String, dynamic> parseHysteria(String url) {
  final parsed = Uri.parse(url);
  final host = parsed.host;
  final port = parsed.port;
  final name = _decodeFragment(parsed.fragment) ?? 'Hysteria';
  if (host.isEmpty || port <= 0) _throwMissing();
  final params = QueryMap(parsed.query);
  final proxy = <String, dynamic>{
    'name': name,
    'type': 'hysteria',
    'server': host,
    'port': port,
    'auth-str': params.get('auth-str') ?? '',
    'up': int.tryParse(params.get('up') ?? '') ?? 0,
    'down': int.tryParse(params.get('down') ?? '') ?? 0,
    'skip-cert-verify': true,
  };
  if (params.get('insecure') == '0' || params.get('allowInsecure') == '0') {
    proxy['skip-cert-verify'] = false;
  }
  final obfs = params.get('obfs');
  if (obfs != null) {
    proxy['obfs'] = obfs;
    final obfsPassword = params.get('obfs-password');
    if (obfsPassword != null) proxy['obfs-password'] = obfsPassword;
  }
  final sni = params.get('sni');
  if (sni != null) {
    proxy['sni'] = sni;
    proxy['servername'] = sni;
  }
  return proxy;
}

Map<String, dynamic> parseVmess(String url) {
  var b64 = url.replaceFirst('vmess://', '');
  // Поддержка URL-safe base64 и отсутствующего паддинга.
  b64 = b64.replaceAll('-', '+').replaceAll('_', '/');
  final pad = (4 - (b64.length % 4)) % 4;
  b64 += '=' * pad;
  Map<String, dynamic> json;
  try {
    json = jsonDecode(utf8.decode(base64Decode(b64))) as Map<String, dynamic>;
  } on Object {
    throw Exception('Невалидный VMess URL');
  }
  // Обязательны только адрес, порт и uuid — остальные поля опциональны.
  final add = '${json['add'] ?? ''}';
  final id = '${json['id'] ?? ''}';
  final port = int.tryParse('${json['port'] ?? ''}') ?? 0;
  if (add.isEmpty || id.isEmpty || port <= 0) _throwMissing();
  final net = '${json['net'] ?? ''}';
  final host = '${json['host'] ?? ''}';
  final path = '${json['path'] ?? ''}';
  final sni = '${json['sni'] ?? ''}';
  final tlsRaw = '${json['tls'] ?? ''}'.toLowerCase();
  final ps = '${json['ps'] ?? ''}';
  final scy = '${json['scy'] ?? ''}';
  final proxy = <String, dynamic>{
    'name': ps.isNotEmpty ? ps : 'VMess',
    'type': 'vmess',
    'server': add,
    'port': port,
    'uuid': id,
    'alterId': int.tryParse('${json['aid'] ?? 0}') ?? 0,
    'cipher': scy.isNotEmpty ? scy : 'auto',
    'network': net.isNotEmpty ? net : 'tcp',
    'client-fingerprint': 'chrome',
    'skip-cert-verify': true,
    'udp': true,
  };
  if (tlsRaw == 'tls' || tlsRaw == 'true') {
    proxy['tls'] = true;
    if (sni.isNotEmpty) {
      proxy['servername'] = sni;
    } else if (host.isNotEmpty) {
      proxy['servername'] = host;
    }
  }
  if (net == 'ws') {
    final wsOpts = <String, dynamic>{};
    if (path.isNotEmpty) wsOpts['path'] = path;
    if (host.isNotEmpty) wsOpts['headers'] = {'Host': host};
    if (wsOpts.isNotEmpty) proxy['ws-opts'] = wsOpts;
  } else if (net == 'h2' || net == 'http') {
    proxy['network'] = 'h2';
    final h2Opts = <String, dynamic>{};
    if (path.isNotEmpty) h2Opts['path'] = path;
    if (host.isNotEmpty) h2Opts['host'] = host;
    if (h2Opts.isNotEmpty) proxy['h2-opts'] = h2Opts;
  } else if (net == 'grpc') {
    final grpcOpts = <String, dynamic>{};
    if (path.isNotEmpty) grpcOpts['grpc-service-name'] = path;
    if (grpcOpts.isNotEmpty) proxy['grpc-opts'] = grpcOpts;
  } else if (net == 'tcp' && '${json['type'] ?? ''}' == 'http') {
    proxy['network'] = 'http';
    final httpOpts = <String, dynamic>{};
    if (path.isNotEmpty) httpOpts['path'] = [path];
    if (host.isNotEmpty) {
      httpOpts['headers'] = {
        'Host': [host],
      };
    }
    if (httpOpts.isNotEmpty) proxy['http-opts'] = httpOpts;
  }
  return proxy;
}

Map<String, dynamic> parseProxyLink(String line) {
  final l = line.trim();
  if (l.startsWith('vless://')) return parseVless(l);
  if (l.startsWith('trojan://')) return parseTrojan(l);
  if (l.startsWith('ss://')) return parseSS(l);
  if (l.startsWith('hy2://') || l.startsWith('hysteria2://')) {
    return parseHysteria2(l);
  }
  if (l.startsWith('tuic://')) return parseTUIC(l);
  if (l.startsWith('anytls://')) return parseAnytls(l);
  if (l.startsWith('masque://')) return parseMasque(l);
  if (l.startsWith('hysteria://')) return parseHysteria(l);
  if (l.startsWith('vmess://')) return parseVmess(l);
  throw Exception('Неизвестный тип: ${l.substring(0, l.length.clamp(0, 20))}');
}

// ---------------- WG / AWG (INI) ----------------

Map<String, dynamic> createWgProxy(Map<String, dynamic> data) {
  var allowedIps = <String>[];
  final rawAllowed = data['allowedIPs'];
  if (rawAllowed is String) {
    allowedIps = rawAllowed
        .split(RegExp(r'[\s,]+'))
        .where((s) => s.isNotEmpty)
        .toList();
  }
  if (allowedIps.isEmpty) allowedIps = ['0.0.0.0/0'];
  allowedIps = allowedIps.where((ip) => !ip.contains(':')).toList();
  if (allowedIps.isEmpty) allowedIps = ['0.0.0.0/0'];

  final isAmnezia =
      data.containsKey('jc') ||
      data.containsKey('s1') ||
      data['headerProtectionKey'] != null ||
      data['contentPaddingAddition'] != null ||
      data['randomTrailers'] != null ||
      data['disableCookies'] != null ||
      data.containsKey('s3') ||
      data.containsKey('s4');

  final newProxy = <String, dynamic>{
    'name': (isAmnezia ? 'AWG-' : 'WG-') + _randomSuffix(),
    'type': 'wireguard',
    'server': data['server'] ?? '',
    'port': data['port'] ?? 0,
    'ip': data['ip'] ?? '',
    'private-key': data['privateKey'],
    'public-key': data['publicKey'],
    'udp': true,
    'dns': data['dns'] is String
        ? (data['dns'] as String)
            .split(RegExp(r'[\s,]+'))
            .where((s) => s.isNotEmpty)
            .toList()
        : (data['dns'] ?? ['1.1.1.1', '1.0.0.1']),
    'allowed-ips': allowedIps,
    'persistent-keepalive': data['keepalive'] ?? 25,
    'pre-shared-key': data['psk'],
    'mtu': data['mtu'] ?? 1420,
  };
  if (isAmnezia) {
    final awg = <String, dynamic>{};
    final isV3 =
        (data['headerProtectionKey'] as String?)?.isNotEmpty == true ||
        (data['contentPaddingAddition'] as String?)?.isNotEmpty == true ||
        (data['rekeyAfterTime'] as String?)?.isNotEmpty == true ||
        (data['rekeyTimeout'] as String?)?.isNotEmpty == true ||
        (data['rejectAfterTime'] as String?)?.isNotEmpty == true ||
        (data['keepaliveTimeout'] as String?)?.isNotEmpty == true ||
        (data['maxHandshakeAttempts'] as String?)?.isNotEmpty == true ||
        (data['randomTrailers'] as String?)?.isNotEmpty == true ||
        (data['disableCookies'] as String?)?.isNotEmpty == true;
    if (isV3) awg['version'] = 3;
    if (data.containsKey('jc')) awg['jc'] = data['jc'];
    if (data.containsKey('jmin')) awg['jmin'] = data['jmin'];
    if (data.containsKey('jmax')) awg['jmax'] = data['jmax'];
    if (data.containsKey('s1')) awg['s1'] = data['s1'];
    if (data.containsKey('s2')) awg['s2'] = data['s2'];
    if (data.containsKey('s3')) awg['s3'] = data['s3'];
    if (data.containsKey('s4')) awg['s4'] = data['s4'];
    if (data.containsKey('h1')) awg['h1'] = data['h1'];
    if (data.containsKey('h2')) awg['h2'] = data['h2'];
    if (data.containsKey('h3')) awg['h3'] = data['h3'];
    if (data.containsKey('h4')) awg['h4'] = data['h4'];
    if (data['i1'] != null) awg['i1'] = data['i1'];
    if (data['headerProtectionKey'] != null) {
      awg['header-protection-key'] = data['headerProtectionKey'];
    }
    if (data['contentPaddingAddition'] != null) {
      awg['content-padding-addition'] = data['contentPaddingAddition'];
    }
    if (data['rekeyAfterTime'] != null) {
      awg['rekey-after-time'] = data['rekeyAfterTime'];
    }
    if (data['rekeyTimeout'] != null) {
      awg['rekey-timeout'] = data['rekeyTimeout'];
    }
    if (data['rejectAfterTime'] != null) {
      awg['reject-after-time'] = data['rejectAfterTime'];
    }
    if (data['keepaliveTimeout'] != null) {
      awg['keepalive-timeout'] = data['keepaliveTimeout'];
    }
    if (data['maxHandshakeAttempts'] != null) {
      awg['max-handshake-attempts'] = data['maxHandshakeAttempts'];
    }
    if (data['randomTrailers'] != null &&
        (data['randomTrailers'] as String).isNotEmpty) {
      final v = (data['randomTrailers'] as String).toLowerCase();
      awg['random-trailers'] = v == 'on' || v == 'true' || v == '1';
    }
    if (data['disableCookies'] != null &&
        (data['disableCookies'] as String).isNotEmpty) {
      final v = (data['disableCookies'] as String).toLowerCase();
      awg['disable-cookies'] = v == 'on' || v == 'true' || v == '1';
    }
    if (awg.isNotEmpty) newProxy['amnezia-wg-option'] = awg;
  }
  if ((newProxy['server'] as String?)?.isEmpty == true) {
    newProxy.remove('server');
  }
  if ((newProxy['port'] ?? 0) == 0) {
    newProxy.remove('port');
  }
  if ((newProxy['ip'] as String?)?.isEmpty == true) {
    newProxy.remove('ip');
  }
  if (newProxy['pre-shared-key'] == null) {
    newProxy.remove('pre-shared-key');
  }
  return newProxy;
}

/// Парсит вставленный текст: INI-конфиг WG/AWG или список ссылок (по строке на
/// прокси). Возвращает список прокси-карт.
List<Map<String, dynamic>> parseManualInput(String? text) {
  final proxies = <Map<String, dynamic>>[];
  if (text == null || text.trim().isEmpty) return proxies;

  final cleanText = text.replaceFirst(RegExp(r'^\uFEFF'), '');
  final lines = cleanText
      .split(RegExp(r'\r?\n'))
      .where((s) => s.trim().isNotEmpty)
      .toList();

  final hasIni = lines.any(
    (line) => line.trim().toLowerCase().startsWith('[interface]'),
  );

  if (hasIni) {
    var data = <String, dynamic>{};
    var section = '';
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      if (line.startsWith('[') && line.endsWith(']')) {
        final newSection = line.substring(1, line.length - 1).toLowerCase();
        if (newSection == 'interface' &&
            section == 'peer' &&
            data['privateKey'] != null &&
            data['publicKey'] != null) {
          proxies.add(createWgProxy(data));
          data = {};
        }
        section = newSection;
        continue;
      }
      final eq = line.indexOf('=');
      if (eq == -1) continue;
      final key = line.substring(0, eq).trim();
      final value = line.substring(eq + 1).trim();
      final lk = key.toLowerCase();
      if (section == 'interface') {
        if (lk == 'privatekey') {
          data['privateKey'] = value;
        } else if (lk == 'address') {
          for (final addr in value.split(',')) {
            final ipOnly = addr.trim().split('/')[0].trim();
            if (!ipOnly.contains(':') && ipOnly.isNotEmpty) {
              data['ip'] ??= ipOnly;
            }
          }
        } else if (lk == 'dns') {
          data['dns'] = value;
        } else if (lk == 'mtu') {
          data['mtu'] = int.tryParse(value);
        } else if (lk == 's1') {
          data['s1'] = int.tryParse(value);
        } else if (lk == 's2') {
          data['s2'] = int.tryParse(value);
        } else if (lk == 's3') {
          data['s3'] = int.tryParse(value);
        } else if (lk == 's4') {
          data['s4'] = int.tryParse(value);
        } else if (lk == 'jc') {
          data['jc'] = int.tryParse(value);
        } else if (lk == 'jmin') {
          data['jmin'] = int.tryParse(value);
        } else if (lk == 'jmax') {
          data['jmax'] = int.tryParse(value);
        } else if (RegExp(r'^h[1-4]$').hasMatch(lk)) {
          data['h${lk[1]}'] = int.tryParse(value);
        } else if (lk == 'i1') {
          data['i1'] = value;
        } else if (lk == 'headerprotectionkey') {
          data['headerProtectionKey'] = value;
        } else if (lk == 'contentpaddingaddition') {
          data['contentPaddingAddition'] = value;
        } else if (lk == 'rekeyaftertime') {
          data['rekeyAfterTime'] = value;
        } else if (lk == 'rekeytimeout') {
          data['rekeyTimeout'] = value;
        } else if (lk == 'rejectaftertime') {
          data['rejectAfterTime'] = value;
        } else if (lk == 'keepalivetimeout') {
          data['keepaliveTimeout'] = value;
        } else if (lk == 'maxhandshakeattempts') {
          data['maxHandshakeAttempts'] = value;
        } else if (lk == 'randomtrailers') {
          data['randomTrailers'] = value;
        } else if (lk == 'disablecookies') {
          data['disableCookies'] = value;
        }
      } else if (section == 'peer') {
        if (lk == 'publickey') {
          data['publicKey'] = value;
        } else if (lk == 'endpoint') {
          if (value.startsWith('[')) {
            final match = RegExp(r'^\[(.+)\]:([0-9]+)$').firstMatch(value);
            if (match != null) {
              data['server'] = match.group(1);
              data['port'] = int.tryParse(match.group(2) ?? '') ?? 0;
            }
          } else {
            final lastColon = value.lastIndexOf(':');
            if (lastColon != -1) {
              data['server'] = value.substring(0, lastColon);
              data['port'] =
                  int.tryParse(value.substring(lastColon + 1)) ?? 0;
            }
          }
        } else if (lk == 'allowedips') {
          data['allowedIPs'] = value;
        } else if (lk == 'persistentkeepalive') {
          final rangeMatch = RegExp(r'^(\d+)').firstMatch(value);
          data['keepalive'] =
              rangeMatch != null
                  ? int.tryParse(rangeMatch.group(1) ?? '')
                  : int.tryParse(value);
        } else if (lk == 'presharedkey') {
          data['psk'] = value;
        }
      }
    }
    if (data['privateKey'] != null && data['publicKey'] != null) {
      proxies.add(createWgProxy(data));
    }
  } else {
    for (final line in lines) {
      try {
        final proxy = parseProxyLink(line);
        if (proxy['name'] != null) proxies.add(proxy);
      } on Object {}
    }
  }
  return proxies;
}

// ---------------- Подписки ----------------

dynamic _yamlToPlain(dynamic node) {
  if (node is YamlMap) {
    // Поддержка merge-ключей "<<" (якоря вида base: &b / <<: *b):
    // сначала базовые ключи, затем собственные (они перекрывают базу).
    var base = <String, dynamic>{};
    final own = <String, dynamic>{};
    node.forEach((key, value) {
      final k = '$key';
      if (k == '<<') {
        final v = _yamlToPlain(value);
        if (v is Map<String, dynamic>) {
          base.addAll(v);
        } else if (v is List) {
          // По спецификации YAML в списке merge раньше — сильнее:
          // применяем с конца, чтобы первые элементы перекрывали последних.
          for (final item in v.reversed) {
            if (item is Map<String, dynamic>) base.addAll(item);
          }
        }
      } else {
        own[k] = _yamlToPlain(value);
      }
    });
    final out = <String, dynamic>{};
    out.addAll(base);
    out.addAll(own);
    return out;
  }
  if (node is YamlList) {
    return node.map(_yamlToPlain).toList();
  }
  return node;
}

/// Ошибка «YAML разобран, но прокси в нём нет» — не лечится фолбэками.
class _YamlNoProxiesException implements Exception {
  final String message;
  _YamlNoProxiesException(this.message);
  @override
  String toString() => message;
}

/// Готовит YAML-текст к разбору: BOM, неразрывные пробелы (NBSP с телефонов),
/// CRLF, «умные» кавычки, ведущие табы → пробелы.
String _sanitizeYamlText(String text) {
  var t = text;
  if (t.startsWith('\uFEFF')) t = t.substring(1);
  t = t
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u00A0', ' ')
      .replaceAll('\u2028', ' ')
      .replaceAll('\u2029', ' ')
      .replaceAll('\u201C', '"')
      .replaceAll('\u201D', '"')
      .replaceAll('\u2018', "'")
      .replaceAll('\u2019', "'");
  final buf = <String>[];
  final leadingTabs = RegExp(r'^(\t+)');
  for (final line in t.split('\n')) {
    final m = leadingTabs.firstMatch(line);
    buf.add(
      m != null
          ? '  ' * m.group(1)!.length + line.substring(m.end)
          : line,
    );
  }
  return buf.join('\n');
}

/// Убирает «мусорные» строки нулевого отступа (обрывки прошлых вставок вида
/// `msq:&msq` перед YAML — не ключ, не элемент списка, не комментарий).
String _stripZeroIndentJunk(String text) {
  final colonKey = RegExp(r':(\s|$)');
  final out = <String>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    final atZero = line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('\t');
    if (atZero &&
        !trimmed.startsWith('#') &&
        !trimmed.startsWith('-') &&
        !trimmed.startsWith('&') &&
        !trimmed.startsWith('!') &&
        trimmed != '---' &&
        !trimmed.startsWith('...') &&
        !colonKey.hasMatch(trimmed)) {
      continue; // строка без ключа — мусор, пропускаем
    }
    out.add(line);
  }
  return out.join('\n');
}

/// При ошибке «Duplicate mapping key» удаляет РАННЮЮ строку-дубликат
/// (последнее вхождение остаётся — так делают все генераторы конфигов).
String? _removeEarlierDuplicateLine(String text, Object error) {
  final m = RegExp(
    r'Error on line (\d+), column \d+: [^\n]*Duplicate mapping key',
  ).firstMatch(error.toString());
  if (m == null) return null;
  final lineNo = int.parse(m.group(1)!) - 1;
  final lines = text.split('\n');
  if (lineNo <= 0 || lineNo >= lines.length) return null;
  final dupLine = lines[lineNo];
  final dupIndent = dupLine.length - dupLine.trimLeft().length;
  final dupBody = dupLine.trimLeft();
  final dupColon = dupBody.indexOf(':');
  if (dupColon <= 0) return null;
  final dupKey = dupBody.substring(0, dupColon).trim();
  for (var i = lineNo - 1; i >= 0; i--) {
    final l = lines[i];
    final t = l.trimLeft();
    if (t.isEmpty) continue;
    final indent = l.length - t.length;
    if (indent < dupIndent) break;
    if (indent == dupIndent && t.startsWith('$dupKey:')) {
      final out = [...lines]..removeAt(i);
      return out.join('\n');
    }
  }
  return null;
}

/// Краткое описание ошибки YAML для сообщения пользователю.
String _shortYamlError(Object error) {
  final s = error.toString().split('\n').first.trim();
  return s.length > 300 ? '${s.substring(0, 300)}…' : s;
}

/// Достаёт список прокси из разобранного YAML-документа.
List<Map<String, dynamic>> _extractYamlProxies(dynamic doc) {
  if (doc is! YamlMap || doc['proxies'] is! YamlList) {
    throw _YamlNoProxiesException('в YAML нет списка proxies');
  }
  final out = <Map<String, dynamic>>[];
  for (final item in (doc['proxies'] as YamlList)) {
    if (item is YamlMap) {
      final map = _yamlToPlain(item);
      if (map is Map<String, dynamic> &&
          map['type'] != null &&
          map['server'] != null) {
        map['name'] ??= 'proxy';
        out.add(map);
      }
    }
  }
  if (out.isEmpty) {
    throw _YamlNoProxiesException('в подписке нет валидных прокси');
  }
  return out;
}

/// «Спасательный» разбор: вынимает элементы всех блоков proxies: и парсит
/// каждый ОТДЕЛЬНО (с якорной преамбулой). Спасает конфиги с дубликатами
/// ключей (два блока proxies после склейки/апдейта), где package:yaml
/// отказывается парсить документ целиком.
List<Map<String, dynamic>> _salvageProxyItems(String text) {
  final lines = text.split('\n');
  final keyProxies = RegExp(r'^proxies\s*:\s*(#.*)?$');
  final anchorDef = RegExp(r'^[^\s#-][^:]*:\s*&\S+');
  final itemStartRe = RegExp(r'^(\s*)- ');

  // 1) якорные определения верхнего уровня (key: &anchor + его блок)
  final preamble = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (anchorDef.hasMatch(lines[i])) {
      preamble.add(lines[i]);
      var j = i + 1;
      while (j < lines.length) {
        final t = lines[j];
        if (t.trim().isEmpty || t.startsWith(' ') || t.startsWith('\t')) {
          preamble.add(t);
          j++;
        } else {
          break;
        }
      }
      i = j - 1;
    }
  }
  final pre = preamble.isEmpty ? '' : "${preamble.join('\n')}\n";

  // 2) блоки proxies: → элементы → отдельный разбор каждого
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < lines.length; i++) {
    if (!keyProxies.hasMatch(lines[i])) continue;
    var j = i + 1;
    final block = <String>[];
    while (j < lines.length) {
      final t = lines[j];
      // элементы списка могут быть на отступе 0 (- name: ...) — тоже часть блока
      if (t.trim().isEmpty ||
          t.startsWith(' ') ||
          t.startsWith('\t') ||
          itemStartRe.hasMatch(t)) {
        block.add(t);
        j++;
      } else {
        break;
      }
    }
    // режем блок на элементы по '- ' на уровне первого элемента
    var itemStart = -1;
    var itemIndent = -1;
    final items = <String>[];
    for (var k = 0; k < block.length; k++) {
      final m = itemStartRe.firstMatch(block[k]);
      if (m != null) {
        final indent = m.group(1)!.length;
        if (itemStart < 0) {
          itemStart = k;
          itemIndent = indent;
        } else if (indent == itemIndent) {
          items.add(block.sublist(itemStart, k).join('\n'));
          itemStart = k;
        }
      }
    }
    if (itemStart >= 0) items.add(block.sublist(itemStart).join('\n'));
    for (final item in items) {
      try {
        final doc = loadYaml('${pre}__salvage__:\n$item');
        if (doc is YamlMap && doc['__salvage__'] is YamlList) {
          for (final node in (doc['__salvage__'] as YamlList)) {
            if (node is YamlMap) {
              final map = _yamlToPlain(node);
              if (map is Map<String, dynamic> &&
                  map['type'] != null &&
                  map['server'] != null) {
                map['name'] ??= 'proxy';
                out.add(map);
              }
            }
          }
        }
      } on Object {
        // битый элемент — пропускаем
      }
    }
    i = j - 1;
  }
  return out;
}

/// Разбирает clash-YAML подписку: извлекает список proxies.
///
/// Устойчив к типичным «битым» вставкам: сначала санитизация (BOM, NBSP,
/// табы, умные кавычки), затем удаление мусорных строк перед YAML, затем
/// хирургия дубликатов ключей, затем мультидокументный разбор. Если не
/// помогло ничего — бросает ошибку С ДЕТАЛЯМИ package:yaml (строка/столбец).
List<Map<String, dynamic>> parseYamlSubscription(String text) {
  final sanitized = _sanitizeYamlText(text);
  final variants = <String>[sanitized];
  final stripped = _stripZeroIndentJunk(sanitized);
  if (stripped != sanitized) variants.add(stripped);

  Object? firstError;
  for (final variant in variants) {
    var current = variant;
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        return _extractYamlProxies(loadYaml(current));
      } on _YamlNoProxiesException {
        rethrow;
      } on Object catch (e) {
        firstError ??= e;
        // Дубликаты ключей и мультидокументные вставки: сначала
        // спасение по-элементно, затем хирургия (удаление раннего дубля).
        if (e.toString().contains('Duplicate mapping key') ||
            e.toString().contains('Only expected one document')) {
          final salvaged = _salvageProxyItems(current);
          if (salvaged.isNotEmpty) return salvaged;
        }
        final patched = _removeEarlierDuplicateLine(current, e);
        if (patched == null || patched == current) break;
        current = patched;
      }
    }
    // Мультидокументный YAML (несколько блоков через ---).
    try {
      final merged = <Map<String, dynamic>>[];
      for (final doc in loadYamlStream(current)) {
        merged.addAll(_extractYamlProxies(doc));
      }
      if (merged.isNotEmpty) return merged;
    } on Object {
      // остаёмся с первой ошибкой
    }
  }
  if (firstError != null) {
    throw Exception('невалидный YAML — ${_shortYamlError(firstError)}');
  }
  throw Exception('в YAML не найдено прокси');
}

/// Разбирает тело подписки: clash-YAML, base64 (v2ray) или список ссылок.
List<Map<String, dynamic>> parseSubscriptionBody(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) {
    throw Exception('сервер вернул пустой ответ');
  }
  // HTML-страница вместо подписки (истёкшая ссылка, капча, ошибка сервера).
  if (RegExp(r'^<!DOCTYPE|^<html|^[\s\r\n]*<(html|body|div|head|script)',
          caseSensitive: false)
      .hasMatch(trimmed)) {
    throw Exception(
        'сервер вернул HTML-страницу вместо подписки — проверьте срок действия ссылки');
  }
  // Clash YAML (в т.ч. с мусором до/после — parseYamlSubscription сам справится)
  if (RegExp(r'^\s*proxies\s*:', multiLine: true).hasMatch(trimmed)) {
    return parseYamlSubscription(trimmed);
  }
  // Base64 (v2ray-подписка)
  final decoded = tryDecodeBase64(trimmed);
  if (decoded != null) {
    if (RegExp(r'proxies\s*:').hasMatch(decoded)) {
      return parseYamlSubscription(decoded);
    }
    final inner = parseManualInput(decoded);
    if (inner.isNotEmpty) return inner;
  }
  // Простой список ссылок
  final direct = parseManualInput(trimmed);
  if (direct.isNotEmpty) return direct;
  throw Exception('не удалось распознать содержимое (нет proxies или ссылок)');
}

// ---------------- Дедупликация ----------------

String _proxyKey(Map<String, dynamic> p) {
  final type = p['type'] as String? ?? 'unknown';
  var id = '';
  switch (type) {
    case 'vless':
      id = p['uuid'] as String? ?? '';
      break;
    case 'trojan':
    case 'anytls':
      id = p['password'] as String? ?? '';
      break;
    case 'ss':
      id = '${p['cipher']}:${p['password']}';
      break;
    case 'hysteria2':
      id = p['password'] as String? ?? '';
      break;
    case 'tuic':
      id = '${p['uuid']}:${p['password']}';
      break;
    case 'wireguard':
      id = '${p['private-key'] ?? ''}${p['public-key'] ?? ''}';
      break;
    case 'masque':
      final sni = p['sni'] ?? '';
      final network = p['network'] ?? 'masque';
      final pk = p['private-key'] ?? '';
      final pub = p['public-key'] ?? '';
      id = '${p['server']}:${p['port']}:$sni:$network:$pk:$pub';
      break;
  }
  return '$type|${p['server']}|${p['port']}|$id';
}

List<Map<String, dynamic>> uniqueProxies(List<Map<String, dynamic>> proxies) {
  final seen = <String>{};
  final unique = <Map<String, dynamic>>[];
  for (final p in proxies) {
    final key = _proxyKey(p);
    if (!seen.contains(key)) {
      seen.add(key);
      unique.add(p);
    }
  }
  return unique;
}

void ensureUniqueNames(List<Map<String, dynamic>> proxies) {
  final names = <String>{};
  for (final p in proxies) {
    var name = p['name'] as String?;
    if (name == null || name.isEmpty) {
      name = 'proxy-${_randomSuffix(6)}';
    }
    var newName = name;
    var counter = 1;
    while (names.contains(newName)) {
      newName = '$name-${counter++}';
    }
    p['name'] = newName;
    names.add(newName);
  }
}

// ---------------- Сборка конфига ----------------

class GeneratorChains {
  /// Каждая цепочка — упорядоченный список имён прокси (A -> B -> C).
  final List<List<String>> chains;
  const GeneratorChains({this.chains = const []});
}

class GeneratorParams {
  final String urlTest;
  final String defaultNameserver;
  final String nameserver;
  final String proxyServerNameserver;
  final String? mtu;
  final bool providerMode;
  final String providerUrl;
  final int providerInterval;
  final List<Map<String, dynamic>> proxies;
  final List<List<String>> chains;
  final List<String> providerSets;
  final List<String> servicePresets;
  final List<String> cdnPresets;
  final bool ruUnblock;
  final List<Map<String, String>> customRules;

  const GeneratorParams({
    required this.urlTest,
    required this.defaultNameserver,
    required this.nameserver,
    required this.proxyServerNameserver,
    this.mtu,
    this.providerMode = false,
    this.providerUrl = '',
    this.providerInterval = 86400,
    required this.proxies,
    this.chains = const [],
    this.providerSets = const ['roscomvpn'],
    this.servicePresets = const [],
    this.cdnPresets = const [],
    this.ruUnblock = true,
    this.customRules = const [],
  });
}

const Map<String, List<String>> _kRequiredFields = {
  'vless': ['uuid'],
  'trojan': ['password'],
  'ss': ['cipher', 'password'],
  'hysteria2': ['password'],
  'tuic': ['uuid', 'password'],
  'anytls': ['password'],
  'masque': ['server', 'port'],
  'hysteria': [],
  'vmess': ['uuid'],
};

List<Map<String, dynamic>> _buildProxyList(List<Map<String, dynamic>> parsed) {
  final proxyList = <Map<String, dynamic>>[];
  for (final proxy in parsed) {
    final type = proxy['type'] as String? ?? '';
    final req = _kRequiredFields[type] ?? const [];
    var ok = true;
    for (final f in req) {
      final val = proxy[f];
      if (val == null || val == '' || (val is String && val.trim().isEmpty)) {
        ok = false;
        break;
      }
    }
    if (ok) {
      final clean = <String, dynamic>{};
      proxy.forEach((k, v) {
        if (v != null && v != '') clean[k] = v;
      });
      proxyList.add(clean);
    }
  }
  return proxyList;
}

/// Порт generateFullYaml из веб-генератора (режим static + provider).
String buildConfig(GeneratorParams p) {
  final urlTest = p.urlTest.trim().isEmpty
      ? 'http://detectportal.firefox.com/success.txt'
      : p.urlTest.trim();
  final defaultNS = p.defaultNameserver.trim().isEmpty
      ? kDefaultDnsValues['defaultNameserver'] as String
      : p.defaultNameserver.trim();
  final nameserver = p.nameserver.trim().isEmpty
      ? kDefaultDnsValues['nameserver'] as String
      : p.nameserver.trim();
  final proxyNS = p.proxyServerNameserver.trim().isEmpty
      ? kDefaultDnsValues['proxyServerNameserver'] as String
      : p.proxyServerNameserver.trim();

  final dnsObj = <String, dynamic>{
    'enable': true,
    'ipv6': false,
    'default-nameserver': defaultNS
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(),
    'direct-nameserver': [
      '77.88.8.8#DIRECT',
      '77.88.8.1#DIRECT',
      '8.8.8.8#DIRECT',
    ],
    'nameserver': nameserver
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(),
    'nameserver-policy': {
      'raw.githubusercontent.com,cdn.jsdelivr.net,github.com': [
        'tls://77.88.8.8#skip-cert-verify=true',
        'tls://77.88.8.1#skip-cert-verify=true',
        'tls://8.8.8.8#skip-cert-verify=true',
      ],
      'rule-set:ru-inline,ru-outside,yandex,mailru,drweb,geosite-ru': [
        'tls://77.88.8.8#skip-cert-verify=true',
        'tls://77.88.8.1#skip-cert-verify=true',
        'tls://8.8.8.8#skip-cert-verify=true',
      ],
    },
    'prefer-h3': false,
    'proxy-server-nameserver': proxyNS
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(),
    'use-hosts': true,
    'use-system-hosts': true,
    'enhanced-mode': 'redir-host',
  };

  // --- прокси ---
  var proxyList = <Map<String, dynamic>>[];
  if (!p.providerMode) {
    proxyList = _buildProxyList(p.proxies);
  }
  ensureUniqueNames(proxyList);

  // --- цепочки (dialer-proxy) ---
  final chainProxyNames = <String>[];
  for (final chainNames in p.chains) {
    if (chainNames.length < 2) continue;
    final originals = <Map<String, dynamic>>[];
    for (final name in chainNames) {
      for (final proxy in proxyList) {
        if (proxy['name'] == name) {
          originals.add(proxy);
          break;
        }
      }
    }
    if (originals.length < 2) continue;
    var prevName = originals[0]['name'] as String;
    for (var i = 1; i < originals.length; i++) {
      final orig = originals[i];
      final newName = '${orig['name']}_via_$prevName';
      final copy = <String, dynamic>{};
      orig.forEach((k, v) {
        if (k != 'dialer-proxy' && v != null && v != '') copy[k] = v;
      });
      copy['name'] = newName;
      copy['dialer-proxy'] = prevName;
      final orderedCopy = <String, dynamic>{
        'name': copy['name'],
        'type': copy['type'],
        'dialer-proxy': copy['dialer-proxy'],
      };
      copy.forEach((k, v) {
        if (k != 'name' && k != 'type' && k != 'dialer-proxy') {
          orderedCopy[k] = v;
        }
      });
      proxyList.add(orderedCopy);
      chainProxyNames.add(newName);
      prevName = newName;
    }
  }

  // --- группы ---
  final groups = jsonDecode(jsonEncode(kProxyGroups)) as List<dynamic>;
  for (final g in groups) {
    if (g is Map<String, dynamic> && g['name'] == '🛡️ VPN') {
      final vpnProxies = (g['proxies'] as List).cast<String>().toList();
      for (final name in chainProxyNames) {
        if (!vpnProxies.contains(name)) vpnProxies.add(name);
      }
      g['proxies'] = vpnProxies;
    }
    if (g is Map<String, dynamic> && g['name'] == '⚡️ Авто') {
      g['url'] = urlTest;
    }
  }

  // --- rule-providers ---
  final selectedProviders = <String>[];
  for (final key in ['roscomvpn', 'davoyan', 'legiz']) {
    if (p.providerSets.contains(key)) selectedProviders.add(key);
  }
  var ruleProviders = <String, dynamic>{};
  for (final key in ['roscomvpn', 'davoyan', 'legiz']) {
    if (selectedProviders.contains(key)) {
      ruleProviders.addAll(kProviderSets[key]!);
    }
  }
  final providerNames = ruleProviders.keys.toSet();

  final filteredPolicy = <String, dynamic>{};
  (dnsObj['nameserver-policy'] as Map<String, dynamic>).forEach((key, value) {
    if (key.startsWith('rule-set:')) {
      final sets = key.split(':')[1].split(',').map((s) => s.trim()).toList();
      final allExist = sets.every(providerNames.contains);
      if (allExist) filteredPolicy[key] = value;
    } else {
      filteredPolicy[key] = value;
    }
  });
  dnsObj['nameserver-policy'] = filteredPolicy;

  // --- правила ---
  var allRules = <String>[];
  for (final rule in kRulesBase.cast<String>()) {
    if (rule.startsWith('RULE-SET,')) {
      final parts = rule.split(',');
      if (parts.length >= 2 && providerNames.contains(parts[1].trim())) {
        allRules.add(rule);
      }
    } else {
      allRules.add(rule);
    }
  }

  final presetRules = <String>[];
  for (final name in p.servicePresets) {
    final rules = kServiceRules[name];
    if (rules != null) presetRules.addAll(rules.cast<String>());
  }
  for (final name in p.cdnPresets) {
    final rules = kCdnRules[name];
    if (rules != null) presetRules.addAll(rules.cast<String>());
  }
  if (p.ruUnblock) presetRules.addAll(kUnblockRules.cast<String>());

  for (final rule in presetRules) {
    if (rule.startsWith('RULE-SET,')) {
      final parts = rule.split(',');
      if (parts.length >= 2 && providerNames.contains(parts[1].trim())) {
        allRules.add(rule);
      }
    } else {
      allRules.add(rule);
    }
  }

  for (final rule in p.customRules) {
    final type = rule['type'] ?? '';
    final value = rule['value'] ?? '';
    final action = rule['action'] ?? '';
    if (value.isEmpty || action.isEmpty) continue;
    if (type == 'RULE-SET') {
      if (!providerNames.contains(value)) continue;
      allRules.add('RULE-SET,$value,$action');
      continue;
    }
    const known = [
      'PROCESS-NAME', 'DOMAIN-SUFFIX', 'DOMAIN', 'IP-CIDR', 'GEOIP',
      'GEOSITE', 'DOMAIN-KEYWORD',
    ];
    if (known.contains(type)) {
      final line = '$type,$value,$action';
      if (!allRules.contains(line)) allRules.add(line);
    }
  }

  final finalRules = <String>[];
  for (final rule in allRules) {
    if (rule.startsWith('RULE-SET,')) {
      final parts = rule.split(',');
      if (parts.length >= 2 && providerNames.contains(parts[1].trim())) {
        finalRules.add(rule);
      }
    } else {
      finalRules.add(rule);
    }
  }

  final seen = <String>{};
  final uniqueRules = <String>[];
  for (final rule in finalRules) {
    if (!seen.contains(rule)) {
      seen.add(rule);
      uniqueRules.add(rule);
    }
  }
  final matchIndex = uniqueRules.indexWhere((r) => r.startsWith('MATCH,'));
  if (matchIndex != -1) {
    final match = uniqueRules.removeAt(matchIndex);
    uniqueRules.add(match);
  } else {
    uniqueRules.add('MATCH,PROXY');
  }

  // --- сборка ---
  final routeExcludes = [
    '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
    '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24',
    '192.88.99.0/24', '192.168.0.0/16', '198.18.0.0/15', '198.51.100.0/24',
    '203.0.113.0/24', '224.0.0.0/3', '::/127', 'fc00::/7', 'fe80::/10',
    'ff00::/8',
  ];

  final tun = <String, dynamic>{
    'enable': true,
    'stack': 'gvisor',
    'auto-route': true,
    'auto-detect-interface': true,
    'strict-route': true,
    'dns-hijack': ['any:53', 'tcp://any:53'],
    'route-exclude-address': routeExcludes,
  };
  final mtu = int.tryParse(p.mtu ?? '');
  if (mtu != null && mtu > 0) tun['mtu'] = mtu;

  final config = <String, dynamic>{
    ...kStaticObj.map((k, v) => MapEntry(k, jsonDecode(jsonEncode(v)))),
    'dns': dnsObj,
    'proxy-groups': groups,
    'rule-providers': ruleProviders,
    'rules': uniqueRules,
    'tun': tun,
    'sniffer': {
      'enable': true,
      'force-dns-mapping': true,
      'override-destination': false,
      'parse-pure-ip': true,
      'skip-dst-address': routeExcludes,
      'sniff': {
        'HTTP': {'override-destination': true, 'ports': [80, '8080-8880']},
        'TLS': {'ports': [443, 8443]},
      },
    },
  };

  if (p.providerMode) {
    if (p.providerUrl.trim().isEmpty) {
      throw Exception('Введите URL подписки в формате YAML.');
    }
    config['proxy-providers'] = {
      'subscription': {
        'type': 'http',
        'url': p.providerUrl.trim(),
        'interval': p.providerInterval,
        'path': './provider/proxies.yaml',
        'health-check': {
          'enable': true,
          'url': urlTest,
          'interval': 600,
        },
      },
    };
  } else {
    if (proxyList.isEmpty) {
      throw Exception('Нет прокси: вставьте ссылки или импортируйте конфиг.');
    }
    config['proxies'] = proxyList;
  }

  return yamlDump(config);
}

// ---------------- YAML-эмиттер ----------------

bool _needsQuoting(String s) {
  if (s.isEmpty) return true;
  if (RegExp(r'^[\s]|[\s]$').hasMatch(s)) return true;
  if (RegExp(r'^[-?:,\[\]{}#&*!|>"''%@`]').hasMatch(s)) return true;
  if (s.contains(': ') || s.contains(' #')) return true;
  if (s.contains('\n') || s.contains('\t')) return true;
  if (RegExp(r'^[0-9+\-.]+$').hasMatch(s) && double.tryParse(s) != null) {
    return true;
  }
  const specials = ['true', 'false', 'null', '~', 'yes', 'no', 'on', 'off'];
  if (specials.contains(s.toLowerCase())) return true;
  return false;
}

String _yamlScalar(String s) {
  if (!_needsQuoting(s)) return s;
  return '"${s.replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n').replaceAll('\t', r'\t')}"';
}

void _yamlWrite(StringBuffer buf, Object? value, int indent) {
  final pad = ' ' * indent;
  if (value is Map<String, dynamic>) {
    if (value.isEmpty) {
      buf.write('{}\n');
      return;
    }
    value.forEach((key, v) {
      final k = _yamlScalar(key);
      if (v is Map<String, dynamic> && v.isNotEmpty) {
        buf.write('$pad$k:\n');
        _yamlWrite(buf, v, indent + 2);
      } else if (v is List<dynamic> && v.isNotEmpty) {
        buf.write('$pad$k:\n');
        _yamlWrite(buf, v, indent + 2);
      } else {
        buf.write('$pad$k: ');
        _yamlWrite(buf, v, indent + 2);
      }
    });
  } else if (value is List<dynamic>) {
    if (value.isEmpty) {
      buf.write('[]\n');
      return;
    }
    for (final item in value) {
      if (item is Map<String, dynamic>) {
        if (item.isEmpty) {
          buf.write('$pad- {}\n');
          continue;
        }
        var first = true;
        item.forEach((key, v) {
          final k = _yamlScalar(key);
          if (first) {
            buf.write('$pad- ');
            first = false;
          } else {
            buf.write('$pad  ');
          }
          if (v is Map<String, dynamic> && v.isNotEmpty) {
            buf.write('$k:\n');
            _yamlWrite(buf, v, indent + 4);
          } else if (v is List<dynamic> && v.isNotEmpty) {
            buf.write('$k:\n');
            _yamlWrite(buf, v, indent + 4);
          } else {
            buf.write('$k: ');
            _yamlWrite(buf, v, indent + 4);
          }
        });
      } else if (item is List<dynamic>) {
        buf.write('$pad- ');
        _yamlWrite(buf, item, indent + 2);
      } else {
        buf.write('$pad- ');
        _yamlWrite(buf, item, indent + 2);
      }
    }
  } else if (value is String) {
    buf.write(_yamlScalar(value));
    buf.write('\n');
  } else if (value is bool || value is int || value == null) {
    buf.write('${value ?? 'null'}\n');
  } else if (value is double) {
    buf.write('${value % 1 == 0 ? value.toInt() : value}\n');
  } else {
    buf.write(_yamlScalar('$value'));
    buf.write('\n');
  }
}

/// Детерминированный block-style YAML, совместимый с mihomo.
String yamlDump(Map<String, dynamic> config) {
  final buf = StringBuffer();
  _yamlWrite(buf, config, 0);
  return buf.toString();
}
