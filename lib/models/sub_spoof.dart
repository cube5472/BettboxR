// Подмена клиента при загрузке подписки.
//
// Некоторые панели провайдеров (Remnawave, RU-бот-панели) фильтруют
// подписки по User-Agent и идентификатору устройства — разрешают
// только «одобренные» приложения. При включённой подмене панель
// НЕ ОТЛИЧАЕТ запрос BettboxR от запроса Happ / v2RayTun / Incy
// (тот же UA, те же заголовки, тот же формат X-Hwid) — она видит
// обычный одобренный клиент, а не BettboxR.
// Отпечатки — подлинные UA/заголовки реальных клиентов; источник
// сверки — форк NekoBoxPlus, где они захардкожены 1:1 с реальными
// приложениями:
//  - Happ (Android): «Happ/3.26.3/Android/<20 цифр>» + заголовок
//    X-Hwid (16 строчных hex) + X-Device-Model/X-Ver-Os/
//    X-Device-Os/X-Device-Locale;
//  - v2RayTun: «v2raytun/android» + X-App-Version: 5.25.80 +
//    X-Device-Model/X-Ver-Os («Android <SDK>»)/X-Device-Os;
//    X-Hwid — 16 ВЕРХНИХ hex;
//  - Incy: «INCY/3.4.3/android Dalvik/2.1.0» + X-Client: INCY,
//    X-App-Version: 3.4.3, X-Device-Locale (ru_RU), Accept,
//    Accept-Language; X-Hwid — UUID-формат (8-4-4-4-12, ВЕРХНИЙ).
// Панель отвечает маркерами x-hwid-limit / x-hwid-max-devices-reached /
// x-hwid-not-supported — их же читает референсный клиент.
// HWID — стабильный идентификатор: генерируется один раз и хранится
// вместе с настройками профиля, чтобы панели с device-limit считали
// каждое обновление подписки тем же устройством.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bett_box/common/common.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';

const kSubSpoofStoreKey = 'sub_spoof_map';

/// id пресета -> User-Agent реального клиента.
/// Значения — точные UA из работающего референсного клиента.
const kSubSpoofClients = <String, String>{
  'happ': 'Happ/3.26.3/Android/17839452147361875676',
  'v2raytun': 'v2raytun/android',
  'incy': 'INCY/3.4.3/android Dalvik/2.1.0',
};

/// Пресеты, для которых передаётся X-Hwid (референс шлёт его для
/// любого выбранного клиента при включённом hwid).
const kSubSpoofHwidClients = <String>['happ', 'incy', 'v2raytun'];

/// Читаемые названия пресетов для UI.
const kSubSpoofClientLabels = <String, String>{
  'happ': 'Happ',
  'v2raytun': 'v2RayTun',
  'incy': 'Incy',
};

/// Старые ключи/UA (до отпечатков референса) -> текущий пресет.
/// Нужно, чтобы конфиги и настройки, сохранённые прежней версией,
/// продолжали маскировку после обновления.
const kSubSpoofClientAliases = <String, String>{
  'v2rayng': 'v2raytun',
};

const kSubSpoofLegacyUa = <String, String>{
  'Happ/4.6.1/': 'happ',
  'v2rayNG/2.3.9': 'v2raytun',
  'INCY/1.0.0': 'incy',
};

/// Нейтральный «проверенный» UA для резервной загрузки провайдеров:
/// под v2rayNG панели отдают полный plain-список ссылок, который ядро
/// разбирает само (ConvertsV2Ray), и обычно НЕ требуют X-Hwid. Используется,
/// когда запрос с подменой (или без неё) не дал тела, пригодного для ядра.
const kSubSpoofFallbackUa = 'v2rayNG/1.9.16';

String normalizeSubSpoofClient(String client) {
  final key = client.trim().toLowerCase();
  if (kSubSpoofClients.containsKey(key)) {
    return key;
  }
  return kSubSpoofClientAliases[key] ?? '';
}

class SubSpoof {
  final String client;
  final String customUa;
  final String hwid;

  const SubSpoof({
    this.client = '',
    this.customUa = '',
    this.hwid = '',
  });

  factory SubSpoof.fromJson(Map<String, dynamic> json) => SubSpoof(
        client: normalizeSubSpoofClient('${json['client'] ?? ''}'),
        customUa: json['customUa'] as String? ?? '',
        hwid: json['hwid'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'client': client,
        'customUa': customUa,
        'hwid': hwid,
      };

  bool get isEnabled =>
      client.isNotEmpty && kSubSpoofClients.containsKey(client);

  bool get needsHwid => kSubSpoofHwidClients.contains(client);

  String get effectiveUa {
    final ua = customUa.trim();
    if (ua.isNotEmpty) {
      return ua;
    }
    return kSubSpoofClients[client] ?? '';
  }

  /// Заголовки для запроса подписки; null — подмена выключена.
  /// Без device-заголовков (они добавляются в [resolveHeaders]).
  /// Как в референсе: устаревший UA старого Happ заменяется текущим
  /// пресетом (нормализация [kSubSpoofLegacyHappUa]).
  Map<String, String>? buildHeaders() {
    if (!isEnabled) {
      return null;
    }
    var ua = effectiveUa;
    if (client == 'happ' && ua == kSubSpoofLegacyHappUa) {
      ua = kSubSpoofClients['happ']!;
    }
    if (ua.isEmpty) {
      return null;
    }
    final headers = <String, String>{'User-Agent': ua};
    final id = formatSubSpoofHwid(client, hwid);
    if (needsHwid && id.isNotEmpty) {
      headers['X-Hwid'] = id;
    }
    return headers;
  }

  /// Полный набор заголовков реального клиента: UA + device-заголовки
  /// (модель/SDK/локаль) + X-Hwid ПОСЛЕДНИМ — порядок 1:1 с референсом
  /// (buildSubscriptionRequestFingerprint ставит X-Hwid после всех).
  /// Если пресет требует hwid, а значение не задано — подставляется
  /// стабильный id устройства ([generateSubSpoofHwid]): как в
  /// референсе, где HWID включается тумблером и шлётся всегда.
  Future<Map<String, String>?> resolveHeaders() async {
    var spoof = this;
    if (!spoof.isEnabled) {
      return null;
    }
    if (spoof.needsHwid &&
        formatSubSpoofHwid(spoof.client, spoof.hwid).isEmpty) {
      spoof = spoof.copyWith(hwid: await generateSubSpoofHwid());
    }
    var ua = spoof.effectiveUa;
    if (spoof.client == 'happ' && ua == kSubSpoofLegacyHappUa) {
      ua = kSubSpoofClients['happ']!;
    }
    if (ua.isEmpty) {
      return null;
    }
    final headers = <String, String>{'User-Agent': ua};
    final dev = await resolveSpoofDeviceContext();
    if (dev != null) {
      headers.addAll(buildSpoofExtraHeaders(spoof.client, dev));
    }
    final id = formatSubSpoofHwid(spoof.client, spoof.hwid);
    if (spoof.needsHwid && id.isNotEmpty) {
      headers['X-Hwid'] = id;
    }
    return headers;
  }

  SubSpoof copyWith({
    String? client,
    String? customUa,
    String? hwid,
  }) {
    return SubSpoof(
      client: client ?? this.client,
      customUa: customUa ?? this.customUa,
      hwid: hwid ?? this.hwid,
    );
  }
}

/// Устаревший UA старого Happ: референс заменяет его на актуальный
/// пресет при отправке (normalizeSpoofUserAgent).
const kSubSpoofLegacyHappUa = 'Happ/3.17.0/Android/17756505247711753599';

/// Суффикс в формуле hwid — ФОРМУЛА 1:1 С РЕФЕРЕНСОМ (neko+,
/// HwidGenerator.generate$app): SHA-256(android_id + "NekoBoxPlus"),
/// из hex-строки берутся первые 16 (happ) / 16 ВЕРХНИХ (v2raytun) /
/// 32 ВЕРХНИХ в виде 8-4-4-4-12 (incy).
/// android_id у каждого приложения СВОЙ (Android выдаёт значение
/// на пару «устройство + подпись приложения»), поэтому авто-hwid
/// BettboxR не совпадает с hwid neko+ на том же телефоне: панель с
/// привязкой устройств сочтёт его новым. Чтобы панель считала
/// BettboxR устройством, с которого подписка уже работает в neko+,
/// впишите его X-Hwid в поле подмены вручную — пользовательское
/// значение уходит на панель ВЕРБАТИМНО (см. [formatSubSpoofHwid]).
/// Панель видит только готовый hex X-Hwid и заголовки выбранного
/// клиента — сама формула (и суффикс) ей недоступна.
const kSubSpoofHwidAppSuffix = 'NekoBoxPlus';

const MethodChannel _deviceChannel = MethodChannel('code_forge/device');
bool _androidIdResolved = false;
String _cachedAndroidId = '';

/// Ключ хранения резервного id устройства (когда android_id недоступен).
const _kSubSpoofFallbackDeviceKey = 'sub_spoof_fallback_device';

/// android_id этого приложения (Settings.Secure.ANDROID_ID) через
/// нативный канал; пусто — если система не отдала (редкий случай).
Future<String> _resolveAndroidId() async {
  if (_androidIdResolved) {
    return _cachedAndroidId;
  }
  _androidIdResolved = true;
  try {
    final value = await _deviceChannel.invokeMethod<String>('getAndroidId');
    _cachedAndroidId = value ?? '';
  } catch (_) {
    _cachedAndroidId = '';
  }
  return _cachedAndroidId;
}

/// Fallback: случайный валидный 32-hex (когда android_id недоступен).
String _randomHwid32() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Стабильный id устройства для формулы hwid: android_id, а если он
/// недоступен — резервное значение, сгенерированное ОДИН раз и
/// сохранённое в настройках. Резерв обязан быть стабильным: панели с
/// привязкой по X-Hwid считают каждый новый id новым устройством, и
/// «случайный на каждый запрос» выглядел бы для панели как новое
/// устройство при каждом обновлении подписки.
Future<String> _resolveStableDeviceId() async {
  final androidId = await _resolveAndroidId();
  if (androidId.isNotEmpty) {
    return androidId;
  }
  try {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    if (prefs != null) {
      final saved = prefs.getString(_kSubSpoofFallbackDeviceKey);
      if (saved != null && saved.isNotEmpty) {
        return saved;
      }
      final generated = _randomHwid32();
      await prefs.setString(_kSubSpoofFallbackDeviceKey, generated);
      return generated;
    }
  } catch (_) {}
  return _randomHwid32();
}

/// Стабильный hwid устройства — SHA-256(android_id + суффикс),
/// первые 32 hex (ровно столько берёт референс для самого длинного
/// формата — incy). Значение у этого приложения на этом устройстве
/// ОДНО И ТО ЖЕ всегда, панели с device-limit видят каждый запрос
/// одним и тем же «устройством» (аналог тумблера «Поддержка HWID»
/// референса). «Сырые» 32 hex; формат пресета (16 hex / 16 HEX /
/// UUID) применяет [formatSubSpoofHwid].
Future<String> generateSubSpoofHwid() async {
  final deviceId = await _resolveStableDeviceId();
  return sha256
      .convert(utf8.encode('$deviceId$kSubSpoofHwidAppSuffix'))
      .toString()
      .substring(0, 32);
}

/// Прямой защищённый фетч нативной стороной (VpnService.protect):
/// сокет выводится из-под собственного TUN до connect, DNS системный.
/// Используется как резерв, когда обычный путь (через ядро) упал —
/// запрос тогда неотличим от запроса обычного приложения без VPN.
/// Возвращает {status:int, headers:{name:value}, body:base64} или
/// {error: string} при неудаче; null — канал недоступен.
Future<Map<String, dynamic>?> protectedFetchNative(
  String url,
  Map<String, String> headers,
) async {
  try {
    final res = await _deviceChannel
        .invokeMethod<Map<Object?, Object?>>(
      'protectedFetch',
      {'url': url, 'headers': headers},
    );
    if (res == null) {
      return null;
    }
    return res.cast<String, Object?>();
  } catch (_) {
    return null;
  }
}

/// Формат X-Hwid под пресет — как в референсном клиенте:
///  - happ: 16 строчных hex;
///  - v2raytun: 16 ВЕРХНИХ hex;
///  - incy: UUID-формат (8-4-4-4-12) из 32 hex, ВЕРХНИЙ.
///
/// Форматирование применяется ТОЛЬКО к автосгенерированному
/// 32-hex идентификатору. Всё, что пользователь вписал вручную
/// (например X-Hwid, снятый с уже зарегистрированного на панели
/// клиента — neko+, Happ), уходит ВЕРБАТИМНО: панели проверяют
/// точное значение заголовка, и любая «нормализация» сделала бы
/// перенос отпечатка невозможным.
String formatSubSpoofHwid(String client, String rawHwid) {
  final trimmed = rawHwid.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  // Автогенерация — ровно 32 hex-символа без разделителей.
  if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(trimmed)) {
    return trimmed;
  }
  final hex = trimmed.toLowerCase();
  switch (client) {
    case 'happ':
      return hex.padRight(16, '0').substring(0, 16);
    case 'v2raytun':
      return hex.padRight(16, '0').substring(0, 16).toUpperCase();
    case 'incy':
      final t = hex.padRight(32, '0').substring(0, 32).toUpperCase();
      return '${t.substring(0, 8)}-${t.substring(8, 12)}-'
          '${t.substring(12, 16)}-${t.substring(16, 20)}-'
          '${t.substring(20, 32)}';
  }
  return rawHwid.trim();
}

/// Сведения об устройстве для device-заголовков реального клиента.
class SpoofDeviceContext {
  /// «производитель модель» — как референс шлёт для v2raytun/incy.
  final String model;

  /// Только модель (Build.MODEL) — референс шлёт её для Happ.
  final String modelShort;
  final int sdkInt;
  final String language;
  final String languageTag;
  final String localeName;

  const SpoofDeviceContext({
    required this.model,
    required this.modelShort,
    required this.sdkInt,
    required this.language,
    required this.languageTag,
    required this.localeName,
  });
}

/// Резолв устройства: только Android — отпечатки референса
/// андроидные. На остальных платформах device-заголовки не шлём
/// (остаются UA + X-Hwid). Ошибки глушим — подмена не должна
/// ломать загрузку подписки.
Future<SpoofDeviceContext?> resolveSpoofDeviceContext() async {
  if (!Platform.isAndroid) {
    return null;
  }
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    final manufacturer = info.manufacturer.trim();
    final model = info.model.trim();
    final fullModel = '$manufacturer $model'.trim();
    final localeName = Platform.localeName.replaceAll('-', '_');
    final parts = localeName.split('_');
    final language = parts.isNotEmpty ? parts.first : 'en';
    final languageTag = parts.length > 1 ? '$language-${parts[1]}' : language;
    return SpoofDeviceContext(
      model: fullModel.isEmpty ? 'Android' : fullModel,
      modelShort: model,
      sdkInt: info.version.sdkInt,
      language: language,
      languageTag: languageTag,
      localeName: localeName,
    );
  } catch (_) {
    return null;
  }
}

/// Device-заголовки реальных клиентов — наборы 1:1 из референса:
///  - Happ: модель (Build.MODEL, без производителя), SDK-число, ОС, язык;
///  - v2RayTun: версия приложения 5.25.80, «производитель модель»,
///    «Android <SDK>», ОС;
///  - Incy: Accept/Accept-Language, X-Client, локаль ru_RU,
///    версия 3.4.3, «производитель модель», SDK-число, ОС.
Map<String, String> buildSpoofExtraHeaders(
  String client,
  SpoofDeviceContext dev,
) {
  switch (client) {
    case 'happ':
      return <String, String>{
        'X-Device-Model': dev.modelShort.isNotEmpty ? dev.modelShort : dev.model,
        'X-Ver-Os': '${dev.sdkInt}',
        'X-Device-Os': 'Android',
        'X-Device-Locale': dev.language,
      };
    case 'v2raytun':
      return <String, String>{
        'X-App-Version': '5.25.80',
        'X-Device-Model': dev.model,
        'X-Ver-Os': 'Android ${dev.sdkInt}',
        'X-Device-Os': 'Android',
      };
    case 'incy':
      return <String, String>{
        'Accept': '*/*',
        'Accept-Language': dev.languageTag,
        'X-Client': 'INCY',
        'X-Device-Locale': dev.localeName,
        'X-App-Version': '3.4.3',
        'X-Device-Model': dev.model,
        'X-Ver-Os': '${dev.sdkInt}',
        'X-Device-Os': 'Android',
      };
  }
  return const <String, String>{};
}

class SubSpoofStore {
  /// Ключ глобальной клиентской подмены (Настройки → Общие →
  /// «Подмена клиента подписок»). Не может совпасть с id профиля:
  /// id профиля — миллисекунды timestamp.
  static const globalKey = '__global__';

  static Future<Map<String, dynamic>> _readRawMap() async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    final raw = prefs?.getString(kSubSpoofStoreKey);
    if (raw == null || raw.isEmpty) {
      return {};
    }
    try {
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return {};
  }

  static Future<SubSpoof> get(String profileId) async {
    try {
      final rawMap = await _readRawMap();
      final entry = rawMap[profileId];
      if (entry is Map) {
        return SubSpoof.fromJson(Map<String, dynamic>.from(entry));
      }
    } catch (_) {}
    return const SubSpoof();
  }

  static Future<void> save(String profileId, SubSpoof spoof) async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    if (prefs == null) {
      return;
    }
    final rawMap = await _readRawMap();
    rawMap[profileId] = spoof.toJson();
    await prefs.setString(kSubSpoofStoreKey, json.encode(rawMap));
  }

  static Future<void> remove(String profileId) async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    if (prefs == null) {
      return;
    }
    final rawMap = await _readRawMap();
    if (rawMap.remove(profileId) != null) {
      await prefs.setString(kSubSpoofStoreKey, json.encode(rawMap));
    }
  }

  /// Глобальная клиентская подмена: действует для ВСЕХ подписок,
  /// где не задана индивидуальная настройка профиля.
  static Future<SubSpoof> getGlobal() => get(globalKey);

  static Future<void> saveGlobal(SubSpoof spoof) =>
      save(globalKey, spoof);
}

/// Эффективная подмена профиля: индивидуальная настройка профиля
/// сильнее; при её отсутствии применяется глобальная клиентская.
Future<SubSpoof> resolveEffectiveSubSpoof(String profileId) async {
  final own = await SubSpoofStore.get(profileId);
  if (own.isEnabled) {
    return own;
  }
  return SubSpoofStore.getGlobal();
}

/// Результат нормализации тела подписки/провайдера.
class SubNormalizedBody {
  /// Тело в формате, который ядро разбирает в proxy-provider.
  final String body;

  /// Человекочитаемое имя формата (для журнала).
  final String format;

  /// Число распознанных нод/ссылок (0 — не подсчитывалось).
  final int nodes;

  const SubNormalizedBody(this.body, this.format, this.nodes);
}

final RegExp _spoofSubHtmlRe = RegExp(
  r'^\s*(<!DOCTYPE|<html)',
  caseSensitive: false,
);

/// YAML-значение -> обычные Dart-структуры (для jsonEncode: YamlMap
/// и YamlList не сериализуются стандартным кодировщиком).
dynamic _yamlToPlain(dynamic value) {
  if (value is YamlMap) {
    return <String, dynamic>{
      for (final entry in value.entries)
        '${entry.key}': _yamlToPlain(entry.value),
    };
  }
  if (value is YamlList) {
    return value.map(_yamlToPlain).toList();
  }
  return value;
}

/// Приводит тело подписки к виду, который ядро (mihomo) разбирает
/// в proxy-provider: конфиг с proxies:, base64 либо plain-список
/// share-ссылок. Панели для «чужих» клиентов (включая UA ядра и
/// некоторые пресеты подмены) могут отдавать YAML/JSON-СПИСОК ссылок
/// или нод — ядро такой формат не понимает («cannot unmarshal !!seq
/// into provider.ProxySchema»), поэтому список раскрывается здесь.
/// null — тело не распознано (HTML-страница, отказ панели,
/// неизвестная структура): вызывателю стоит залогировать начало тела
/// и не трогать файл провайдера, оставив ядро работать как раньше.
SubNormalizedBody? normalizeSubProviderBody(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  if (_spoofSubHtmlRe.hasMatch(trimmed)) {
    return null;
  }
  final seenNames = <String>{};
  try {
    final parsed = loadYaml(trimmed);
    if (parsed is YamlList) {
      final items = parsed.toList();
      if (items.isEmpty) {
        return null;
      }
      final links = <String>[];
      final nodes = <Map<String, dynamic>>[];
      for (final item in items) {
        if (item is String && item.contains('://')) {
          links.add(item.trim());
          continue;
        }
        if (item is YamlMap) {
          final plain = Map<String, dynamic>.from(
            _yamlToPlain(item) as Map,
          );
          final node = convertSubNodeToClash(plain);
          if (node != null) {
            nodes.add(node);
          }
        }
      }
      if (nodes.isNotEmpty) {
        // Список нод -> конфиг с proxies:. JSON-кодирование даёт
        // валидный YAML (flow-отображения), экранируя любые значения.
        final buffer = StringBuffer('proxies:');
        for (final node in nodes) {
          _spoofUniqueNodeName(node, seenNames);
          buffer.write('\n  - ${jsonEncode(node)}');
        }
        return SubNormalizedBody(
          buffer.toString(),
          'yaml-node-list',
          nodes.length,
        );
      }
      if (links.isNotEmpty && links.length == items.length) {
        // Список ссылок -> plain-список: ядро парсит его само.
        return SubNormalizedBody(links.join('\n'), 'share-links', links.length);
      }
      return null;
    }
    if (parsed is YamlMap) {
      if (parsed.containsKey('proxies')) {
        final proxies = parsed['proxies'];
        return SubNormalizedBody(
          trimmed,
          'clash-yaml',
          proxies is YamlList ? proxies.length : 0,
        );
      }
      // Полный клиентский JSON/YAML-конфиг (sing-box / Xray): ноды
      // лежат в outbounds — конвертируем в proxies:.
      final outbounds = parsed['outbounds'];
      if (outbounds is YamlList) {
        final nodes = <Map<String, dynamic>>[];
        for (final item in outbounds) {
          if (item is! YamlMap) {
            continue;
          }
          final plain = Map<String, dynamic>.from(
            _yamlToPlain(item) as Map,
          );
          final node = convertSubNodeToClash(plain);
          if (node != null) {
            nodes.add(node);
          }
        }
        if (nodes.isNotEmpty) {
          final buffer = StringBuffer('proxies:');
          for (final node in nodes) {
            _spoofUniqueNodeName(node, seenNames);
            buffer.write('\n  - ${jsonEncode(node)}');
          }
          return SubNormalizedBody(
            buffer.toString(),
            'client-config',
            nodes.length,
          );
        }
      }
      // YAML-отображение без proxies — не тело провайдера.
      return null;
    }
  } catch (_) {
    // Не YAML: share-ссылки построчно / base64 / одиночная ссылка —
    // ядро разбирает это само (ConvertsV2Ray).
  }
  return SubNormalizedBody(trimmed, 'raw', 0);
}

// ---------------- Ноды клиентских форматов -> clash ----------------
//
// Панели под «свои» клиенты отдают список нод объектами:
//  - sing-box outbounds ({type, tag, server, server_port, tls, transport});
//  - Xray-клиент ({protocol, settings.vnext/servers, streamSettings});
//  - плоский клиентский JSON ({protocol, address, port, id, sni, pbk…}).
// Ядро такие списки не разбирает («!!seq»), каждая нода приводится
// здесь к clash-схеме. Неизвестные типы/поля отбрасываются: одна
// неопознанная нода не роняет остальные.

const _spoofNodeNameKeys = ['name', 'remark', 'remarks', 'ps', 'tag', 'title'];
const _spoofNodeHostKeys = ['server', 'address', 'add', 'server-host'];
const _spoofNodePortKeys = ['port', 'server_port', 'server-port'];

String? _spoofNodeString(Map<String, dynamic> node, List<String> keys) {
  for (final key in keys) {
    final value = node[key];
    if (value == null) {
      continue;
    }
    final text = '$value'.trim();
    if (text.isNotEmpty && text != 'null') {
      return text;
    }
  }
  return null;
}

int? _spoofNodePort(Map<String, dynamic> node) {
  for (final key in _spoofNodePortKeys) {
    final value = node[key];
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) {
        return parsed;
      }
    }
  }
  return null;
}

Map<String, dynamic>? _spoofNodeMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

List<String>? _spoofNodeStringList(dynamic value) {
  if (value is String) {
    final parts = value
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return parts.isEmpty ? null : parts;
  }
  if (value is List && value.isNotEmpty) {
    final parts = value.map((e) => '$e'.trim()).where((e) => e.isNotEmpty);
    final result = parts.toList();
    return result.isEmpty ? null : result;
  }
  return null;
}

/// Уникальное имя ноды: пустое/без имени -> «Node N», дубликаты —
/// с номером (ядро отбрасывает ноды с совпадающими именами).
void _spoofUniqueNodeName(Map<String, dynamic> node, Set<String> seen) {
  var name = '${node['name'] ?? ''}'.trim();
  if (name.isEmpty) {
    name = 'Node';
  }
  var candidate = name;
  var index = 2;
  while (seen.contains(candidate)) {
    candidate = '$name $index';
    index++;
  }
  seen.add(candidate);
  node['name'] = candidate;
}

/// Приводит одну ноду любого поддержанного клиентского формата к
/// clash-схеме. null — формат ноды не опознан.
Map<String, dynamic>? convertSubNodeToClash(Map<String, dynamic> node) {
  if (node.isEmpty) {
    return null;
  }
  // Уже clash-схема (name + type + server) — оставить как есть.
  final clashType = node['type'];
  if (clashType is String &&
      clashType.trim().isNotEmpty &&
      node['name'] is String &&
      _spoofNodePort(node) != null &&
      _spoofNodeString(node, _spoofNodeHostKeys) != null) {
    return Map<String, dynamic>.from(node);
  }
  final singBox = _convertSingBoxOutbound(node);
  if (singBox != null) {
    return singBox;
  }
  final xray = _convertXrayOutbound(node);
  if (xray != null) {
    return xray;
  }
  return _convertFlatClientNode(node);
}

/// sing-box outbound -> clash.
Map<String, dynamic>? _convertSingBoxOutbound(Map<String, dynamic> ob) {
  final type = '${ob['type'] ?? ''}'.trim().toLowerCase();
  if (type.isEmpty) {
    return null;
  }
  final server = _spoofNodeString(ob, _spoofNodeHostKeys);
  final port = _spoofNodePort(ob);
  if (server == null || port == null) {
    return null;
  }
  final clash = <String, dynamic>{
    'type': type,
    'server': server,
    'port': port,
  };
  switch (type) {
    case 'vless':
      final uuid = _spoofNodeString(ob, const ['uuid', 'id']);
      if (uuid == null) {
        return null;
      }
      clash['uuid'] = uuid;
      final flow = _spoofNodeString(ob, const ['flow']);
      if (flow != null) {
        clash['flow'] = flow;
      }
    case 'vmess':
      final uuid = _spoofNodeString(ob, const ['uuid', 'id']);
      if (uuid == null) {
        return null;
      }
      clash['uuid'] = uuid;
      final alterId = ob['alter_id'] ?? ob['alterId'];
      clash['alterId'] = alterId is num ? alterId.toInt() : 0;
      clash['cipher'] =
          _spoofNodeString(ob, const ['security', 'cipher']) ?? 'auto';
    case 'trojan':
      final password = _spoofNodeString(ob, const ['password']);
      if (password == null) {
        return null;
      }
      clash['password'] = password;
    case 'shadowsocks':
      final password = _spoofNodeString(ob, const ['password']);
      final cipher = _spoofNodeString(ob, const ['method', 'cipher']);
      if (password == null || cipher == null) {
        return null;
      }
      clash['password'] = password;
      clash['cipher'] = cipher;
    case 'hysteria2':
      final password = _spoofNodeString(ob, const ['password', 'auth']);
      if (password != null) {
        clash['password'] = password;
      }
      final obfs = _spoofNodeMap(ob['obfs']);
      if (obfs != null && '${obfs['type'] ?? ''}'.trim() == 'salamander') {
        clash['obfs'] = 'salamander';
        final obfsPassword = obfs['password'];
        if (obfsPassword != null) {
          clash['obfs-password'] = '$obfsPassword';
        }
      }
    case 'tuic':
      final uuid = _spoofNodeString(ob, const ['uuid']);
      final password = _spoofNodeString(ob, const ['password']);
      if (uuid != null) {
        clash['uuid'] = uuid;
      }
      if (password != null) {
        clash['password'] = password;
      }
      final congestion = _spoofNodeString(ob, const ['congestion_control']);
      if (congestion != null) {
        clash['congestion-controller'] = congestion;
      }
      clash['alpn'] =
          _spoofNodeStringList(ob['alpn']) ?? const ['h3'];
    default:
      return null;
  }
  final tls = _spoofNodeMap(ob['tls']);
  if (tls != null && tls['enabled'] == true) {
    _applyClashTlsFields(
      clash,
      sni: _spoofNodeString(tls, const ['server_name', 'serverName']),
      insecure: tls['insecure'] == true,
      alpn: _spoofNodeStringList(tls['alpn']),
      fingerprint:
          _spoofNodeString(tls, const ['fingerprint']) ??
              _spoofNodeString(
                _spoofNodeMap(tls['utls']) ?? const {},
                const ['fingerprint'],
              ),
      publicKey: _spoofNodeString(
        _spoofNodeMap(tls['reality']) ?? const {},
        const ['public_key', 'publicKey'],
      ),
      shortId: _spoofNodeString(
        _spoofNodeMap(tls['reality']) ?? const {},
        const ['short_id', 'shortId'],
      ),
    );
  }
  _applyClashTransport(
    clash,
    network: _spoofNodeString(ob, const ['network']),
    transport: _spoofNodeMap(ob['transport']),
  );
  clash['name'] =
      _spoofNodeString(ob, _spoofNodeNameKeys) ?? '$server:$port';
  return clash;
}

/// Xray-outbound (клиентский конфиг) -> clash.
Map<String, dynamic>? _convertXrayOutbound(Map<String, dynamic> ob) {
  final protocol = '${ob['protocol'] ?? ''}'.trim().toLowerCase();
  const supported = {'vless', 'vmess', 'trojan', 'shadowsocks'};
  if (!supported.contains(protocol)) {
    return null;
  }
  final settings = _spoofNodeMap(ob['settings']);
  if (settings == null) {
    return null;
  }
  Map<String, dynamic>? endpoint;
  final vnext = settings['vnext'];
  final servers = settings['servers'];
  if (vnext is List && vnext.isNotEmpty && vnext.first is Map) {
    endpoint = Map<String, dynamic>.from(vnext.first);
  } else if (servers is List && servers.isNotEmpty && servers.first is Map) {
    endpoint = Map<String, dynamic>.from(servers.first);
  }
  if (endpoint == null) {
    return null;
  }
  final server = _spoofNodeString(endpoint, const ['address', 'server']);
  final port = _spoofNodePort(endpoint);
  if (server == null || port == null) {
    return null;
  }
  final clash = <String, dynamic>{
    'type': protocol == 'shadowsocks' ? 'ss' : protocol,
    'server': server,
    'port': port,
  };
  if (protocol == 'shadowsocks') {
    final method = _spoofNodeString(endpoint, const ['method', 'cipher']);
    final password = _spoofNodeString(endpoint, const ['password']);
    if (method == null || password == null) {
      return null;
    }
    clash['cipher'] = method;
    clash['password'] = password;
  } else {
    final users = endpoint['users'];
    Map<String, dynamic> user = {};
    if (users is List && users.isNotEmpty && users.first is Map) {
      user = Map<String, dynamic>.from(users.first);
    }
    final id = _spoofNodeString(
      user.isNotEmpty ? user : endpoint,
      const ['id', 'uuid', 'password'],
    );
    if (id == null) {
      return null;
    }
    if (protocol == 'trojan') {
      clash['password'] = id;
    } else {
      clash['uuid'] = id;
    }
    if (protocol == 'vless') {
      final flow = _spoofNodeString(user, const ['flow']);
      if (flow != null) {
        clash['flow'] = flow;
      }
    }
    if (protocol == 'vmess') {
      final alterId = user['alterId'] ?? user['alter_id'];
      clash['alterId'] = alterId is num ? alterId.toInt() : 0;
      clash['cipher'] =
          _spoofNodeString(user, const ['security', 'scy', 'cipher']) ??
              'auto';
    }
  }
  final stream = _spoofNodeMap(ob['streamSettings']) ?? const <String, dynamic>{};
  final security =
      '${stream['security'] ?? ''}'.trim().toLowerCase();
  if (security == 'tls' || security == 'reality') {
    final tlsNode = _spoofNodeMap(
          stream['${security}Settings'],
        ) ??
        const <String, dynamic>{};
    _applyClashTlsFields(
      clash,
      sni: _spoofNodeString(
        tlsNode,
        const ['serverName', 'server_name', 'sni'],
      ),
      insecure: tlsNode['allowInsecure'] == true ||
          tlsNode['allow_insecure'] == true ||
          tlsNode['insecure'] == true,
      alpn: _spoofNodeStringList(tlsNode['alpn']),
      fingerprint: _spoofNodeString(
        tlsNode,
        const ['fingerprint', 'fp'],
      ),
      publicKey: _spoofNodeString(
        tlsNode,
        const ['publicKey', 'public_key', 'pbk'],
      ),
      shortId: _spoofNodeString(
        tlsNode,
        const ['shortId', 'short_id', 'sid'],
      ),
    );
  }
  _applyClashTransport(
    clash,
    network: _spoofNodeString(stream, const ['network', 'net']),
    transport: _spoofNodeMap(stream['wsSettings']) ??
        _spoofNodeMap(stream['grpcSettings']) ??
        _spoofNodeMap(stream['httpSettings']) ??
        _spoofNodeMap(stream['httpupgradeSettings']),
  );
  clash['name'] =
      _spoofNodeString(ob, _spoofNodeNameKeys) ?? '$server:$port';
  return clash;
}

/// Плоский клиентский JSON ({protocol, address, port, id…}) -> clash.
Map<String, dynamic>? _convertFlatClientNode(Map<String, dynamic> node) {
  final protocol = _spoofNodeString(node, const ['protocol', 'type']);
  final server = _spoofNodeString(node, _spoofNodeHostKeys);
  final port = _spoofNodePort(node);
  if (protocol == null || server == null || port == null) {
    return null;
  }
  final type = protocol.trim().toLowerCase();
  final clash = <String, dynamic>{
    'type': type == 'shadowsocks' ? 'ss' : type,
    'server': server,
    'port': port,
  };
  switch (type) {
    case 'vless':
    case 'vmess':
      final id = _spoofNodeString(node, const ['id', 'uuid']);
      if (id == null) {
        return null;
      }
      clash['uuid'] = id;
      if (type == 'vless') {
        final flow = _spoofNodeString(node, const ['flow']);
        if (flow != null) {
          clash['flow'] = flow;
        }
      } else {
        final alterId = node['alterId'] ?? node['alter_id'];
        clash['alterId'] = alterId is num ? alterId.toInt() : 0;
        clash['cipher'] =
            _spoofNodeString(node, const ['security', 'scy', 'cipher']) ??
                'auto';
      }
    case 'trojan':
      final password = _spoofNodeString(node, const ['password', 'id']);
      if (password == null) {
        return null;
      }
      clash['password'] = password;
    case 'ss':
    case 'shadowsocks':
      final method = _spoofNodeString(node, const ['method', 'cipher', 'encryption']);
      final password = _spoofNodeString(node, const ['password']);
      if (method == null || password == null) {
        return null;
      }
      clash['cipher'] = method;
      clash['password'] = password;
    case 'hysteria2':
      final password = _spoofNodeString(node, const ['password', 'auth']);
      if (password != null) {
        clash['password'] = password;
      }
    default:
      return null;
  }
  final security = _spoofNodeString(node, const ['security', 'tls']);
  final securityText = (security ?? '').trim().toLowerCase();
  final isTls = securityText == 'tls' ||
      securityText == 'reality' ||
      securityText == '1' ||
      securityText == 'true';
  if (isTls) {
    _applyClashTlsFields(
      clash,
      sni: _spoofNodeString(node, const ['sni', 'sniHost', 'servername', 'host']),
      insecure: node['allowInsecure'] == true ||
          node['insecure'] == true ||
          '${node['allowInsecure'] ?? ''}' == '1',
      alpn: _spoofNodeStringList(node['alpn']),
      fingerprint: _spoofNodeString(node, const ['fp', 'fingerprint']),
      publicKey: _spoofNodeString(node, const ['pbk', 'publicKey', 'public-key']),
      shortId: _spoofNodeString(node, const ['sid', 'shortId', 'short-id']),
    );
  }
  final wsPath = _spoofNodeString(node, const ['path']);
  final wsHost = _spoofNodeString(node, const ['host']);
  _applyClashTransport(
    clash,
    network: _spoofNodeString(node, const ['network', 'net', 'transport']),
    transport: wsPath != null || wsHost != null
        ? {'path': wsPath, 'Host': wsHost}
        : null,
  );
  clash['name'] =
      _spoofNodeString(node, _spoofNodeNameKeys) ?? '$server:$port';
  return clash;
}

/// Общие TLS-поля clash для всех конвертеров.
void _applyClashTlsFields(
  Map<String, dynamic> clash, {
  String? sni,
  bool insecure = false,
  List<String>? alpn,
  String? fingerprint,
  String? publicKey,
  String? shortId,
}) {
  clash['tls'] = true;
  if (sni != null && sni.isNotEmpty) {
    clash['servername'] = sni;
  }
  if (insecure) {
    clash['skip-cert-verify'] = true;
  }
  if (alpn != null && alpn.isNotEmpty) {
    clash['alpn'] = alpn;
  }
  if (fingerprint != null && fingerprint.isNotEmpty) {
    clash['client-fingerprint'] = fingerprint;
  }
  if (publicKey != null && publicKey.isNotEmpty) {
    clash['public-key'] = publicKey;
  }
  if (shortId != null && shortId.isNotEmpty) {
    clash['short-id'] = shortId;
  }
}

/// Транспорт (ws/grpc/http) из клиентских форматов -> clash-опции.
/// [transport] — «сырые» поля ws/http из sing-box/Xray; для плоского
/// формата передаются path/Host напрямую.
void _applyClashTransport(
  Map<String, dynamic> clash, {
  String? network,
  Map<String, dynamic>? transport,
}) {
  final net = (network ?? '').trim().toLowerCase();
  if (net.isEmpty && transport == null) {
    return;
  }
  switch (net) {
    case 'ws':
      clash['network'] = 'ws';
      final opts = <String, dynamic>{};
      if (transport != null) {
        final path = transport['path'];
        if (path != null && '$path'.trim().isNotEmpty) {
          opts['path'] = '$path';
        }
        final headers = <String, dynamic>{};
        final rawHeaders = _spoofNodeMap(transport['headers']);
        final host = rawHeaders != null
            ? (rawHeaders['Host'] ?? rawHeaders['host'])
            : (transport['Host'] ?? transport['host']);
        if (host != null && '$host'.trim().isNotEmpty) {
          headers['Host'] = '$host';
        }
        if (headers.isNotEmpty) {
          opts['headers'] = headers;
        }
      }
      if (opts.isNotEmpty) {
        clash['ws-opts'] = opts;
      }
    case 'grpc':
      clash['network'] = 'grpc';
      if (transport != null) {
        final serviceName =
            transport['service_name'] ?? transport['serviceName'];
        if (serviceName != null && '$serviceName'.trim().isNotEmpty) {
          clash['grpc-opts'] = {'grpc-service-name': '$serviceName'};
        }
      }
    case 'http':
    case 'h2':
      clash['network'] = 'h2';
      final opts = <String, dynamic>{};
      if (transport != null) {
        final path = transport['path'];
        if (path != null && '$path'.trim().isNotEmpty) {
          opts['path'] = ['$path'];
        }
        final rawHeaders = _spoofNodeMap(transport['headers']);
        final host = rawHeaders != null
            ? (rawHeaders['Host'] ?? rawHeaders['host'])
            : transport['host'];
        if (host is List && host.isNotEmpty) {
          opts['host'] = host.map((e) => '$e').toList();
        } else if (host is String && host.trim().isNotEmpty) {
          opts['host'] = [host.trim()];
        }
      }
      if (opts.isNotEmpty) {
        clash['h2-opts'] = opts;
      }
    case 'httpupgrade':
      clash['network'] = 'httpupgrade';
      if (transport != null) {
        final path = transport['path'];
        if (path != null && '$path'.trim().isNotEmpty) {
          clash['httpupgrade-opts'] = {'path': '$path'};
        }
      }
    default:
      break;
  }
}
