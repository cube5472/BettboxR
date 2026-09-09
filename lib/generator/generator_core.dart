// Ядро генератора BettboxR — порт веб-генератора "РКН ОФФЛАЙН" (index.html).
// Чистый Dart без внешних зависимостей: парсеры ссылок и WG/AWG-конфигов,
// дедупликация, сборка mihomo YAML с собственным детерминированным эмиттером.
import 'dart:convert';
import 'dart:math';

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
  final parsed = Uri.parse(url);
  final userInfo = parsed.userInfo;
  final eq = userInfo.indexOf(':');
  final method = eq == -1 ? userInfo : userInfo.substring(0, eq);
  final password = eq == -1 ? '' : userInfo.substring(eq + 1);
  final host = parsed.host;
  final port = parsed.port;
  final name = _decodeFragment(parsed.fragment) ?? 'SS';
  if (method.isEmpty || password.isEmpty || host.isEmpty || port <= 0) {
    _throwMissing();
  }
  return {
    'name': name,
    'type': 'ss',
    'server': host,
    'port': port,
    'cipher': method,
    'password': password,
    'skip-cert-verify': true,
  };
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
  const required = [
    'v', 'ps', 'add', 'port', 'id', 'aid', 'net', 'type', 'host', 'path',
    'tls', 'sni',
  ];
  for (final key in required) {
    if (!json.containsKey(key)) {
      throw Exception('Отсутствует поле $key');
    }
  }
  final proxy = <String, dynamic>{
    'name': (json['ps'] as String?)?.isNotEmpty == true ? json['ps'] : 'VMess',
    'type': 'vmess',
    'server': json['add'],
    'port': int.tryParse('${json['port']}') ?? 0,
    'uuid': json['id'],
    'alterId': int.tryParse('${json['aid']}') ?? 0,
    'cipher': 'auto',
    'network': (json['net'] as String?)?.isNotEmpty == true ? json['net'] : 'tcp',
    'client-fingerprint': 'chrome',
    'skip-cert-verify': true,
    'udp': true,
  };
  if (json['tls'] == 'tls') {
    proxy['tls'] = true;
    if ((json['sni'] as String?)?.isNotEmpty == true) {
      proxy['servername'] = json['sni'];
    } else if ((json['host'] as String?)?.isNotEmpty == true) {
      proxy['servername'] = json['host'];
    }
  }
  if (json['net'] == 'ws') {
    proxy['network'] = 'ws';
    final wsOpts = <String, dynamic>{};
    if ((json['path'] as String?)?.isNotEmpty == true) {
      wsOpts['path'] = json['path'];
    }
    if ((json['host'] as String?)?.isNotEmpty == true) {
      wsOpts['headers'] = {'Host': json['host']};
    }
    if (wsOpts.isNotEmpty) proxy['ws-opts'] = wsOpts;
  }
  if (json['net'] == 'h2' || json['net'] == 'http') {
    proxy['network'] = 'h2';
    final h2Opts = <String, dynamic>{};
    if ((json['path'] as String?)?.isNotEmpty == true) {
      h2Opts['path'] = json['path'];
    }
    if ((json['host'] as String?)?.isNotEmpty == true) {
      h2Opts['host'] = json['host'];
    }
    if (h2Opts.isNotEmpty) proxy['h2-opts'] = h2Opts;
  }
  if (json['net'] == 'grpc') {
    proxy['network'] = 'grpc';
    final grpcOpts = <String, dynamic>{};
    if ((json['path'] as String?)?.isNotEmpty == true) {
      grpcOpts['grpc-service-name'] = json['path'];
    }
    if (grpcOpts.isNotEmpty) proxy['grpc-opts'] = grpcOpts;
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
  'hysteria': ['auth-str'],
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
