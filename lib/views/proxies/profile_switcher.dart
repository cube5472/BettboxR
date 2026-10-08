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
/// null — файла профиля ещё нет, YAML не разобрался или провайдерные
/// кэши ещё не скачаны (профиль ни разу не применялся): на карточке
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
          Future<void> countCacheFile(String abs) async {
            try {
              final providerFile = File(abs);
              if (!await providerFile.exists()) {
                hasUnloadedProvider = true;
                return;
              }
              final providerDoc = loadYaml(await providerFile.readAsString());
              final providerProxies = providerDoc is Map
                  ? providerDoc['proxies']
                  : null;
              if (providerProxies is List) count += providerProxies.length;
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
              );
            } else {
              // file-провайдер или провайдер с ручным путём.
              final providerPath = entry['path'];
              if (providerPath is! String || providerPath.isEmpty) continue;
              final abs = p.isAbsolute(providerPath)
                  ? providerPath
                  : p.join(homeDir, providerPath);
              await countCacheFile(abs);
            }
          }
        }
        if (count == 0 && hasUnloadedProvider) return null;
        return count;
      } on Object {
        return null;
      }
    });

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
