// Подмена клиента при загрузке подписки.
//
// Некоторые панели провайдеров (Remnawave и форки Marzban) фильтруют
// подписки по User-Agent — разрешают только «одобренные» приложения.
// Для таких подписок BettboxR может представляться популярным клиентом.
// Заголовки сняты с реальных клиентов:
//  - Happ (Android 4.6.1, из classes.dex): «Happ/<ver>/» + заголовок
//    X-HWID; Remnawave читает x-hwid (^[a-zA-Z0-9=-]{10,64}$) при
//    включённом лимите устройств;
//  - Incy (iOS): «INCY/<ver>» + X-HWID (панель распознаёт префикс
//    «INCY/»);
//  - v2rayNG (исходники 2dust/v2rayNG): «v2rayNG/<ver>», hwid не
//    передаёт.
// HWID — стабильный идентификатор устройства: генерируется один раз и
// хранится вместе с настройками профиля, чтобы панели с device-limit
// считали каждое обновление подписки тем же устройством.
import 'dart:convert';
import 'dart:math';

import 'package:bett_box/common/common.dart';

const kSubSpoofStoreKey = 'sub_spoof_map';

/// id пресета -> User-Agent реального клиента.
const kSubSpoofClients = <String, String>{
  'happ': 'Happ/4.6.1/',
  'incy': 'INCY/1.0.0',
  'v2rayng': 'v2rayNG/2.3.9',
};

/// Пресеты, для которых передаётся X-HWID.
const kSubSpoofHwidClients = <String>['happ', 'incy'];

/// Читаемые названия пресетов для UI.
const kSubSpoofClientLabels = <String, String>{
  'happ': 'Happ',
  'incy': 'Incy',
  'v2rayng': 'v2rayNG',
};

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
        client: json['client'] as String? ?? '',
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
  Map<String, String>? buildHeaders() {
    if (!isEnabled) {
      return null;
    }
    final ua = effectiveUa;
    if (ua.isEmpty) {
      return null;
    }
    final headers = <String, String>{'User-Agent': ua};
    final id = hwid.trim();
    if (needsHwid && id.isNotEmpty) {
      headers['X-HWID'] = id;
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
