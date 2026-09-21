import 'dart:async';
import 'dart:convert';

import 'package:bett_box/common/preferences.dart';
import 'package:bett_box/common/print.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Пассивная DNS-статистика BettboxR (уровень 1 — без правок ядра).
///
/// Пока включена:
///  - patchRawConfig (state.dart) и updateParamsProvider временно поднимают
///    log-level ядра до debug, если пользовательский уровень ниже;
///  - приложение включает поток логов ядра (startLog);
///  - этот сервис разбирает debug-строки ядра вида:
///      [DNS] resolve <домен> <тип> from <сервер>
///      [DNS] <домен> --> <ответ> from <сервер>
///      [DNS] cache hit <домен> --> <ответ>, expire at <время>
///      [DNS Server] Exchange <вопрос> failed: <ошибка>
///    и копит агрегаты за день (серверы, домены, типы, задержки).
///
/// Данные живут только на устройстве (SharedPreferences, 7 дневных
/// корзин). Агрегация выполняется в UI-изоляте, поэтому пока приложение
/// свёрнуто и его UI-процесс выгружен системой, события не считаются.
class DnsServerStats {
  int queries = 0;
  int answers = 0;
  int errors = 0;
  int timeouts = 0;
  int latencySamples = 0;
  int totalLatencyMs = 0;

  int get avgLatencyMs {
    if (latencySamples <= 0) return 0;
    return totalLatencyMs ~/ latencySamples;
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'q': queries,
      'a': answers,
      'e': errors,
      't': timeouts,
      'ls': latencySamples,
      'tm': totalLatencyMs,
    };
  }

  static DnsServerStats fromMap(Map<String, dynamic> map) {
    final stats = DnsServerStats();
    stats.queries = _asInt(map['q']);
    stats.answers = _asInt(map['a']);
    stats.errors = _asInt(map['e']);
    stats.timeouts = _asInt(map['t']);
    stats.latencySamples = _asInt(map['ls']);
    stats.totalLatencyMs = _asInt(map['tm']);
    return stats;
  }

  static int _asInt(dynamic value) {
    return value is int ? value : 0;
  }
}

class DnsDayStats {
  DnsDayStats({required this.dayKey});

  final String dayKey;

  int queries = 0;
  int answers = 0;
  int cacheHits = 0;
  int errors = 0;
  int timeouts = 0;
  int latencySamples = 0;
  int totalLatencyMs = 0;

  final Map<String, DnsServerStats> servers = {};
  final Map<String, int> domains = {};
  final Map<String, int> qtypes = {};

  int get handled {
    return queries + cacheHits;
  }

  int get avgLatencyMs {
    if (latencySamples <= 0) return 0;
    return totalLatencyMs ~/ latencySamples;
  }

  Map<String, dynamic> toMap() {
    final serversMap = <String, dynamic>{};
    servers.forEach((key, value) {
      serversMap[key] = value.toMap();
    });
    return <String, dynamic>{
      'q': queries,
      'a': answers,
      'c': cacheHits,
      'e': errors,
      't': timeouts,
      'ls': latencySamples,
      'tm': totalLatencyMs,
      'servers': serversMap,
      'domains': domains,
      'qtypes': qtypes,
    };
  }

  static DnsDayStats fromMap(String key, Map<String, dynamic> map) {
    final stats = DnsDayStats(dayKey: key);
    stats.queries = _asInt(map['q']);
    stats.answers = _asInt(map['a']);
    stats.cacheHits = _asInt(map['c']);
    stats.errors = _asInt(map['e']);
    stats.timeouts = _asInt(map['t']);
    stats.latencySamples = _asInt(map['ls']);
    stats.totalLatencyMs = _asInt(map['tm']);
    final serversMap = map['servers'];
    if (serversMap is Map) {
      serversMap.forEach((serverKey, value) {
        if (serverKey is String && value is Map) {
          stats.servers[serverKey] = DnsServerStats.fromMap(
            Map<String, dynamic>.from(value),
          );
        }
      });
    }
    _copyIntMap(map['domains'], stats.domains);
    _copyIntMap(map['qtypes'], stats.qtypes);
    return stats;
  }

  static int _asInt(dynamic value) {
    return value is int ? value : 0;
  }

  static void _copyIntMap(dynamic source, Map<String, int> target) {
    if (source is Map) {
      source.forEach((key, value) {
        if (key is String) {
          target[key] = _asInt(value);
        }
      });
    }
  }
}

class DnsEvent {
  DnsEvent({
    required this.at,
    required this.kind,
    required this.domain,
    this.server,
    this.latencyMs,
  });

  final int at;
  final String kind;
  final String domain;
  final String? server;
  final int? latencyMs;
}

class DnsStatsService extends ChangeNotifier {
  DnsStatsService._internal();

  static final DnsStatsService instance = DnsStatsService._internal();

  factory DnsStatsService() => instance;

  static const String prefsKey = 'bb.dnsStats.v1';
  static const int keepDays = 7;
  static const int maxDomains = 400;
  static const int maxServers = 32;
  static const int maxEvents = 60;
  static const int maxPendingKeys = 512;
  static const int pendingTimeoutMs = 15000;

  bool _loaded = false;
  bool _loading = false;
  bool _enabled = false;
  bool _dirty = false;

  DnsDayStats _current = DnsDayStats(dayKey: '');
  String _currentKey = '';
  final Map<String, DnsDayStats> _history = {};
  final List<DnsEvent> _events = <DnsEvent>[];
  final Map<String, List<int>> _pending = <String, List<int>>{};
  Timer? _saveTimer;
  Timer? _notifyTimer;

  bool get enabled => _enabled;

  bool get isLoaded => _loaded;

  DnsDayStats get today => _current;

  List<DnsEvent> get events => List<DnsEvent>.unmodifiable(_events);

  Future<void> load() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final raw = prefs?.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = json.decode(raw);
        if (decoded is Map) {
          _enabled = decoded['enabled'] == true;
          final days = decoded['days'];
          if (days is Map) {
            days.forEach((key, value) {
              if (key is String && value is Map) {
                _history[key] = DnsDayStats.fromMap(
                  key,
                  Map<String, dynamic>.from(value),
                );
              }
            });
          }
        }
      }
      _pruneDays();
      _currentKey = keyForDate(DateTime.now());
      _current =
          _history[_currentKey] ??
          DnsDayStats(dayKey: _currentKey);
      _history[_currentKey] = _current;
    } catch (e) {
      commonPrint.log('DNS stats: load failed: $e');
    } finally {
      _loading = false;
      _loaded = true;
      notifyListeners();
    }
  }

  /// Свежая перечитка флага из prefs — для сервисного изолята, где
  /// собственная копия могла устареть после переключения тумблера в UI.
  Future<void> reloadEnabled() async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final raw = prefs?.getString(prefsKey);
      var value = false;
      if (raw != null && raw.isNotEmpty) {
        final decoded = json.decode(raw);
        if (decoded is Map) {
          value = decoded['enabled'] == true;
        }
      }
      _enabled = value;
    } catch (e) {
      commonPrint.log('DNS stats: reload failed: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    if (!_loaded) {
      await load();
    }
    if (_enabled == value) return;
    _enabled = value;
    _markDirty();
    notifyListeners();
    await _save();
  }

  Future<void> reset() async {
    _history.clear();
    _pending.clear();
    _events.clear();
    _currentKey = keyForDate(DateTime.now());
    _current = DnsDayStats(dayKey: _currentKey);
    _history[_currentKey] = _current;
    _markDirty();
    notifyListeners();
    await _save();
  }

  /// Точка входа для логов ядра. Вызывается из ClashManager.onLog.
  void handleLog(String payload) {
    if (!_enabled || !_loaded) return;
    if (!payload.startsWith('[DNS')) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _ensureToday(nowMs);
    _purgePending(nowMs);

    if (payload.startsWith('[DNS] resolve ')) {
      final parsed = _parseResolve(payload.substring('[DNS] resolve '.length));
      if (parsed != null) {
        _onQuery(parsed[0], parsed[1], parsed[2], nowMs);
      }
    } else if (payload.startsWith('[DNS] cache hit ')) {
      final domain = _parseCacheHit(
        payload.substring('[DNS] cache hit '.length),
      );
      if (domain != null) {
        _onCache(domain);
      }
    } else if (payload.startsWith('[DNS Server] Exchange ')) {
      final rest = payload.substring('[DNS Server] Exchange '.length);
      final failedIndex = rest.indexOf(' failed: ');
      if (failedIndex > 0) {
        final question = rest.substring(0, failedIndex).trim();
        final domain = _normalizeDomain(
          question.split(RegExp(r'\s')).first,
        );
        if (domain.isNotEmpty) {
          _onServerError(domain);
        }
      }
    } else if (payload.startsWith('[DNS] ')) {
      final rest = payload.substring('[DNS] '.length);
      final arrowIndex = rest.indexOf(' --> ');
      if (arrowIndex > 0) {
        final domain = _normalizeDomain(rest.substring(0, arrowIndex));
        final tail = rest.substring(arrowIndex + ' --> '.length);
        String? server;
        final fromIndex = tail.lastIndexOf(' from ');
        if (fromIndex > 0) {
          server = tail.substring(fromIndex + ' from '.length).trim();
        }
        if (domain.isNotEmpty) {
          _onAnswer(domain, server, nowMs);
        }
      }
    }

    _throttledNotify();
  }

  List<String>? _parseResolve(String rest) {
    final fromIndex = rest.lastIndexOf(' from ');
    if (fromIndex <= 0) return null;
    final server = rest.substring(fromIndex + ' from '.length).trim();
    if (server.isEmpty) return null;
    final head = rest.substring(0, fromIndex).trim();
    final spaceIndex = head.indexOf(' ');
    if (spaceIndex <= 0) return null;
    final domain = _normalizeDomain(head.substring(0, spaceIndex));
    final qtype = head.substring(spaceIndex + 1).trim();
    if (domain.isEmpty || qtype.isEmpty) return null;
    return <String>[domain, qtype, server];
  }

  String? _parseCacheHit(String rest) {
    final arrowIndex = rest.indexOf(' --> ');
    if (arrowIndex <= 0) return null;
    return _normalizeDomain(rest.substring(0, arrowIndex));
  }

  void _onQuery(String domain, String qtype, String server, int nowMs) {
    _current.queries++;
    if (qtype.isNotEmpty) {
      _current.qtypes[qtype] = (_current.qtypes[qtype] ?? 0) + 1;
    }
    _countDomain(domain);
    final serverStats = _serverStats(server);
    serverStats.queries++;
    final key = '$domain|$server';
    final starts = _pending.putIfAbsent(key, () => <int>[]);
    starts.add(nowMs);
    if (_pending.length > maxPendingKeys) {
      final firstKey = _pending.keys.first;
      _pending.remove(firstKey);
    }
  }

  void _onAnswer(String domain, String? server, int nowMs) {
    _current.answers++;
    DnsServerStats? serverStats;
    if (server != null && server.isNotEmpty) {
      serverStats = _serverStats(server);
      serverStats.answers++;
      final key = '$domain|$server';
      final starts = _pending[key];
      if (starts != null && starts.isNotEmpty) {
        final start = starts.removeAt(0);
        if (starts.isEmpty) {
          _pending.remove(key);
        }
        final latency = nowMs - start;
        if (latency >= 0 && latency < 60000) {
          _current.latencySamples++;
          _current.totalLatencyMs += latency;
          serverStats.latencySamples++;
          serverStats.totalLatencyMs += latency;
          _addEvent(
            DnsEvent(
              at: nowMs,
              kind: 'answer',
              domain: domain,
              server: server,
              latencyMs: latency,
            ),
          );
          return;
        }
      }
    }
    _addEvent(
      DnsEvent(at: nowMs, kind: 'answer', domain: domain, server: server),
    );
  }

  void _onCache(String domain) {
    _current.cacheHits++;
    _countDomain(domain);
    _addEvent(
      DnsEvent(
        at: DateTime.now().millisecondsSinceEpoch,
        kind: 'cache',
        domain: domain,
      ),
    );
  }

  void _onServerError(String domain) {
    _current.errors++;
    _addEvent(
      DnsEvent(
        at: DateTime.now().millisecondsSinceEpoch,
        kind: 'error',
        domain: domain,
      ),
    );
  }

  void _countTimeout(String key) {
    final separatorIndex = key.indexOf('|');
    if (separatorIndex <= 0) return;
    final server = key.substring(separatorIndex + 1);
    _current.timeouts++;
    final serverStats = _current.servers[server];
    if (serverStats != null) {
      serverStats.timeouts++;
    }
    _addEvent(
      DnsEvent(
        at: DateTime.now().millisecondsSinceEpoch,
        kind: 'timeout',
        domain: key.substring(0, separatorIndex),
        server: server,
      ),
    );
  }

  void _purgePending(int nowMs) {
    final emptyKeys = <String>[];
    _pending.forEach((key, starts) {
      starts.removeWhere((start) {
        if (nowMs - start > pendingTimeoutMs) {
          _countTimeout(key);
          return true;
        }
        return false;
      });
      if (starts.isEmpty) {
        emptyKeys.add(key);
      }
    });
    for (final key in emptyKeys) {
      _pending.remove(key);
    }
  }

  DnsServerStats _serverStats(String server) {
    var key = server;
    var stats = _current.servers[key];
    if (stats == null) {
      if (_current.servers.length >= maxServers) {
        // Лимит карт достигнут: не плодим новые записи и не дублируем
        // существующие объекты — уводим хвост в общий бакет.
        key = '(прочие серверы)';
        stats = _current.servers[key];
      }
      stats ??= DnsServerStats();
      _current.servers[key] = stats;
    }
    return stats;
  }

  void _countDomain(String domain) {
    if (_current.domains.length >= maxDomains &&
        !_current.domains.containsKey(domain)) {
      return;
    }
    _current.domains[domain] = (_current.domains[domain] ?? 0) + 1;
  }

  void _addEvent(DnsEvent event) {
    _events.add(event);
    if (_events.length > maxEvents) {
      _events.removeRange(0, _events.length - maxEvents);
    }
  }

  void _ensureToday(int nowMs) {
    final key = keyForDate(DateTime.fromMillisecondsSinceEpoch(nowMs));
    if (key == _currentKey) return;
    _currentKey = key;
    _current = _history.putIfAbsent(key, () => DnsDayStats(dayKey: key));
  }

  void _pruneDays() {
    if (_history.length <= keepDays) return;
    final keys = _history.keys.toList()..sort();
    while (keys.length > keepDays) {
      _history.remove(keys.removeAt(0));
    }
  }

  void _markDirty() {
    _dirty = true;
    _saveTimer ??= Timer.periodic(const Duration(seconds: 60), (_) {
      _purgePending(DateTime.now().millisecondsSinceEpoch);
      if (_dirty) {
        unawaited(_save());
      }
    });
  }

  Future<void> _save() async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      _pruneDays();
      final days = <String, dynamic>{};
      _history.forEach((key, value) {
        days[key] = value.toMap();
      });
      final map = <String, dynamic>{'enabled': _enabled, 'days': days};
      await prefs?.setString(prefsKey, json.encode(map));
      _dirty = false;
    } catch (e) {
      commonPrint.log('DNS stats: save failed: $e');
    }
  }

  void _throttledNotify() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 250), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  static String keyForDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year.toString().padLeft(4, '0')}-$month-$day';
  }

  static String _normalizeDomain(String raw) {
    var domain = raw.trim();
    if (domain.endsWith('.')) {
      domain = domain.substring(0, domain.length - 1);
    }
    return domain.toLowerCase();
  }
}

final dnsStats = DnsStatsService();

/// Мост для реактивных провайдеров: updateParamsProvider слушает этот флаг
/// и на лету применяет debug log-level к работающему ядру.
final dnsStatsEnabledProvider = StateProvider<bool>((ref) => dnsStats.enabled);
