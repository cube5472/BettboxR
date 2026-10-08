import 'dart:convert';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/profiles/edit_profile.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Число нод в конфиге профиля: статические proxies из файла профиля
/// плюс proxies из кэша proxy-провайдеров.
///
/// ВАЖНО: путь кэша http-провайдера нельзя брать из файла профиля —
/// при каждом применении конфига приложение переписывает поле `path`
/// каждого http-провайдера на свой приватный файл
/// (state.dart, patchRawConfig → getProvidersFilePath:
/// `profiles/providers/<id>/proxies/<md5(url)>`), именно туда ядро
/// скачивает подписку. Поэтому счётчик вызывает тот же
/// [appPath.getProvidersFilePath] — один источник правды с ядром.
/// Для file-провайдеров и ручных путей резолвим как ядро
/// (C.Path.Resolve): относительный путь — от home-каталога.
///
/// Разбор кэша зеркалит парсер провайдеров ядра (adapter/provider):
/// 1) YAML с полем `proxies:` — считаем поимённо, дубликаты имён
///    выкидываются (proxiesSet), учитывается exclude-filter;
/// 2) иначе список share-ссылок (ConvertsV2Ray, в т.ч. base64-блоб):
///    считаются строки с известной схемой, имя берётся из фрагмента
///    (у ядра имена размножаются uniqueName — дедупа нет),
///    vmess-base64-JSON требует поле `ps`, для vless/trojan/tuic
///    обязаны быть host и порт. exclude-filter применяется к имени.
///
/// null — файла профиля ещё нет, провайдерные кэши ещё не скачаны
/// (профиль ни разу не применялся) или файл не читается: на карточке
/// ничего не рисуем.
///
/// Пересчитывается при любом изменении списка профилей (обновление
/// подписки, пересборка, правка файла) и при возврате на вкладку
/// (autoDispose) — кэш провайдера мог обновиться ядром.
final profileNodeCountProvider = FutureProvider.autoDispose
    .family<int?, String>((ref, profileId) async {
      final profiles = ref.watch(profilesProvider);
      final profile = profiles.getProfile(profileId);
      if (profile == null) return null;
      try {
        final path = await appPath.getProfilePath(profile.id);
        final file = File(path);
        if (!await file.exists()) return null;
        final content = await file.readAsString();
        final doc = loadYaml(content);
        var count = 0;
        // Правда ли, что какой-то провайдер ещё не скачан/не читается:
        // тогда при нулевом итоге честного числа у нас нет.
        var hasUnloadedProvider = false;
        final proxies = doc is Map ? doc['proxies'] : null;
        if (proxies is List) count += proxies.length;
        final providers = doc is Map ? doc['proxy-providers'] : null;
        if (providers is Map) {
          final homeDir = await appPath.homeDirPath;
          Future<void> countCacheFile(String abs, Object? excludeFilter) async {
            try {
              final providerFile = File(abs);
              if (!await providerFile.exists()) {
                hasUnloadedProvider = true;
                return;
              }
              count += _countProviderContent(
                await providerFile.readAsString(),
                excludeFilter,
              );
            } on Object {
              // Битый или недокачанный кэш провайдера.
              hasUnloadedProvider = true;
            }
          }

          for (final entry in providers.values) {
            if (entry is! Map) continue;
            final url = entry['url'];
            if (entry['type'] == 'http' && url is String && url.isNotEmpty) {
              // Тот же путь, что назначает приложение при применении
              // конфига (patchRawConfig) — там ядро держит кэш.
              await countCacheFile(
                await appPath.getProvidersFilePath(
                  profile.id,
                  'proxies',
                  url,
                ),
                entry['exclude-filter'],
              );
            } else {
              // file-провайдер или провайдер с ручным путём.
              final providerPath = entry['path'];
              if (providerPath is! String || providerPath.isEmpty) continue;
              final abs = p.isAbsolute(providerPath)
                  ? providerPath
                  : p.join(homeDir, providerPath);
              await countCacheFile(abs, entry['exclude-filter']);
            }
          }
        }
        if (count == 0 && hasUnloadedProvider) return null;
        return count;
      } on Object {
        return null;
      }
    });

/// Схемы share-ссылок, которые понимает парсер провайдеров ядра
/// (core/Clash.Meta, common/convert/converter.go → ConvertsV2Ray).
const Set<String> _kShareLinkSchemes = {
  'hysteria',
  'hysteria2',
  'hy2',
  'hysteria2+realm',
  'hy2+realm',
  'tuic',
  'trojan',
  'vless',
  'vmess',
  'ss',
  'ssr',
  'socks',
  'socks5',
  'socks5h',
  'http',
  'https',
  'anytls',
  'mierus',
};

/// Считает ноды в содержимом кэша провайдера тем же способом, что и
/// ядро: сначала YAML с `proxies:`, при неудаче — список share-ссылок
/// (ConvertsV2Ray, включая base64-блоб целиком).
int _countProviderContent(String content, Object? excludeFilter) {
  RegExp? exclude;
  if (excludeFilter is String && excludeFilter.trim().isNotEmpty) {
    try {
      exclude = RegExp(excludeFilter.trim());
    } on Object {
      // Битый regex в конфиге — ядро упало бы на нём, нам просто
      // считаем без фильтра.
    }
  }
  Object? doc;
  try {
    doc = loadYaml(content);
  } on Object {
    doc = null;
  }
  if (doc is Map && doc['proxies'] is List) {
    return _countYamlProxies(doc['proxies'] as List, exclude);
  }
  return _countShareLinkLines(content, exclude);
}

/// YAML-ветка ядра: имя обязательно, дедуп по имени (proxiesSet),
/// exclude-filter по имени.
int _countYamlProxies(List proxies, RegExp? exclude) {
  final seen = <String>{};
  var count = 0;
  for (final item in proxies) {
    if (item is! Map) continue;
    final name = item['name'];
    if (name is! String || name.isEmpty) continue;
    if (exclude != null && exclude.hasMatch(name)) continue;
    if (!seen.add(name)) continue;
    count++;
  }
  return count;
}

/// Ветка share-ссылок (ConvertsV2Ray): base64-блоб разворачивается,
/// дальше построчно. Дедупа нет — ядро размножает имена через
/// uniqueName, поэтому считаем каждую валидную строку.
int _countShareLinkLines(String content, RegExp? exclude) {
  final text = _tryBase64Body(content) ?? content;
  var count = 0;
  for (final raw in text.split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    final sep = line.indexOf('://');
    if (sep <= 0) continue;
    final scheme = line.substring(0, sep).toLowerCase();
    if (!_kShareLinkSchemes.contains(scheme)) continue;
    final uri = Uri.tryParse(line);
    if (uri == null) continue;
    final name = _decodedFragment(uri);
    if (name == null) continue; // битые %-последовательности — ядро выкидывает строку
    if (scheme == 'vmess') {
      // V2RayN-стиль: vmess://base64(JSON с обязательным полем ps);
      // иначе — Xray VMessAEAD-ссылка, требующая host и порт.
      final ps = _vmessJsonName(line.substring(sep + 3));
      if (ps != null) {
        if (exclude == null || !exclude.hasMatch(ps)) count++;
      } else if (uri.host.isNotEmpty && uri.port != 0) {
        if (exclude == null || !exclude.hasMatch(name)) count++;
      }
      continue;
    }
    if (uri.host.isEmpty) continue;
    // vless/trojan/tuic: ядро требует непустые host и port
    // (handleVShareLink и аналоги); hysteria/hysteria2/ss — порт может
    // отсутствовать, ядро подставляет дефолт или берёт из тела.
    final portRequired =
        scheme == 'vless' || scheme == 'trojan' || scheme == 'tuic';
    if (portRequired && uri.port == 0) continue;
    if (exclude != null && exclude.hasMatch(name)) continue;
    count++;
  }
  return count;
}

/// Имя ноды из фрагмента ссылки. Ядро берёт url.Fragment — он уже
/// процитирован/декодирован; Dart Uri.fragment возвращает сырое
/// значение — декодируем вручную. null — битые %-последовательности
/// (ядро в таком случае выкидывает всю строку на url.Parse).
String? _decodedFragment(Uri uri) {
  try {
    return Uri.decodeComponent(uri.fragment);
  } on Object {
    return null;
  }
}

/// Зеркало DecodeBase64 ядра: весь файл как один base64-блоб
/// (RawStdEncoding, затем StdEncoding, стандартный алфавит). При
/// неудаче — null (используем текст как есть).
String? _tryBase64Body(String s) {
  final trimmed = s.trim();
  if (trimmed.isEmpty || trimmed.contains('\n') || trimmed.contains('\r')) {
    return null;
  }
  if (!RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(trimmed)) return null;
  if (trimmed.length % 4 == 1) return null;
  final padded = trimmed.padRight(
    (trimmed.length + 3) ~/ 4 * 4,
    '=',
  );
  try {
    final decoded = utf8.decode(base64.decode(padded));
    return decoded.contains('://') ? decoded : null;
  } on Object {
    return null;
  }
}

/// Имя vmess-ссылки V2RayN-стиля: base64(JSON), поле `ps` обязательно
/// (ядро: values["ps"].(string), иначе строка пропускается). Алфавит —
/// стандартный, как tryDecodeBase64 ядра.
String? _vmessJsonName(String body) {
  final b64 = body.trim();
  if (b64.isEmpty || b64.length % 4 == 1) return null;
  if (!RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(b64)) return null;
  final padded = b64.padRight((b64.length + 3) ~/ 4 * 4, '=');
  try {
    final decoded = jsonDecode(utf8.decode(base64.decode(padded)));
    if (decoded is Map && decoded['ps'] is String) {
      return decoded['ps'] as String;
    }
  } on Object {
    // Не vmess-JSON — возможно, AEAD-ссылка или мусор.
  }
  return null;
}

/// Панель быстрого переключения конфигов (профилей) во вкладке «Прокси».
///
/// Горизонтальная лента чипов под верхней панелью: активный конфиг
/// выделен, тап переключает активный профиль. Механика переключения —
/// та же, что на странице «Конфигурации»: присвоение
/// [currentProfileIdProvider], после чего ClashManager (листенер
/// needSetupProvider) сам применяет новый конфиг к ядру — в том числе
/// на лету, при работающем VPN.
///
/// Показывается автоматически, только когда профилей два и больше:
/// с одним конфигом переключать нечего и панель скрыта.
///
/// Долгое нажатие на чип открывает редактирование этого конфига —
/// тот же экран правки профиля, что и на странице «Конфигурации»
/// (имя, подписка, автообновление, правка файла конфига).
class ProxiesProfileSwitcher extends ConsumerWidget {
  const ProxiesProfileSwitcher({super.key});

  Future<void> _handleSwitch(WidgetRef ref, Profile profile) async {
    if (ref.read(currentProfileIdProvider) == profile.id) {
      return;
    }
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  void _handleEdit(BuildContext context, Profile profile) {
    showExtend(
      context,
      builder: (_, type) {
        return AdaptiveSheetScaffold(
          type: type,
          body: EditProfileView(profile: profile, context: context),
          title: appLocalizations.edit,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final currentProfileId = ref.watch(currentProfileIdProvider);
    if (profiles.length < 2) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 56,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        itemCount: profiles.length,
        itemBuilder: (context, index) {
          final profile = profiles[index];
          final isSelected = profile.id == currentProfileId;
          final nodeCount = ref
              .watch(profileNodeCountProvider(profile.id))
              .valueOrNull;
          return Padding(
            padding: EdgeInsets.only(
              right: index == profiles.length - 1 ? 0 : 8,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: CommonCard(
                isSelected: isSelected,
                radius: 16,
                onPressed: () => _handleSwitch(ref, profile),
                onLongPress: globalState.isAndroidTV
                    ? null
                    : () => _handleEdit(context, profile),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isSelected
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                        size: 18,
                        color: isSelected
                            ? context.colorScheme.primary
                            : context.colorScheme.outline,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: EmojiText(
                          profile.label ?? profile.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: isSelected
                                ? context.colorScheme.primary
                                : null,
                          ),
                        ),
                      ),
                      if (nodeCount != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color:
                                (isSelected
                                        ? context.colorScheme.primary
                                        : context.colorScheme.onSurfaceVariant)
                                    .withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '$nodeCount',
                            style: TextStyle(
                              fontSize: 11,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              fontWeight: FontWeight.w600,
                              color: isSelected
                                  ? context.colorScheme.primary
                                  : context.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
