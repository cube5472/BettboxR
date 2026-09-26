import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';

import 'constant.dart';
import 'path.dart';
import 'print.dart';

class Preferences {
  static Preferences? _instance;
  Completer<SharedPreferences?> sharedPreferencesCompleter = Completer();

  Future<bool> get isInit async => await sharedPreferencesCompleter.future != null;

  Preferences._internal() {
    SharedPreferences.getInstance()
        .then((value) => sharedPreferencesCompleter.complete(value))
        .onError((_, _) => sharedPreferencesCompleter.complete(null));
  }

  factory Preferences() {
    _instance ??= Preferences._internal();
    return _instance!;
  }

  /// Однократная миграция уровня логирования: старый дефолт 'error' 
  /// заменяется на новый 'silent'. Явно выбранные info/debug/warning 
  /// не трогаются.
  static const _logLevelSilentMigratedKey = 'logLevelSilentMigrated';

  /// Метка времени последнего сохранения конфига. Пишется в SharedPreferences
  /// при каждом saveConfig; при загрузке сравнивается с mtime config.json,
  /// чтобы после сбоя записи файла (гонка, нехватка места) загрузить более
  /// свежую копию из SharedPreferences, а не устаревший файл.
  static const _savedAtKey = 'configSavedAt';

  /// Допуск в миллисекундах: в одном saveConfig SharedPreferences пишутся
  /// ДО файла, поэтому mtime файла нормален, когда он чуть НОВЕЕ savedAt.
  static const _savedAtToleranceMs = 5000;

  /// Сериализует записи конфига. Параллельные saveConfig (старт туннеля,
  /// сидирование встроенных скриптов, тумблеры UI) без замки гонялись за
  /// один config.json.tmp: часть сохранений падала с PathNotFoundException
  /// (журнал: "Cannot delete file / Cannot rename file ... .tmp"), а файл
  /// оставался устаревшим — после перезапуска откатывались тумблеры скриптов
  /// и «скрипт-оверрайд» профиля.
  static final Lock _saveLock = Lock();

  Future<ClashConfig?> getClashConfig() async {
    final preferences = await sharedPreferencesCompleter.future;
    final clashConfigString = preferences?.getString(clashConfigKey);
    if (clashConfigString == null) return null;
    try {
      final clashConfigMap = json.decode(clashConfigString);
      var clashConfig = ClashConfig.fromJson(clashConfigMap);
      final migrated = await preferences?.getBool(_logLevelSilentMigratedKey) ?? false;
      if (!migrated && clashConfig.logLevel == LogLevel.error) {
        clashConfig = clashConfig.copyWith(logLevel: LogLevel.silent);
        await preferences?.setBool(_logLevelSilentMigratedKey, true);
      }
      return clashConfig;
    } catch (e, stackTrace) {
      commonPrint.log('Failed to parse clash config from preferences: $e\n$stackTrace');
      return null;
    }
  }

  Future<Config?> getConfig() async {
    final preferences = await sharedPreferencesCompleter.future;

    DateTime? fileMtime;
    Config? fileConfig;
    try {
      final configFilePath = await appPath.appConfigPath;
      final configFile = File(configFilePath);
      if (await configFile.exists()) {
        try {
          fileMtime = await configFile.lastModified();
        } catch (_) {
          fileMtime = null;
        }
        final content = await configFile.readAsString();
        if (content.isNotEmpty) {
          final configMap = json.decode(content);
          fileConfig = Config.compatibleFromJson(configMap);
        }
      }
    } catch (e, stackTrace) {
      commonPrint.log('Failed to parse config from file: $e\n$stackTrace');
    }

    Config? prefsConfig;
    try {
      final configString = preferences?.getString(configKey);
      if (configString != null && configString.isNotEmpty) {
        final configMap = json.decode(configString);
        prefsConfig = Config.compatibleFromJson(configMap);
      }
    } catch (e, stackTrace) {
      commonPrint.log('Failed to parse config from preferences: $e\n$stackTrace');
    }

    Config? selectedConfig;
    if (fileConfig != null && prefsConfig != null) {
      if (fileConfig.profiles.isEmpty && prefsConfig.profiles.isNotEmpty) {
        selectedConfig = prefsConfig;
        await saveConfig(prefsConfig);
      } else if (_isPrefsNewer(preferences, fileMtime)) {
        // Файл остался от сорванного сохранения (гонка/сбой), а в
        // SharedPreferences лежит более свежая копия — берём её и чиним файл.
        commonPrint.log('config.json is stale, restoring newer config from preferences');
        selectedConfig = prefsConfig;
        await saveConfig(prefsConfig);
      } else {
        selectedConfig = fileConfig;
      }
    } else {
      selectedConfig = fileConfig ?? prefsConfig;
      if (selectedConfig != null && fileConfig == null) {
        await saveConfig(selectedConfig);
      }
    }

    if (selectedConfig != null &&
        preferences?.getBool('autoLaunch') != selectedConfig.appSetting.autoLaunch) {
      await preferences?.setBool('autoLaunch', selectedConfig.appSetting.autoLaunch);
    }

    return selectedConfig;
  }

  /// SharedPreferences новее config.json с учётом допуска (_savedAtToleranceMs):
  /// внутри одного saveConfig сперва пишется SharedPreferences, поэтому нормален
  /// файл чуть новее savedAt; заметно более свежий savedAt значит, что запись
  /// файла сорвалась (см. журнал: PathNotFoundException на config.json).
  bool _isPrefsNewer(SharedPreferences? preferences, DateTime? fileMtime) {
    final savedAt = preferences?.getInt(_savedAtKey);
    if (savedAt == null) return false;
    if (fileMtime == null) return true;
    return savedAt > fileMtime.millisecondsSinceEpoch + _savedAtToleranceMs;
  }

  Future<bool> saveConfig(Config config) async {
    final preferences = await sharedPreferencesCompleter.future;
    await preferences?.setBool('autoLaunch', config.appSetting.autoLaunch);

    final jsonStr = json.encode(config);

    try {
      await preferences?.setString(configKey, jsonStr);
      // Метка пишется ПОСЛЕ содержимого: если процесс умрёт между ними,
      // savedAt останется старым и устаревший prefs не «перебьёт» файл.
      await preferences?.setInt(
        _savedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      commonPrint.log('Failed to mirror config to preferences: $e');
    }

    return _saveLock.synchronized(() async {
      try {
        final configFilePath = await appPath.appConfigPath;
        final tempFile = File('$configFilePath.${DateTime.now().microsecondsSinceEpoch}.tmp');
        await tempFile.parent.create(recursive: true);
        await tempFile.writeAsString(jsonStr, flush: true);
        try {
          await tempFile.rename(configFilePath);
        } catch (_) {
          // rename() может не перезаписать существующий файл (Windows) —
          // тогда копируем поверх и убираем временный файл.
          if (await tempFile.exists()) {
            await tempFile.copy(configFilePath);
            await tempFile.delete();
          }
        }
        return true;
      } catch (e, stackTrace) {
        commonPrint.log('Failed to save config to file: $e\n$stackTrace');
        return false;
      }
    });
  }

  Future<void> clearClashConfig() async {
    final preferences = await sharedPreferencesCompleter.future;
    preferences?.remove(clashConfigKey);
  }

  Future<void> clearPreferences() async {
    final sharedPreferencesIns = await sharedPreferencesCompleter.future;
    await sharedPreferencesIns?.clear();
    try {
      final file = File(await appPath.appConfigPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
    try {
      final ipFile = File(await appPath.ipCacheFilePath);
      if (await ipFile.exists()) {
        await ipFile.delete();
      }
    } catch (_) {}
  }
}

final preferences = Preferences();
