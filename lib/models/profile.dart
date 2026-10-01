// ignore_for_file: invalid_annotation_target
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bett_box/clash/core.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import 'clash_config.dart';
import 'sub_spoof.dart';

part 'generated/profile.freezed.dart';
part 'generated/profile.g.dart';

typedef SelectedMap = Map<String, String>;

@freezed
abstract class SubscriptionInfo with _$SubscriptionInfo {
  const factory SubscriptionInfo({
    @Default(0) int upload,
    @Default(0) int download,
    @Default(0) int total,
    @Default(0) int expire,
  }) = _SubscriptionInfo;

  factory SubscriptionInfo.fromJson(Map<String, Object?> json) =>
      _$SubscriptionInfoFromJson(json);

  static int? _parseValue(String? value) {
    if (value == null) return null;
    return int.tryParse(value) ?? double.tryParse(value)?.toInt();
  }

  factory SubscriptionInfo.formHString(String? info) {
    if (info == null) return const SubscriptionInfo();
    final list = info.split(';');
    Map<String, int?> map = {};
    for (final i in list) {
      final keyValue = i.trim().split('=');
      if (keyValue.length < 2) continue;
      map[keyValue[0]] = _parseValue(keyValue[1]);
    }
    return SubscriptionInfo(
      upload: map['upload'] ?? 0,
      download: map['download'] ?? 0,
      total: map['total'] ?? 0,
      expire: map['expire'] ?? 0,
    );
  }
}

extension SubscriptionInfoExtension on SubscriptionInfo {
  String? get expireDesc {
    if (expire > 0) {
      final expireDate =
          DateTime.fromMillisecondsSinceEpoch(expire * 1000).show;
      final isExpired =
          expire * 1000 < DateTime.now().millisecondsSinceEpoch;
      return isExpired
          ? '${appLocalizations.expired} · $expireDate'
          : expireDate;
    }
    return total > 0 ? appLocalizations.infiniteTime : null;
  }
}

@freezed
abstract class Profile with _$Profile {
  const factory Profile({
    required String id,
    String? label,
    String? currentGroupName,
    @Default('') String url,
    DateTime? lastUpdateDate,
    required Duration autoUpdateDuration,
    SubscriptionInfo? subscriptionInfo,
    @Default(true) bool autoUpdate,
    @Default({}) SelectedMap selectedMap,
    @Default({}) Set<String> unfoldSet,
    @Default(OverrideData()) OverrideData overrideData,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool isUpdating,
    @Default(true) bool useScriptOverride,
    String? ageSecretKey,
    @JsonKey(name: 'group-switches') @Default({}) Map<String, bool> groupSwitches,
  }) = _Profile;

  factory Profile.fromJson(Map<String, Object?> json) =>
      _$ProfileFromJson(json);

  factory Profile.normal({String? label, String url = '', String? ageSecretKey}) {
    return Profile(
      label: label,
      url: url,
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      autoUpdateDuration: defaultUpdateDuration,
      ageSecretKey: ageSecretKey,
    );
  }
}

@freezed
abstract class OverrideData with _$OverrideData {
  const factory OverrideData({
    @Default(false) bool enable,
    @Default(OverrideRule()) OverrideRule rule,
  }) = _OverrideData;

  factory OverrideData.fromJson(Map<String, Object?> json) =>
      _$OverrideDataFromJson(json);
}

extension OverrideDataExt on OverrideData {
  List<String> get runningRule {
    if (!enable) {
      return [];
    }
    return rule.rules.map((item) => item.value).toList();
  }
}

@freezed
abstract class OverrideRule with _$OverrideRule {
  const factory OverrideRule({
    @Default(OverrideRuleType.override) OverrideRuleType type,
    @Default([]) List<Rule> overrideRules,
    @Default([]) List<Rule> addedRules,
  }) = _OverrideRule;

  factory OverrideRule.fromJson(Map<String, Object?> json) =>
      _$OverrideRuleFromJson(json);
}

extension OverrideRuleExt on OverrideRule {
  List<Rule> get rules => switch (type == OverrideRuleType.override) {
    true => overrideRules,
    false => addedRules,
  };

  OverrideRule updateRules(List<Rule> Function(List<Rule> rules) builder) {
    if (type == OverrideRuleType.added) {
      return copyWith(addedRules: builder(addedRules));
    }
    return copyWith(overrideRules: builder(overrideRules));
  }
}

extension ProfilesExt on List<Profile> {
  Profile? getProfile(String? profileId) {
    final index = indexWhere((profile) => profile.id == profileId);
    return index == -1 ? null : this[index];
  }
}

extension ProfileExtension on Profile {
  ProfileType get type =>
      url.isEmpty == true ? ProfileType.file : ProfileType.url;

  bool get realAutoUpdate => url.isEmpty == true ? false : autoUpdate;

  Future<void> checkAndUpdate() async {
    final isExists = await check();
    if (!isExists) {
      if (url.isNotEmpty) {
        await update();
      }
    }
  }

  Future<bool> check() async {
    final profilePath = await appPath.getProfilePath(id);
    return await File(profilePath).exists();
  }

  Future<File> getFile() async {
    final path = await appPath.getProfilePath(id);
    final file = File(path);
    final isExists = await file.exists();
    if (!isExists) {
      await file.create(recursive: true);
    }
    return file;
  }

  Future<int> get profileLastModified async {
    final file = await getFile();
    return (await file.lastModified()).microsecondsSinceEpoch;
  }

  Future<Profile> update({bool validate = true}) async {
    // Подмена клиента подписки (User-Agent/X-Hwid + device-заголовки) —
    // индивидуальная настройка профиля, иначе глобальная клиентская
    // (Настройки → Общие → «Подмена клиента подписок»).
    final subSpoof = await resolveEffectiveSubSpoof(id);
    final response = await request.getFileResponseForUrl(
      url,
      extraHeaders: await subSpoof.resolveHeaders(),
    );
    // HWID-панели (3x-ui и форки) отвечают отказом HTTP 404 с маркерами
    // X-Hwid-Not-Supported / X-Hwid-Max-Devices-Reached; без проверки
    // пользователь увидит криптическую ошибку валидатора вместо причины.
    final hwidUnsupported =
        response.headers['x-hwid-not-supported']?.firstOrNull;
    if (hwidUnsupported != null) {
      throw Exception(
        'панель не поддерживает HWID-подмену для этой подписки '
        '(X-Hwid-Not-Supported) — отключите подмену X-Hwid или смените '
        'пресет клиента',
      );
    }
    final hwidMaxDevices =
        response.headers['x-hwid-max-devices-reached']?.firstOrNull;
    if (hwidMaxDevices != null) {
      throw Exception(
        'у панели исчерпан лимит устройств для этой подписки '
        '(X-Hwid-Max-Devices-Reached). Сбросьте устройства в боте/панели '
        'или впишите в подмене тот же X-Hwid, что у уже работающего '
        'клиента (например neko+)',
      );
    }
    final statusCode = response.statusCode ?? 0;
    if (statusCode >= 400) {
      throw Exception(
        'панель ответила отказом HTTP $statusCode. При включённой '
        'подмене это обычно значит: пресет клиента не принят '
        '(попробуйте другой), X-Hwid отклонён (впишите значение '
        'работающего клиента) либо ссылка недействительна',
      );
    }
    final disposition = response.headers['content-disposition']?.firstOrNull;
    final userinfo = response.headers['subscription-userinfo']?.firstOrNull;
    return await copyWith(
      label: label ?? utils.getFileNameForDisposition(disposition) ?? id,
      subscriptionInfo: SubscriptionInfo.formHString(userinfo),
    ).saveFile(response.data, validate: validate);
  }

  Future<Profile> saveFile(Uint8List bytes, {bool validate = true}) async {
    String content = utf8.decode(bytes);
    final key = ageSecretKey;
    if (key != null && key.isNotEmpty) {
      try {
        final decrypted = await clashCore.decryptAgeConfig(content, key);
        if (decrypted.isNotEmpty) {
          content = decrypted;
        }
      } catch (_) {}
    }
    content = await _convertSubBodyIfNeeded(this, content);
    content = utils.patchYamlConfig(content);
    if (validate) {
      final message =
          await clashCore.validateConfig(content, ageSecretKey: ageSecretKey);
      if (message.isNotEmpty) {
        final patched = utils.patchValidateConfig(content);
        if (patched != content) {
          final patchedMessage =
              await clashCore.validateConfig(patched, ageSecretKey: ageSecretKey);
          if (patchedMessage.isEmpty) {
            content = patched;
          } else {
            throw message;
          }
        } else {
          throw message;
        }
      }
    }
    final file = await getFile();
    await file.writeAsString(content);
    return copyWith(lastUpdateDate: DateTime.now());
  }

  Future<Profile> saveFileWithString(String value) async {
    String content = value;
    final key = ageSecretKey;
    if (key != null && key.isNotEmpty) {
      try {
        final decrypted = await clashCore.decryptAgeConfig(content, key);
        if (decrypted.isNotEmpty) {
          content = decrypted;
        }
      } catch (_) {}
    }
    content = await _convertSubBodyIfNeeded(this, content);
    content = utils.patchYamlConfig(content);
    final message =
        await clashCore.validateConfig(content, ageSecretKey: ageSecretKey);
    if (message.isNotEmpty) {
      final patched = utils.patchValidateConfig(content);
      if (patched != content) {
        final patchedMessage =
            await clashCore.validateConfig(patched, ageSecretKey: ageSecretKey);
        if (patchedMessage.isEmpty) {
          content = patched;
        } else {
          throw message;
        }
      } else {
        throw message;
      }
    }
    final file = await getFile();
    await file.writeAsString(content);
    return copyWith(lastUpdateDate: DateTime.now());
  }
}

// ---------------- Тело подписки в формате реального клиента ----------------
//
// Панели, проверяющие клиента (UA/X-Hwid), отвечают «подменным»
// запросам телом в формате реального приложения: построчные
// share-ссылки (vless://, ss://, trojan://, …), часто с #-шапкой
// (profile-title, subscription-userinfo), либо base64-блобом. Раньше
// такое тело сохранялось «как есть», и валидация ядра падала («это не
// YAML-конфиг») — профиль не создавался и «ноды не загружались», хотя
// в v2ray-клиентах (NekoBox+, Happ, …) та же подписка работала.
// Теперь тело распознаётся и оборачивается в минимальный mihomo-конфиг
// с proxy-provider на исходный URL: ядро само скачает и разберёт
// список ссылок (тот же конвертер, что обрабатывает провайдер
// генератора), а подмена профиля (UA/X-Hwid/device-заголовки) из
// SubSpoofStore переносится в заголовки провайдера.

final RegExp _subSchemeLineRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');
final RegExp _subHtmlRe = RegExp(
  r'^\s*(<!DOCTYPE|<html)',
  caseSensitive: false,
);

/// Похоже ли тело на готовый mihomo-конфиг (YAML или JSON).
bool _isMihomoConfigBody(String body) {
  final trimmed = body.trimLeft();
  if (trimmed.startsWith('{')) {
    // JSON-конфиг: ядро принимает JSON, не трогаем.
    return true;
  }
  return RegExp(
    r'^\s*(proxies|proxy-providers|proxy-groups|rule-providers)\s*:',
    multiLine: true,
  ).hasMatch(body);
}

/// Первая содержательная строка-ссылка (схема://…), либо null.
/// #-строки (шапка v2raytun/Happ-подписок) и пустые пропускаются.
String? _firstShareLinkLine(String body) {
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (_subSchemeLineRe.hasMatch(line)) return line;
    return null;
  }
  return null;
}

/// base64-блоб (v2ray-подписка), внутри которого share-ссылки.
bool _base64BodyHasShareLinks(String body) {
  final compact = body.replaceAll(RegExp(r'\s'), '');
  if (compact.length < 16) return false;
  if (!RegExp(r'^[A-Za-z0-9+/=\-_]+$').hasMatch(compact)) return false;
  try {
    final normalized = compact.replaceAll('-', '+').replaceAll('_', '/');
    final padding = (4 - normalized.length % 4) % 4;
    final decoded = utf8.decode(
      base64.decode(normalized + '=' * padding),
      allowMalformed: true,
    );
    return _firstShareLinkLine(decoded) != null;
  } catch (_) {
    return false;
  }
}

/// YAML-строка в двойных кавычках с экранированием спецсимволов.
/// Значения динамические (URL, UA, hwid, модель) — кавычим всегда.
String _subYamlQuote(String value) {
  final escaped = value
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('\n', '\\n')
      .replaceAll('\t', '\\t')
      .replaceAll('\r', '\\r');
  return '"$escaped"';
}

/// Распознаёт тело-«не конфиг» (share-ссылки / base64) и оборачивает
/// в конфиг с proxy-provider. YAML/JSON-конфиги и всё нераспознанное
/// проходят без изменений (их валидирует ядро как раньше). Осмысленно
/// распознанный отказ панели (HTML вместо подписки) даёт понятную
/// ошибку вместо криптики валидатора.
Future<String> _convertSubBodyIfNeeded(Profile profile, String content) async {
  final url = profile.url.trim();
  // Обёртка осмысленна только для URL-профилей: телу нужна ссылка
  // для proxy-provider. Файловые профили и вставки не трогаем.
  if (url.isEmpty ||
      (!url.startsWith('http://') && !url.startsWith('https://'))) {
    return content;
  }
  final trimmed = content.trim();
  if (trimmed.isEmpty) {
    return content;
  }
  if (_subHtmlRe.hasMatch(trimmed)) {
    throw Exception(
      'сервер вернул HTML-страницу вместо подписки — панель отклонила '
      'запрос (проверьте срок действия ссылки и подмену клиента)',
    );
  }
  // Отказ панели текстом (без HTTP-ошибки на уровне запроса): «Not found»
  // у HWID-панелей 3x-ui означает «устройство не найдено/лимит слотов»,
  // русское сообщение — «ключ перевыпущен/подписка кончилась».
  final lowered = trimmed.toLowerCase();
  if (trimmed.length <= 256 &&
      (lowered == 'not found' ||
          lowered.startsWith('ссылка на подписку') ||
          lowered.startsWith('the subscription link'))) {
    throw Exception(
      'панель отказала в выдаче подписки: ответ «$trimmed». Если панель '
      'привязывает устройства по X-Hwid — впишите в подмене тот же '
      'X-Hwid, что у работающего клиента (например neko+), или сбросьте '
      'устройства в боте/панели (см. README пакета)',
    );
  }
  if (_isMihomoConfigBody(trimmed)) {
    return content;
  }
  final isLinkList = _firstShareLinkLine(trimmed) != null;
  if (!isLinkList && !_base64BodyHasShareLinks(trimmed)) {
    return content;
  }
  return _buildSubProviderWrapper(profile);
}

/// Минимальный рабочий конфиг: provider с исходным URL + заголовки
/// подмены профиля + одна select-группа + MATCH-правило. Секции
/// tun/dns ядро и приложение дополняют при запуске, как и для любого
/// другого профиля.
Future<String> _buildSubProviderWrapper(Profile profile) async {
  Map<String, String>? headers;
  try {
    final spoof = await resolveEffectiveSubSpoof(profile.id);
    headers = await spoof.resolveHeaders();
  } catch (_) {}
  final b = StringBuffer()
    ..writeln('# bettboxr-sub-wrap: тело подписки (share-ссылки/base64)')
    ..writeln('# обёрнуто в proxy-provider — ядро скачивает и разбирает')
    ..writeln('# его само; заголовки подмены профиля сохранены.')
    ..writeln('mode: rule')
    ..writeln('log-level: silent')
    ..writeln('ipv6: true')
    ..writeln('proxy-providers:')
    ..writeln('  subscription:')
    ..writeln('    type: http')
    ..writeln('    url: ${_subYamlQuote(profile.url.trim())}')
    ..writeln('    interval: 86400')
    ..writeln('    path: ./provider/bettboxr_sub_${profile.id}.yaml')
    ..writeln('    override:')
    ..writeln('      skip-cert-verify: true')
    ..writeln('    health-check:')
    ..writeln('      enable: true')
    ..writeln('      url: https://www.gstatic.com/generate_204')
    ..writeln('      interval: 600');
  if (headers != null && headers.isNotEmpty) {
    b.writeln('    header:');
    headers.forEach((name, value) {
      b.writeln('      $name: [${_subYamlQuote(value)}]');
    });
  }
  b
    ..writeln('proxy-groups:')
    ..writeln('  - name: PROXY')
    ..writeln('    type: select')
    ..writeln('    use: [subscription]')
    ..writeln('rules:')
    ..writeln('  - MATCH,PROXY');
  return b.toString();
}
