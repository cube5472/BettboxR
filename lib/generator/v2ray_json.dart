// Конвертер подписок в формате v2ray-JSON (массив полных Xray-конфигов) в
// mihomo-прокси. Этот формат отдают панели, рассчитанные на клиенты
// happ / v2raytun / INCY (эндпоинт вида /json/<token>): тело подписки —
// JSON-массив, каждый элемент которого содержит remarks, dns, routing и
// outbounds с серверами. Именно так «понимают» такие панели клиенты
// happ/v2raytun, поэтому BettboxR тоже должен уметь их читать.
//
// BettboxR извлекает все прокси-outbounds (vless/vmess/trojan/ss/hysteria2),
// конвертирует их в mihomo-прокси и собирает обычный конфиг средствами
// генератора (buildConfig). Service-outbounds (freedom/blackhole/loopback)
// игнорируются. Поддержаны оба представления настроек: стандартное v2ray
// (settings.vnext[0].users[0]) и упрощённое плоское (settings.address/id).
import 'dart:convert';

import 'generator_core.dart';

const List<String> _kProxyProtocols = [
  'vless',
  'vmess',
  'trojan',
  'shadowsocks',
  'hysteria',
  'hysteria2',
];

/// Распознаёт v2ray-JSON подписку и извлекает mihomo-прокси.
/// null — тело не является JSON-массивом Xray-конфигов;
/// пустой список — формат тот, но прокси не извлеклись.
List<Map<String, dynamic>>? tryParseV2rayJsonSubscription(String body) {
  final trimmed = body.trim();
  if (!trimmed.startsWith('[')) return null;
  final dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on Object {
    return null;
  }
  if (decoded is! List || decoded.isEmpty) return null;
  var hasOutbounds = false;
  for (final item in decoded) {
    if (item is Map && item['outbounds'] is List) {
      hasOutbounds = true;
      break;
    }
  }
  if (!hasOutbounds) return null;

  // Одиночные элементы (1 прокси) получают имя из remarks — как в happ;
  // групповые («умные»/балансировочные) обрабатываются после них, поэтому
  // дубликаты серверов отбрасываются в пользу «человеческих» имён.
  final singles = <Map<String, dynamic>>[];
  final multis = <Map<String, dynamic>>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final outbounds = item['outbounds'];
    if (outbounds is! List) continue;
    final remarks =
        item['remarks'] is String ? (item['remarks'] as String).trim() : '';
    final proxies = <Map<String, dynamic>>[];
    var fallbackIdx = 0;
    for (final o in outbounds) {
      if (o is! Map) continue;
      fallbackIdx++;
      final proxy = _convertOutbound(o, remarks, fallbackIdx);
      if (proxy != null) proxies.add(proxy);
    }
    if (proxies.length == 1) {
      singles.add(proxies.first);
    } else if (proxies.length > 1) {
      multis.addAll(proxies);
    }
  }
  return uniqueProxies([...singles, ...multis]);
}

/// Конвертирует полный v2ray-JSON в готовый mihomo-YAML (генераторный
/// скелет: DNS, группы, правила, tun). null — тело не является
/// v2ray-JSON подпиской. Бросает Exception, если формат распознан,
/// но извлечь прокси не удалось.
String? convertV2rayJsonSubscription(String body) {
  final parsed = tryParseV2rayJsonSubscription(body);
  if (parsed == null) return null;
  if (parsed.isEmpty) {
    throw Exception(
      'подписка в формате v2ray-JSON распознана, но прокси в ней не найдены',
    );
  }
  return buildConfig(
    GeneratorParams(
      urlTest: '',
      defaultNameserver: '',
      nameserver: '',
      proxyServerNameserver: '',
      proxies: parsed,
    ),
  );
}

Map<String, dynamic>? _convertOutbound(
  Map<dynamic, dynamic> o,
  String remarks,
  int fallbackIdx,
) {
  final protocol = o['protocol'] is String ? o['protocol'] as String : '';
  if (!_kProxyProtocols.contains(protocol)) return null;
  final settings = o['settings'] is Map
      ? o['settings'] as Map<dynamic, dynamic>
      : const <dynamic, dynamic>{};
  final stream = o['streamSettings'] is Map
      ? o['streamSettings'] as Map<dynamic, dynamic>
      : const <dynamic, dynamic>{};
  final tag = o['tag'] is String ? (o['tag'] as String).trim() : '';
  // Генерические теги ('proxy', 'direct', ...) не информативны — имя берём
  // из remarks; содержательный тег ('bal-1-vless') дополняет remarks.
  const genericTags = {
    'proxy',
    'proxies',
    'outbound',
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'ss',
    'hysteria',
    'hysteria2',
    'tuic',
    'wireguard',
    'warp',
    'direct',
    'block',
  };
  final tagIsGeneric = tag.isEmpty || genericTags.contains(tag.toLowerCase());
  final nameBase = !tagIsGeneric && remarks.isNotEmpty
      ? '$remarks · $tag'
      : remarks.isNotEmpty
          ? remarks
          : (tag.isNotEmpty ? tag : 'node-$fallbackIdx');

  Map<String, dynamic>? proxy;
  switch (protocol) {
    case 'vless':
    case 'vmess':
      proxy = _convertVlessVmess(settings, protocol);
      break;
    case 'trojan':
      proxy = _convertTrojan(settings);
      break;
    case 'shadowsocks':
      proxy = _convertShadowsocks(settings);
      break;
    case 'hysteria':
    case 'hysteria2':
      proxy = _convertHysteria2(settings, stream);
      break;
  }
  if (proxy == null) return null;
  proxy['name'] = nameBase;
  if (protocol == 'hysteria' || protocol == 'hysteria2') {
    // QUIC-транспорт: sni/alpn/obfs уже учтены; streamSettings тут —
    // не v2ray-транспорт.
  } else if (!_applyStream(proxy, stream)) {
    return null;
  }
  return proxy;
}

/// settings может быть стандартным ({vnext:[{address,port,users:[...]}]})
/// или упрощённым плоским ({address, port, id, flow, ...}).
Map<String, dynamic>? _convertVlessVmess(
  Map<dynamic, dynamic> settings,
  String type,
) {
  var server = settings;
  var user = settings;
  final vnext = settings['vnext'];
  if (vnext is List && vnext.isNotEmpty && vnext.first is Map) {
    server = vnext.first as Map<dynamic, dynamic>;
    final users = server['users'];
    if (users is List && users.isNotEmpty && users.first is Map) {
      user = users.first as Map<dynamic, dynamic>;
    }
  }
  final address = server['address'];
  if (address is! String || address.isEmpty) return null;
  final rawPort = server['port'];
  final port = rawPort is int ? rawPort : int.tryParse('$rawPort');
  if (port == null || port <= 0 || port > 65535) return null;
  final id = user['id'];
  if (id is! String || id.isEmpty) return null;

  final proxy = <String, dynamic>{
    'type': type,
    'server': address,
    'port': port,
    'uuid': id,
    'udp': true,
  };
  if (type == 'vmess') {
    final rawAid = user['alterId'] ?? settings['alterId'];
    proxy['alterId'] = rawAid is int ? rawAid : int.tryParse('$rawAid') ?? 0;
    final cipher = user['security'] ?? settings['security'];
    proxy['cipher'] =
        cipher is String && cipher.isNotEmpty ? cipher : 'auto';
  } else {
    final encryption = user['encryption'];
    if (encryption is String &&
        encryption.isNotEmpty &&
        encryption != 'none') {
      proxy['encryption'] = encryption;
    }
  }
  final flow = user['flow'] ?? settings['flow'];
  if (flow is String && flow.isNotEmpty) {
    proxy['flow'] = flow;
  }
  return proxy;
}

Map<String, dynamic>? _convertTrojan(Map<dynamic, dynamic> settings) {
  var server = settings;
  final servers = settings['servers'];
  if (servers is List && servers.isNotEmpty && servers.first is Map) {
    server = servers.first as Map<dynamic, dynamic>;
  }
  final address = server['address'];
  if (address is! String || address.isEmpty) return null;
  final rawPort = server['port'];
  final port = rawPort is int ? rawPort : int.tryParse('$rawPort');
  if (port == null || port <= 0 || port > 65535) return null;
  final password = server['password'];
  if (password is! String || password.isEmpty) return null;
  return <String, dynamic>{
    'type': 'trojan',
    'server': address,
    'port': port,
    'password': password,
    'udp': true,
  };
}

Map<String, dynamic>? _convertShadowsocks(Map<dynamic, dynamic> settings) {
  var server = settings;
  final servers = settings['servers'];
  if (servers is List && servers.isNotEmpty && servers.first is Map) {
    server = servers.first as Map<dynamic, dynamic>;
  }
  final address = server['address'];
  if (address is! String || address.isEmpty) return null;
  final rawPort = server['port'];
  final port = rawPort is int ? rawPort : int.tryParse('$rawPort');
  if (port == null || port <= 0 || port > 65535) return null;
  final method = server['method'] ?? server['cipher'];
  final password = server['password'];
  if (method is! String ||
      method.isEmpty ||
      password is! String ||
      password.isEmpty) {
    return null;
  }
  return <String, dynamic>{
    'type': 'ss',
    'server': address,
    'port': port,
    'cipher': method,
    'password': password,
    'udp': true,
  };
}

/// Панели отдают hysteria2 в том числе как protocol "hysteria" c
/// hysteriaSettings.version = 2 (Xray 25.x), иногда с QUIC-обфускацией
/// salamander внутри streamSettings.finalmask.
Map<String, dynamic>? _convertHysteria2(
  Map<dynamic, dynamic> settings,
  Map<dynamic, dynamic> stream,
) {
  final address = settings['address'];
  if (address is! String || address.isEmpty) return null;
  final rawPort = settings['port'];
  final port = rawPort is int ? rawPort : int.tryParse('$rawPort');
  if (port == null || port <= 0 || port > 65535) return null;
  final hysteriaSettings = stream['hysteriaSettings'] is Map
      ? stream['hysteriaSettings'] as Map<dynamic, dynamic>
      : const <dynamic, dynamic>{};
  final rawVersion = hysteriaSettings['version'] ?? settings['version'];
  final version = rawVersion is int ? rawVersion : int.tryParse('$rawVersion');
  if (version != null && version != 2) return null;
  final auth = hysteriaSettings['auth'] ??
      settings['auth'] ??
      settings['password'];
  if (auth is! String || auth.isEmpty) return null;

  final proxy = <String, dynamic>{
    'type': 'hysteria2',
    'server': address,
    'port': port,
    'password': auth,
  };
  final tls = stream['tlsSettings'];
  if (tls is Map) {
    final sni = tls['serverName'];
    if (sni is String && sni.isNotEmpty) proxy['sni'] = sni;
    final inner = tls['settings'];
    if (inner is Map && inner['allowInsecure'] == true) {
      proxy['skip-cert-verify'] = true;
    }
    final alpn = tls['alpn'];
    if (alpn is List && alpn.isNotEmpty) {
      proxy['alpn'] = alpn.whereType<String>().toList();
    }
  }
  final finalmask = stream['finalmask'];
  if (finalmask is Map) {
    final udp = finalmask['udp'];
    if (udp is List) {
      for (final item in udp) {
        if (item is Map &&
            item['type'] == 'salamander' &&
            item['settings'] is Map) {
          final obfsPassword = (item['settings'] as Map)['password'];
          if (obfsPassword is String && obfsPassword.isNotEmpty) {
            proxy['obfs'] = 'salamander';
            proxy['obfs-password'] = obfsPassword;
          }
        }
      }
    }
  }
  return proxy;
}

/// Применяет streamSettings (tls/reality/транспорт).
/// false — транспорт не поддерживается ядром, outbound пропускается.
bool _applyStream(Map<String, dynamic> proxy, Map<dynamic, dynamic> stream) {
  final security =
      stream['security'] is String ? stream['security'] as String : '';
  final network =
      stream['network'] is String ? stream['network'] as String : 'tcp';

  if (security == 'reality') {
    proxy['tls'] = true;
    final rs = stream['realitySettings'];
    if (rs is Map) {
      final sni = rs['serverName'];
      if (sni is String && sni.isNotEmpty) proxy['servername'] = sni;
      final fp = rs['fingerprint'];
      if (fp is String && fp.isNotEmpty) proxy['client-fingerprint'] = fp;
      final realityOpts = <String, dynamic>{};
      final publicKey = rs['publicKey'];
      if (publicKey is String && publicKey.isNotEmpty) {
        realityOpts['public-key'] = publicKey;
      }
      final shortId = rs['shortId'];
      if (shortId is String && shortId.isNotEmpty) {
        realityOpts['short-id'] = shortId;
      }
      if (realityOpts.isNotEmpty) proxy['reality-opts'] = realityOpts;
    }
    // uTLS-отпечаток для reality в mihomo обязателен
    if (!proxy.containsKey('client-fingerprint')) {
      proxy['client-fingerprint'] = 'chrome';
    }
  } else if (security == 'tls') {
    proxy['tls'] = true;
    final ts = stream['tlsSettings'];
    if (ts is Map) {
      final sni = ts['serverName'];
      if (sni is String && sni.isNotEmpty) proxy['servername'] = sni;
      final fp = ts['fingerprint'];
      if (fp is String && fp.isNotEmpty) proxy['client-fingerprint'] = fp;
      final alpn = ts['alpn'];
      if (alpn is List && alpn.isNotEmpty) {
        proxy['alpn'] = alpn.whereType<String>().toList();
      }
      final inner = ts['settings'];
      if (inner is Map && inner['allowInsecure'] == true) {
        proxy['skip-cert-verify'] = true;
      }
      if (ts['allowInsecure'] == true) proxy['skip-cert-verify'] = true;
    }
  } else if (security.isNotEmpty && security != 'none') {
    return false;
  }

  switch (network) {
    case 'tcp':
    case '':
      final tcp = stream['tcpSettings'];
      if (tcp is Map && tcp['header'] is Map) {
        final header = tcp['header'] as Map<dynamic, dynamic>;
        if (header['type'] == 'http') {
          proxy['network'] = 'http';
          final httpOpts = <String, dynamic>{};
          final request = header['request'] is Map
              ? header['request'] as Map<dynamic, dynamic>
              : const <dynamic, dynamic>{};
          final path = request['path'];
          if (path is List && path.isNotEmpty) {
            httpOpts['path'] = path.whereType<String>().toList();
          }
          final headers = request['headers'];
          if (headers is Map && headers['Host'] is List) {
            httpOpts['headers'] = <String, dynamic>{
              'Host': (headers['Host'] as List).whereType<String>().toList(),
            };
          }
          if (httpOpts.isNotEmpty) proxy['http-opts'] = httpOpts;
        }
      }
      break;
    case 'ws':
      proxy['network'] = 'ws';
      final ws = stream['wsSettings'];
      if (ws is Map) {
        final wsOpts = <String, dynamic>{};
        final path = ws['path'];
        if (path is String && path.isNotEmpty) wsOpts['path'] = path;
        final headers = ws['headers'];
        if (headers is Map) {
          final host = headers['Host'] ?? headers['host'];
          if (host is String && host.isNotEmpty) {
            wsOpts['headers'] = <String, dynamic>{'Host': host};
          }
        }
        if (wsOpts.isNotEmpty) proxy['ws-opts'] = wsOpts;
      }
      break;
    case 'grpc':
      proxy['network'] = 'grpc';
      final grpc = stream['grpcSettings'];
      if (grpc is Map) {
        final serviceName = grpc['serviceName'];
        if (serviceName is String && serviceName.isNotEmpty) {
          proxy['grpc-opts'] = <String, dynamic>{
            'grpc-service-name': serviceName,
          };
        }
      }
      break;
    case 'xhttp':
    case 'splithttp':
      proxy['network'] = 'xhttp';
      final xs = stream['xhttpSettings'] ?? stream['splithttpSettings'];
      final xhttpOpts = <String, dynamic>{};
      if (xs is Map) {
        // Панели (например FishVPN/v2raytun) кладут расширенные параметры
        // во вложенный map 'extra'. Верхний уровень — лишь краткая сводка
        // (path/host/mode). Сливаем: значения из extra перекрывают верхний
        // уровень, пустые/null не переносим.
        final eff = Map<dynamic, dynamic>.from(xs);
        final extra = xs['extra'];
        if (extra is Map) {
          extra.forEach((k, v) {
            if (v == null || v == '') return;
            eff[k] = v;
          });
        }

        void putStr(String from, String to) {
          final v = eff[from];
          if (v is String && v.isNotEmpty) xhttpOpts[to] = v;
        }

        putStr('path', 'path');
        putStr('host', 'host');
        putStr('mode', 'mode');
        putStr('xPaddingBytes', 'x-padding-bytes');
        if (eff['xPaddingObfsMode'] == true) {
          xhttpOpts['x-padding-obfs-mode'] = true;
        }
        putStr('xPaddingKey', 'x-padding-key');
        putStr('xPaddingHeader', 'x-padding-header');
        putStr('xPaddingPlacement', 'x-padding-placement');
        putStr('xPaddingMethod', 'x-padding-method');
        putStr('uplinkHTTPMethod', 'uplink-http-method');
        putStr('uplinkDataKey', 'uplink-data-key');
        putStr('uplinkDataPlacement', 'uplink-data-placement');
        putStr('uplinkChunkSize', 'uplink-chunk-size');
        putStr('seqKey', 'seq-key');
        putStr('seqPlacement', 'seq-placement');
        putStr('sessionIDKey', 'session-key');
        putStr('sessionIDPlacement', 'session-placement');
        putStr('sessionIDLength', 'session-length');
        putStr('scMaxEachPostBytes', 'sc-max-each-post-bytes');
        putStr('scMinPostsIntervalMs', 'sc-min-posts-interval-ms');
        if (eff['noGRPCHeader'] == true) xhttpOpts['no-grpc-header'] = true;
        final xmux = eff['xmux'];
        if (xmux is Map && xmux.isNotEmpty) {
          final reuse = <String, dynamic>{};
          // В ядре эти поля — строки (диапазоны «16-32»), число приводим к
          // строке; нули пропускаем (в Xray это «без лимита»).
          void putReuse(String from, String to) {
            final v = xmux[from];
            if (v is String && v.isNotEmpty) {
              reuse[to] = v;
            } else if (v is int && v != 0) {
              reuse[to] = '$v';
            }
          }

          putReuse('maxConcurrency', 'max-concurrency');
          putReuse('maxConnections', 'max-connections');
          putReuse('cMaxReuseTimes', 'c-max-reuse-times');
          putReuse('hMaxRequestTimes', 'h-max-request-times');
          putReuse('hMaxReusableSecs', 'h-max-reusable-secs');
          final keepAlive = xmux['hKeepAlivePeriod'];
          if (keepAlive is int) reuse['h-keep-alive-period'] = keepAlive;
          if (reuse.isNotEmpty) xhttpOpts['reuse-settings'] = reuse;
        }

        // Дефолты, которые Xray проставляет в infra/conf
        // (transport_method.go Build), а ядро mihomo — НЕТ. Критичен
        // первый: при uplinkDataPlacement=header без ключа ядро кладёт
        // данные в заголовки «-0», «-1» — сервер их не находит и молча
        // держит соединение до таймаута (узлы «От глушилок» FishVPN).
        final uplPlacement = xhttpOpts['uplink-data-placement'];
        final uplStr = uplPlacement is String && uplPlacement.isNotEmpty
            ? uplPlacement
            : 'body';
        if (uplStr != 'body' && !xhttpOpts.containsKey('uplink-data-key')) {
          xhttpOpts['uplink-data-key'] =
              uplStr == 'cookie' ? 'x_data' : 'X-Data';
        }
        final seqPlacement = xhttpOpts['seq-placement'];
        if (seqPlacement is String &&
            seqPlacement.isNotEmpty &&
            seqPlacement != 'path' &&
            !xhttpOpts.containsKey('seq-key')) {
          xhttpOpts['seq-key'] = seqPlacement == 'header' ? 'X-Seq' : 'x_seq';
        }
        final sessPlacement = xhttpOpts['session-placement'];
        if (sessPlacement is String &&
            sessPlacement.isNotEmpty &&
            sessPlacement != 'path' &&
            !xhttpOpts.containsKey('session-key')) {
          xhttpOpts['session-key'] =
              sessPlacement == 'header' ? 'X-Session' : 'x_session';
        }
      }
      if (xhttpOpts.isNotEmpty) proxy['xhttp-opts'] = xhttpOpts;
      break;
    case 'h2':
    case 'http2':
      proxy['network'] = 'h2';
      final hs = stream['httpSettings'];
      if (hs is Map) {
        final h2Opts = <String, dynamic>{};
        final host = hs['host'];
        if (host is List && host.isNotEmpty) {
          h2Opts['host'] = host.whereType<String>().toList();
        }
        final path = hs['path'];
        if (path is String && path.isNotEmpty) h2Opts['path'] = path;
        if (h2Opts.isNotEmpty) proxy['h2-opts'] = h2Opts;
      }
      break;
    default:
      // kcp/quic/httpupgrade и прочие ядром не поддерживаются
      return false;
  }
  return true;
}
