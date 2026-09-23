import 'dart:convert';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract mixin class VpnListener {
  void onDnsChanged(String dns) {}

  void onScreenStateChanged(bool isOn) {}

  void onNetworkChanged() {}
}

class Vpn {
  static final Vpn _instance = Vpn._internal();
  final MethodChannel methodChannel = const MethodChannel('vpn');

  Vpn._internal() {
    methodChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'gc':
          clashCore.requestGc(forceFreeOSMemory: true);
          break;
        case 'closeConnections':
          clashCore.closeConnections();
          break;
        case 'status':
          return clashLibHandler?.getRunTime() != null;
        case 'dnsChanged':
          for (final listener in _listeners) {
            listener.onDnsChanged(call.arguments as String);
          }
          break;
        case 'screenStateChanged':
          final isOn = call.arguments as bool;
          globalState.isScreenOn = isOn;
          for (final listener in _listeners) {
            listener.onScreenStateChanged(isOn);
          }
          break;
        case 'networkChanged':
          for (final listener in _listeners) {
            listener.onNetworkChanged();
          }
          break;
        default:
      }
    });
  }

  factory Vpn() => _instance;

  final ObserverList<VpnListener> _listeners = ObserverList<VpnListener>();

  Future<bool?> start(AndroidVpnOptions options) async {
    return await methodChannel.invokeMethod<bool>('start', {
      'data': jsonEncode(options),
    });
  }

  Future<bool?> stop() => methodChannel.invokeMethod<bool>('stop');

  Future<List<String>> getLocalIpAddresses() async {
    return await methodChannel.invokeListMethod<String>(
          'getLocalIpAddresses',
        ) ??
        const [];
  }

  Future<List<String>> getLocalGateways() async {
    return await methodChannel.invokeListMethod<String>(
          'getLocalGateways',
        ) ??
        const [];
  }

  Future<Map<String, dynamic>?> stealthCheck() async {
    return await methodChannel.invokeMapMethod<String, dynamic>(
      'stealthCheck',
    );
  }

  Future<void> setSmartStopped(bool value) async {
    await methodChannel.invokeMethod<bool>('setSmartStopped', {'value': value});
  }

  Future<bool> isSmartStopped() async {
    return await methodChannel.invokeMethod<bool>('isSmartStopped') ?? false;
  }

  Future<bool?> smartStop() => methodChannel.invokeMethod<bool>('smartStop');

  Future<bool?> smartResume(AndroidVpnOptions options) async {
    return await methodChannel.invokeMethod<bool>('smartResume', {
      'data': jsonEncode(options),
    });
  }

  Future<bool> getStatus() async {
    return await methodChannel.invokeMethod<bool>('status') ?? false;
  }

  Future<void> updateNotificationSpeed(
    String profileName,
    String speedInfo,
  ) async {
    await methodChannel.invokeMethod<void>('updateNotificationSpeed', {
      'profileName': profileName,
      'speedInfo': speedInfo,
    });
  }

  /// Обновляет флаг страны выбранной ноды рядом с иконкой приложения
  /// в статус-баре (второе тихое уведомление). Пустой [countryCode]
  /// убирает флаг.
  Future<void> updateNotificationFlag(
    String? countryCode,
    String nodeName,
  ) async {
    await methodChannel.invokeMethod<void>('updateNotificationFlag', {
      'countryCode': countryCode,
      'nodeName': nodeName,
    });
  }

  void addListener(VpnListener listener) => _listeners.add(listener);

  void removeListener(VpnListener listener) => _listeners.remove(listener);
}

Vpn? get vpn => globalState.isService ? Vpn() : null;

/// Состояние паузы VPN для UI-движка.
///
/// Геттер `vpn` в UI-движке равен null (он живёт только в сервисном
/// движке), поэтому дашборд зовёт канал 'vpn' напрямую — VpnPlugin
/// прицеплен и к движку активити (см. комментарий в stealth_check.dart).
/// Kotlin пушит `pauseStateChanged` во все свои каналы; этот синглтон
/// принимает пуши и отдаёт состояние через [untilTs].
class VpnPauseState {
  static final ValueNotifier<int> untilTs = ValueNotifier<int>(0);
  static bool _initialized = false;

  static void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    const MethodChannel('vpn').setMethodCallHandler(_handleCall);
    _syncFromPlatform();
  }

  static Future<void> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'pauseStateChanged':
        untilTs.value = (call.arguments as int?) ?? 0;
        break;
      default:
    }
  }

  static Future<void> _syncFromPlatform() async {
    try {
      final data = await const MethodChannel('vpn')
          .invokeMapMethod<String, dynamic>('getPauseState');
      untilTs.value = (data?['until'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // Канал недоступен (десктоп/ранняя инициализация) — паузы нет.
    }
  }

  static bool get isPaused {
    final until = untilTs.value;
    return until > DateTime.now().millisecondsSinceEpoch;
  }

  /// Поставить VPN на паузу на [minutes] минут.
  static Future<bool> pause(int minutes) async {
    try {
      final res = await const MethodChannel('vpn')
          .invokeMethod<bool>('pause', {'minutes': minutes});
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Прекратить паузу и поднять VPN немедленно.
  static Future<void> resumeNow() async {
    try {
      await const MethodChannel('vpn').invokeMethod('resumeNow');
    } catch (_) {}
  }
}
