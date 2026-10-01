// Подмена клиента при загрузке подписки.
//
// Некоторые панели провайдеров (Remnawave, RU-бот-панели) фильтруют
// подписки по User-Agent и идентификатору устройства — разрешают
// только «одобренные» приложения. Для таких подписок BettboxR может
// представляться популярным клиентом.
// Отпечатки сняты с работающего клиента (форк NekoBoxPlus, где они
// захардкожены 1:1 с реальными приложениями):
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
import 'package:device_info_plus/device_info_plus.dart';

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

  /// Полный набор заголовков реального клиента: UA + X-Hwid +
  /// device-заголовки (модель/SDK/локаль) как в референсе.
  Future<Map<String, String>?> resolveHeaders() async {
    final base = buildHeaders();
    if (base == null) {
      return null;
    }
    final dev = await resolveSpoofDeviceContext();
    if (dev != null) {
      base.addAll(buildSpoofExtraHeaders(client, dev));
    }
    return base;
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

/// UUID v4 без дефисов (32 hex-символа) — проходит валидацию hwid
/// панелей (Remnawave: ^[a-zA-Z0-9=-]{10,64}$) и не раскрывает
/// реальное устройство.
String generateSubSpoofHwid() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
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
}
