import 'dart:async';
import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:synchronized/synchronized.dart';

class _ScriptOptionsCache {
  static final _entries = <String, Map<String, dynamic>>{};
  static const _maxEntries = 16;

  static Map<String, dynamic>? get(String content) {
    final key = _key(content);
    final v = _entries[key];
    if (v != null) {
      // Move to end (most recently used)
      _entries.remove(key);
      _entries[key] = v;
    }
    return v;
  }

  static void put(String content, Map<String, dynamic> value) {
    final key = _key(content);
    _entries[key] = value;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  static void remove(String content) {
    _entries.remove(_key(content));
  }

  static String _key(String content) {
    final bytes = utf8.encode(content);
    return '${bytes.length}_${bytes.fold<int>(0, (p, b) => (p * 31 + b) & 0x7fffffff)}';
  }
}

class JavaScriptRuntimeManager {
  /// Постоянный JS-движок. Раньше на каждый запуск скрипта создавался новый
  /// IsolateQjs — это заметно удлиняло каждый старт туннеля (спавн изолята +
  /// инициализация QuickJS). Теперь движок переиспользуется, а простаивая,
  /// закрывается по таймеру. Скрипты выполняются внутри IIFE — верхнеуровневые
  /// var/const/function не переживают вызов и не конфликтуют при повторе.
  static IsolateQjs? _engine;
  static Timer? _idleTimer;
  static const Duration _idleTtl = Duration(minutes: 2);

  static Future<IsolateQjs> _acquireEngine() async {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTtl, () {
      _idleTimer = null;
      final engine = _engine;
      _engine = null;
      if (engine != null) {
        engine.close().then((_) {}, onError: (_) {});
      }
    });
    final existing = _engine;
    if (existing != null) return existing;
    final fresh = IsolateQjs();
    _engine = fresh;
    return fresh;
  }

  static Future<void> _discardEngine() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final engine = _engine;
    _engine = null;
    try {
      await engine?.close();
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> evaluateScript(
    String scriptContent,
    Map<String, dynamic> config, {
    Map<String, bool>? customOptions,
  }) async {
    final result = await _evaluateWithRetry(
      scriptContent,
      config,
      customOptions: customOptions,
    );
    // Быстрый путь: main() возвращает JSON.stringify(config) — одна строка
    // через FFI вместо поэлементной конвертации большого объекта.
    if (result is String) {
      try {
        final decoded = json.decode(result);
        if (decoded is Map) return _deepCastMap(decoded);
      } on Object catch (e) {
        commonPrint.log('evaluateScript: decode failed: $e');
      }
      return config;
    }
    if (result is Map) {
      return _deepCastMap(result);
    }
    return config;
  }

  static final Lock _engineLock = Lock();

  static Future<Map<String, dynamic>> extractScriptOptions(
    String scriptContent,
  ) async {
    final cached = _ScriptOptionsCache.get(scriptContent);
    if (cached != null) return cached;

    return _engineLock.synchronized(() async {
      // Double-check after acquiring lock
      final recached = _ScriptOptionsCache.get(scriptContent);
      if (recached != null) return recached;

      final engine = await _acquireEngine();
      try {
        final res = await engine.evaluate('''
          var console = {
            log: function() {},
            warn: function() {},
            error: function() {},
            info: function() {},
            debug: function() {}
          };
          (function() {
            $scriptContent
            var options = typeof ruleOptionsEnable !== 'undefined' && ruleOptionsEnable && typeof ruleOptionsEnable === 'object' ? ruleOptionsEnable : {};
            var icons = {};
            if (typeof serviceConfigs !== 'undefined' && Array.isArray(serviceConfigs)) {
              for (var i = 0; i < serviceConfigs.length; i++) {
                var svc = serviceConfigs[i];
                if (svc && svc.name && typeof svc.icon === 'string') {
                  icons[svc.name] = svc.icon;
                }
              }
            }
            return JSON.stringify({ options: options, icons: icons });
          })();
        ''');

        final result = <String, dynamic>{};
        if (res is String) {
          final decoded = json.decode(res);
          if (decoded is Map) {
            result.addAll(_deepCastMap(decoded));
          }
        }
        _ScriptOptionsCache.put(scriptContent, result);
        return result;
      } catch (e) {
        commonPrint.log('extractScriptOptions error: $e');
        // Движок мог остаться в плохом состоянии — пересоздадим при след. запуске.
        await _discardEngine();
        return {};
      }
    });
  }

  static void invalidateCachedOptions(String scriptContent) {
    _ScriptOptionsCache.remove(scriptContent);
  }

  static bool hasCachedOptions(String scriptContent) {
    return _ScriptOptionsCache.get(scriptContent) != null;
  }

  static Map<String, dynamic>? getCachedOptions(String scriptContent) {
    return _ScriptOptionsCache.get(scriptContent);
  }

  /// Вывод console.* из скрипта (причины пропуска правил, предупреждения)
  /// собирается в globalThis.__bbLogs и после выполнения забирается в журнал
  /// приложения. Без этого пропуски встроенных скриптов полностью незаметны:
  /// скрипт молча возвращает конфиг без изменений.
  static Future<void> _drainScriptLogs(IsolateQjs engine) async {
    try {
      final logsJson = await engine.evaluate(
        "JSON.stringify(typeof globalThis === 'object' && globalThis.__bbLogs"
        ' ? globalThis.__bbLogs.slice(0, 50) : [])',
      );
      if (logsJson is String && logsJson.isNotEmpty) {
        final decoded = json.decode(logsJson);
        if (decoded is List) {
          for (final line in decoded) {
            commonPrint.log('[script] $line');
          }
        }
      }
    } catch (_) {
      // Журнал — вспомогательный канал: любая ошибка здесь не должна
      // влиять на результат выполнения скрипта.
    }
  }

  static Future<dynamic> _evaluateWithRetry(
    String scriptContent,
    Map<String, dynamic> config, {
    Map<String, bool>? customOptions,
    int maxRetries = 1,
  }) async {
    var attempt = 0;
    while (true) {
      final engine = await _acquireEngine();
      try {
        final configJs = json.encode(config);
        final customJs = customOptions != null && customOptions.isNotEmpty
            ? json.encode(customOptions)
            : null;
        final overrideSnippet = customJs != null
            ? 'if (typeof ruleOptionsEnable !== "undefined") { Object.assign(ruleOptionsEnable, $customJs); }'
            : '';

        // Возврат через JSON.stringify: конфиг передаётся одной строкой,
        // а не конвертируется поэлементно через FFI (это было заметной
        // частью стоимости запуска на больших профилях).
        final res = await engine.evaluate('''
          globalThis.__bbLogs = [];
          var console = {
            log: function(...args) { globalThis.__bbLogs.push(args.join(' ')); if (typeof print !== 'undefined') print(...args); },
            warn: function(...args) { globalThis.__bbLogs.push('WARN: ' + args.join(' ')); if (typeof print !== 'undefined') print('WARN:', ...args); },
            error: function(...args) { globalThis.__bbLogs.push('ERROR: ' + args.join(' ')); if (typeof print !== 'undefined') print('ERROR:', ...args); },
            info: function(...args) { globalThis.__bbLogs.push('INFO: ' + args.join(' ')); if (typeof print !== 'undefined') print('INFO:', ...args); },
            debug: function(...args) { if (typeof print !== 'undefined') print('DEBUG:', ...args); }
          };
          (function() {
            $scriptContent
            $overrideSnippet
            var __patchedConfig = main($configJs);
            return (typeof __patchedConfig === "object" && __patchedConfig !== null)
              ? JSON.stringify(__patchedConfig)
              : null;
          })();
        ''');
        await _drainScriptLogs(engine);
        return res;
      } catch (e) {
        // Движок мог остаться в плохом состоянии — пересоздаём и повторяем.
        await _drainScriptLogs(engine);
        await _discardEngine();
        if (attempt >= maxRetries) {
          throw 'JS Script Error: $e';
        }
        attempt++;
      }
    }
  }

  static Map<String, dynamic> _deepCastMap(Map dynamicMap) {
    return dynamicMap.map<String, dynamic>((key, value) {
      return MapEntry(key.toString(), _deepCastValue(value));
    });
  }

  static dynamic _deepCastValue(dynamic value) {
    if (value is Map) {
      return _deepCastMap(value);
    } else if (value is List) {
      return value.map((e) => _deepCastValue(e)).toList();
    }
    return value;
  }
}
