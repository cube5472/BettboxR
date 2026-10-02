import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/print.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Подмена клиента подписок (HWID-часть).
///
/// Стандарт заголовков установлен Remnawave (и поддержан Happ, v2RayTun,
/// INCY, FlClashX, Prizrak-Box и др.): при получении подписки клиент шлёт
/// x-hwid (обязателен), x-device-os, x-ver-os, x-device-model (опциональны).
/// Если на панели включён HWID device limit, а заголовка нет — отдача
/// подписки заканчивается ошибкой 404.
///
/// HWID считается один раз за сессию приложения: на Android это
/// Settings.Secure.ANDROID_ID, полученный через нативный канал
/// `com.appshub.bettbox/device_id`; если канал недоступен или значение не
/// проходит валидацию панели — берётся SHA-256 (первые 16 символов, верхний
/// регистр) от стабильного набора идентификаторов устройства. Оба варианта
/// удовлетворяют регулярному выражению панели ^[a-zA-Z0-9=-]{10,64}$.
class SubSpoof {
  SubSpoof._();

  static const _channelName = 'com.appshub.bettbox/device_id';
  static const _prefsKeyHwidEnabled = 'subSpoofHwidEnabled';

  /// Регулярное выражение, по которому панель валидирует x-hwid.
  static final RegExp hwidRegExp = RegExp(r'^[a-zA-Z0-9=-]{10,64}$');

  /// UA-пресеты «имитации приложения». Формат сверён с реальными клиентами:
  /// Happ шлёт `Happ/<версия>`, v2RayTun — `v2rayTun/<версия>`,
  /// INCY — `INCY/<версия>`; панели матчуют клиентов по префиксу UA
  /// (^Happ/, ^INCY/, v2rayTun и т.д.).
  static const String uaHapp = 'Happ/3.24.1';
  static const String uaV2RayTun = 'v2rayTun/3.0.8';
  static const String uaIncy = 'INCY/1.4.3';

  /// (подпись в UI, значение UA) для диалога выбора UA.
  static const List<(String, String)> uaPresets = [
    ('Happ', uaHapp),
    ('v2RayTun', uaV2RayTun),
    ('INCY', uaIncy),
  ];

  static const MethodChannel _channel = MethodChannel(_channelName);

  static bool? _hwidEnabled;
  static String? _cachedHwid;
  static String? _cachedOs;
  static String? _cachedOsVersion;
  static String? _cachedModel;

  static bool get hwidEnabled => _hwidEnabled ?? false;

  static Future<bool> _readHwidPref() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      return preferences.getBool(_prefsKeyHwidEnabled) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Читает тумблер «Поддержка HWID» из настроек (лениво, один раз).
  static Future<void> ensureLoaded() async {
    _hwidEnabled ??= await _readHwidPref();
  }

  /// Сохраняет тумблер «Поддержка HWID».
  static Future<void> setHwidEnabled(bool value) async {
    _hwidEnabled = value;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_prefsKeyHwidEnabled, value);
    } catch (e) {
      commonPrint.log('SubSpoof: failed to persist hwid flag: $e');
    }
  }

  /// Сбрасывает кэш идентификаторов (для тестов/диагностики).
  static void resetCache() {
    _cachedHwid = null;
    _cachedOs = null;
    _cachedOsVersion = null;
    _cachedModel = null;
  }

  /// Заголовки для запроса подписки. Пустая карта — ничего дополнительно
  /// не отправлять (тумблер выключен или hwid получить не удалось).
  static Future<Map<String, String>> buildHeaders() async {
    await ensureLoaded();
    if (!hwidEnabled) {
      return const {};
    }
    final hwid = await resolveHwid();
    if (hwid == null || hwidRegExp.hasMatch(hwid) != true) {
      commonPrint.log('SubSpoof: hwid unavailable, headers skipped');
      return const {};
    }
    final headers = <String, String>{
      'x-hwid': hwid,
      if (await resolveOs() case final String os) 'x-device-os': os,
      if (await resolveOsVersion() case final String osVersion)
        'x-ver-os': osVersion,
      if (await resolveModel() case final String model)
        'x-device-model': model,
    };
    commonPrint.log(
      'SubSpoof: sending hwid headers (hwid=${_maskHwid(hwid)})',
    );
    return headers;
  }

  /// Заголовки для proxy-провайдеров mihomo (значения обязаны быть списками).
  static Future<Map<String, List<String>>> buildProviderHeaders() async {
    final headers = await buildHeaders();
    return headers.map((key, value) => MapEntry(key, [value]));
  }

  static String _maskHwid(String hwid) =>
      '${hwid.substring(0, hwid.length >= 4 ? 4 : hwid.length)}…';

  /// ANDROID_ID (или хэш-фолбэк) — сам идентификатор без заголовков.
  static Future<String?> resolveHwid() async {
    if (_cachedHwid != null) {
      return _cachedHwid;
    }
    String? raw;
    if (Platform.isAndroid) {
      try {
        raw = await _channel.invokeMethod<String>('getAndroidId');
      } catch (e) {
        commonPrint.log('SubSpoof: device_id channel failed: $e');
      }
      raw = raw?.trim();
      if (raw != null && raw.isEmpty) {
        raw = null;
      }
    }
    if (raw != null && hwidRegExp.hasMatch(raw)) {
      _cachedHwid = raw;
      return _cachedHwid;
    }
    final fallbackSource = await _deviceFallbackSource();
    if (fallbackSource == null || fallbackSource.isEmpty) {
      return null;
    }
    _cachedHwid = _compactId(fallbackSource);
    return _cachedHwid;
  }

  /// SHA-256 → первые 16 hex-символов в верхнем регистре.
  static String _compactId(String source) =>
      sha256.convert(utf8.encode(source)).toString().substring(0, 16)
          .toUpperCase();

  static Future<String?> _deviceFallbackSource() async {
    try {
      final deviceInfo = await DeviceInfoPlugin().deviceInfo;
      if (deviceInfo is AndroidDeviceInfo) {
        final combined =
            '${deviceInfo.brand}-${deviceInfo.device}-'
            '${deviceInfo.hardware}-${deviceInfo.id}';
        if (combined.replaceAll('-', '').isNotEmpty) {
          return combined;
        }
        return null;
      }
      if (deviceInfo is WindowsDeviceInfo) {
        return '${deviceInfo.computerName}-${deviceInfo.deviceId}';
      }
      if (deviceInfo is LinuxDeviceInfo) {
        return deviceInfo.machineId ?? '${deviceInfo.id}-${deviceInfo.name}';
      }
      if (deviceInfo is MacOsDeviceInfo) {
        return deviceInfo.systemGUID ??
            '${deviceInfo.model}-${deviceInfo.computerName}';
      }
    } catch (e) {
      commonPrint.log('SubSpoof: device info failed: $e');
    }
    return null;
  }

  static Future<String?> resolveOs() async {
    if (_cachedOs != null) {
      return _cachedOs;
    }
    if (Platform.isAndroid) {
      _cachedOs = 'Android';
    } else if (Platform.isWindows) {
      _cachedOs = 'Windows';
    } else if (Platform.isLinux) {
      _cachedOs = 'Linux';
    } else if (Platform.isMacOS) {
      _cachedOs = 'macOS';
    }
    return _cachedOs;
  }

  static Future<String?> resolveOsVersion() async {
    if (_cachedOsVersion != null) {
      return _cachedOsVersion;
    }
    try {
      final deviceInfo = await DeviceInfoPlugin().deviceInfo;
      if (deviceInfo is AndroidDeviceInfo) {
        final release = deviceInfo.version.release;
        _cachedOsVersion = release.isEmpty ? '${deviceInfo.version.sdkInt}' : release;
      } else if (deviceInfo is WindowsDeviceInfo) {
        _cachedOsVersion = deviceInfo.displayVersion;
      } else if (deviceInfo is LinuxDeviceInfo) {
        _cachedOsVersion = deviceInfo.versionId;
      } else if (deviceInfo is MacOsDeviceInfo) {
        _cachedOsVersion = deviceInfo.osRelease;
      }
    } catch (_) {}
    if (_cachedOsVersion != null && _cachedOsVersion!.length > 32) {
      _cachedOsVersion = _cachedOsVersion!.substring(0, 32);
    }
    return _cachedOsVersion;
  }

  static Future<String?> resolveModel() async {
    if (_cachedModel != null) {
      return _cachedModel;
    }
    try {
      final deviceInfo = await DeviceInfoPlugin().deviceInfo;
      if (deviceInfo is AndroidDeviceInfo) {
        final manufacturer = deviceInfo.manufacturer.trim();
        final model = deviceInfo.model.trim();
        _cachedModel = model.toLowerCase().startsWith(manufacturer.toLowerCase())
            ? model
            : '$manufacturer $model';
      } else if (deviceInfo is WindowsDeviceInfo) {
        _cachedModel = deviceInfo.productName;
      } else if (deviceInfo is LinuxDeviceInfo) {
        _cachedModel = deviceInfo.name;
      } else if (deviceInfo is MacOsDeviceInfo) {
        _cachedModel = deviceInfo.model;
      }
    } catch (_) {}
    if (_cachedModel != null && _cachedModel!.length > 64) {
      _cachedModel = _cachedModel!.substring(0, 64);
    }
    return _cachedModel;
  }
}
