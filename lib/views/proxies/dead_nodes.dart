// Удаление мёртвых нод из конфига профиля — «рядом со скрытием» в списке
// прокси. Мёртвая нода = delay < 0 по последней проверке в этой группе.
//
// Правила удаления:
//  - ноды, выбранные хоть в одной группе (и «now» текущей), не трогаются;
//  - статические ноды вырезаются из `proxies:` и из списков всех групп;
//  - ноды подписок (proxy-providers) не удаляются физически (их вернёт
//    обновление), а скрываются: имя дописывается в `exclude-filter`
//    своего провайдера через '|'.
// После правки конфиг валидируется ядром (saveFileWithString) и
// переприменяется, если профиль активен (setProfileAndAutoApply).
//
// Синхронизация маркера генератора: конфиги, собранные генератором,
// несут в шапке `# bettboxr-params: {JSON}` параметры сборки — без
// правки «Пересобрать» вернул бы удалённые ноды, а сам loadYaml/
// yamlDump комментарии теряют. Поэтому шапка переносится отдельно:
//  - статические ноды вырезаются из params.proxies (в т.ч. копии
//    дублей '<имя>-<N>' — см. ensureUniqueNames);
//  - для нод подписок имена дописываются в exclude подписки;
//  - для основного провайдера (режим provider) — в providerExclude.
// У не-генераторных конфигов комментарии шапки сохраняются как были.
import 'dart:convert';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/generator/generator_core.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaml/yaml.dart';

const _groupTypeNames = {
  'selector',
  'urltest',
  'url-test',
  'fallback',
  'loadbalance',
  'load-balance',
  'relay',
};

List<String> collectDeadNodeNames(WidgetRef ref, Group group) {
  final selectedNames = ref.read(selectedMapProvider).values.toSet();
  final now = group.now;
  if (now != null && now.isNotEmpty) {
    selectedNames.add(now);
  }
  final deadNames = <String>[];
  for (final proxy in group.all) {
    if (selectedNames.contains(proxy.name)) {
      continue;
    }
    if (_groupTypeNames.contains(proxy.type.toLowerCase())) {
      continue;
    }
    final delay = ref.read(
      getDelayProvider(proxyName: proxy.name, testUrl: group.testUrl),
    );
    if (delay != null && delay < 0) {
      deadNames.add(proxy.name);
    }
  }
  return deadNames;
}

dynamic _plainifyNode(dynamic value) {
  if (value is YamlMap) {
    return value.map<String, dynamic>(
      (key, v) => MapEntry('$key', _plainifyNode(v)),
    );
  }
  if (value is YamlList) {
    return value.map(_plainifyNode).toList();
  }
  return value;
}

final RegExp _subKeyRe = RegExp(r'^sub(\d+)$');

/// Индекс подписки в params.reserveSubscriptions по ключу провайдера
/// subK. buildConfig нумерует подряд только подписки с непустым
/// http(s)-URL, поэтому sub2 — вторая ВАЛИДНАЯ подписка списка, а не
/// просто вторая строка.
int? _paramsSubIndexForKey(String key, GeneratorParams params) {
  final match = _subKeyRe.firstMatch(key);
  if (match == null) return null;
  final target = int.tryParse(match.group(1)!);
  if (target == null || target < 1) return null;
  var seen = 0;
  for (var i = 0; i < params.reserveSubscriptions.length; i++) {
    final url = (params.reserveSubscriptions[i]['url'] ?? '').trim();
    if (url.isEmpty) continue;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      continue;
    }
    seen++;
    if (seen == target) return i;
  }
  return null;
}

/// Дописывает альтернативу в regex-список через '|', не создавая дублей:
/// тот же формат, что у append в exclude-filter провайдера.
String _appendToRegexAlternatives(String exclude, String escaped) {
  final existing = exclude.trim();
  final tokens = existing.isEmpty ? <String>[] : existing.split('|');
  if (tokens.contains(escaped)) return existing;
  return existing.isEmpty ? escaped : '$existing|$escaped';
}

void _appendToExclude(GeneratorParams params, int index, String escaped) {
  final sub = params.reserveSubscriptions[index];
  sub['exclude'] = _appendToRegexAlternatives(sub['exclude'] ?? '', escaped);
}

/// Статические ноды: по одной записи params.proxies на каждую удалённую.
/// ensureUniqueNames при сборке переименовывает дубли в '<имя>-<N>' в
/// КОПИЯХ (params.proxies хранит оригиналы), поэтому живое имя 'X-1'
/// может значиться в параметрах записью 'X' — точное имя не нашлось,
/// вырезаем одну запись базового имени.
void _removeStaticFromParams(GeneratorParams params, List<String> dead) {
  final unmatched = <String>[];
  for (final name in dead) {
    final index = params.proxies.indexWhere(
      (p) => '${p['name']}' == name,
    );
    if (index >= 0) {
      params.proxies.removeAt(index);
    } else {
      unmatched.add(name);
    }
  }
  for (final name in unmatched) {
    final dup = RegExp(r'^(.+)-\d+$').firstMatch(name);
    if (dup == null) continue;
    final base = dup.group(1)!;
    final index = params.proxies.indexWhere(
      (p) => '${p['name']}' == base,
    );
    if (index >= 0) {
      params.proxies.removeAt(index);
    }
  }
}

/// Шапка файла: начальные пустые строки и комментарии до первого
/// содержательного YAML (то же правило «маркер в начале файла», что у
/// extractGeneratorParams). Возвращает '' если конфиг начинается сразу
/// с содержимого; переводы строк нормализуются к \n.
String _extractYamlHeader(String raw) {
  final lines = raw.replaceAll('\r\n', '\n').split('\n');
  final header = <String>[];
  for (final line in lines) {
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      header.add(line);
    } else {
      break;
    }
  }
  return header.isEmpty ? '' : '${header.join('\n')}\n';
}

Future<void> deleteDeadNodesFlow(
  BuildContext context,
  WidgetRef ref,
  Group group,
) async {
  final deadNames = collectDeadNodeNames(ref, group);
  if (deadNames.isEmpty) {
    globalState.showNotifier(appLocalizations.deleteUnavailableEmpty);
    return;
  }
  final profile = ref.read(currentProfileProvider);
  final isSubLinked = (profile?.url.isNotEmpty ?? false);

  final confirmed = await globalState.showCommonDialog<bool>(
    child: CommonDialog(
      title: appLocalizations.deleteUnavailable,
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop(false);
          },
          child: Text(appLocalizations.cancel),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop(true);
          },
          child: Text(appLocalizations.delete),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appLocalizations.deleteUnavailableBody(deadNames.length)),
          const SizedBox(height: 8),
          for (final name in deadNames.take(8))
            EmojiText(
              '• $name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          if (deadNames.length > 8)
            Text(
              appLocalizations.deleteUnavailableMore(deadNames.length - 8),
              style: Theme.of(context).textTheme.labelSmall?.toLight,
            ),
          if (isSubLinked) ...[
            const SizedBox(height: 8),
            Text(
              appLocalizations.deleteUnavailableAutoUpdateNote,
              style: Theme.of(context).textTheme.labelSmall?.toLight,
            ),
          ],
        ],
      ),
    ),
  );
  if (confirmed != true || !context.mounted) {
    return;
  }

  try {
    final result = await _deleteDeadNodesFromProfile(ref, deadNames);
    var message = appLocalizations.deleteUnavailableDone(result.removed);
    if (result.misses.isNotEmpty) {
      message += ' · ${result.misses.take(4).join(', ')}';
    }
    globalState.showNotifier(message);
  } on Object catch (e) {
    globalState.showNotifier(e.formatError);
  }
}

class _DeleteResult {
  final int removed;
  final List<String> misses;
  const _DeleteResult(this.removed, this.misses);
}

/// Удаление ОДНОЙ ноды по удержанию карточки: работает и для живых нод,
/// не только для мёртвых. Группы не удаляются (это другой механизм);
/// выбранная нода удаляется с предупреждением — после удаления выбор
/// в группах, где была выбрана эта нода, сбрасывается. При подтверждении
/// тот же механизм ([_deleteDeadNodesFromProfile]) с синком маркера
/// генератора.
///
/// В режиме ручной сортировки удаление срабатывает по «удержанию без
/// движения» (см. ProxyDragTile.onHoldNoMove), а в остальных режимах —
/// по обычному долгому нажатию на карточку.
Future<void> deleteSingleNodeFlow(
  BuildContext context,
  WidgetRef ref,
  Group group,
  Proxy proxy,
) async {
  final name = proxy.name;
  if (_groupTypeNames.contains(proxy.type.toLowerCase())) {
    globalState.showNotifier(appLocalizations.deleteNodeGroupTip);
    return;
  }
  final selectedNames = ref.read(selectedMapProvider).values.toSet();
  final now = group.now;
  if (now != null && now.isNotEmpty) {
    selectedNames.add(now);
  }
  final isSelected = selectedNames.contains(name);
  final profile = ref.read(currentProfileProvider);
  final isSubLinked = (profile?.url.isNotEmpty ?? false);

  final confirmed = await globalState.showCommonDialog<bool>(
    child: CommonDialog(
      title: appLocalizations.deleteNodeTitle,
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop(false);
          },
          child: Text(appLocalizations.cancel),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop(true);
          },
          child: Text(appLocalizations.delete),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EmojiText(
            appLocalizations.deleteNodeBody(name),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          if (isSelected) ...[
            const SizedBox(height: 8),
            Text(
              appLocalizations.deleteNodeSelectedNote,
              style: Theme.of(context).textTheme.labelSmall?.toLight,
            ),
          ],
          if (isSubLinked) ...[
            const SizedBox(height: 8),
            Text(
              appLocalizations.deleteUnavailableAutoUpdateNote,
              style: Theme.of(context).textTheme.labelSmall?.toLight,
            ),
          ],
        ],
      ),
    ),
  );
  if (confirmed != true || !context.mounted) {
    return;
  }

  try {
    final result = await _deleteDeadNodesFromProfile(ref, [name]);
    if (result.removed > 0 && isSelected) {
      // Выбор в группах, где была выбрана удалённая нода, сбрасываем,
      // иначе UI будет показывать выделение несуществующей карточки.
      ref.read(selectedMapProvider).forEach((groupName, selectedName) {
        if (selectedName == name) {
          globalState.appController.updateCurrentSelectedMap(groupName, '');
        }
      });
    }
    var message = appLocalizations.deleteUnavailableDone(result.removed);
    if (result.misses.isNotEmpty) {
      message += ' · ${result.misses.first}';
    }
    globalState.showNotifier(message);
  } on Object catch (e) {
    globalState.showNotifier(e.formatError);
  }
}


Future<_DeleteResult> _deleteDeadNodesFromProfile(
  WidgetRef ref,
  List<String> deadNames,
) async {
  final profile = ref.read(currentProfileProvider);
  if (profile == null) {
    return _DeleteResult(0, deadNames);
  }
  final file = await profile.getFile();
  final raw = await file.readAsString();
  final config = _plainifyNode(loadYaml(raw));
  if (config is! Map<String, dynamic> || config.isEmpty) {
    throw 'profile config is not a valid YAML map';
  }

  final proxiesRaw = config['proxies'];
  final staticNames = <String>{};
  if (proxiesRaw is List) {
    for (final entry in proxiesRaw) {
      if (entry is Map && entry['name'] is String) {
        staticNames.add(entry['name'] as String);
      }
    }
  }
  final staticDead = deadNames.where(staticNames.contains).toList();
  final providerDead = deadNames
      .where((name) => !staticNames.contains(name))
      .toList();

  // Параметры из маркера генератора (см. шапку файла): синхронизируются
  // с удалением ниже, чтобы пересборка не воскресила мёртвые ноды.
  // null — конфиг собран не генератором: синковать нечего, но шапку
  // (пользовательские комментарии) всё равно сохраняем.
  final params = extractGeneratorParams(raw);
  var providerExcludeAcc = params?.providerExclude ?? '';

  var removed = 0;
  final misses = <String>[];

  // 1. Статические ноды: proxies + все списки групп.
  if (staticDead.isNotEmpty) {
    final keepStatic = staticNames.difference(staticDead.toSet());
    if (keepStatic.isEmpty) {
      throw appLocalizations.deleteUnavailableLastStatic;
    }
    config['proxies'] = (proxiesRaw as List).where((entry) {
      final name = entry is Map ? entry['name'] : null;
      return !staticDead.contains(name);
    }).toList();
    final groupsRaw = config['proxy-groups'];
    if (groupsRaw is List) {
      for (var i = 0; i < groupsRaw.length; i++) {
        final groupEntry = groupsRaw[i];
        if (groupEntry is Map && groupEntry['proxies'] is List) {
          final groupMap = Map<String, dynamic>.from(groupEntry);
          groupMap['proxies'] = (groupMap['proxies'] as List)
              .where((name) => !staticDead.contains(name))
              .toList();
          groupsRaw[i] = groupMap;
        }
      }
    }
    removed += staticDead.length;
    if (params != null) {
      _removeStaticFromParams(params, staticDead);
    }
  }

  // 2. Ноды провайдеров: дописываем в exclude-filter владельца.
  if (providerDead.isNotEmpty) {
    final providers = ref.read(providersProvider);
    final owners = <String, Set<String>>{};
    for (final provider in providers) {
      for (final proxy in provider.proxies ?? const []) {
        if (proxy is Map) {
          final name = proxy['name'];
          if (name is String) {
            owners.putIfAbsent(name, () => <String>{}).add(provider.name);
          }
        }
      }
    }
    final providersConfig = config['proxy-providers'];
    for (final name in providerDead) {
      final providerNames = owners[name];
      if (providerNames == null || providerNames.isEmpty) {
        misses.add(name);
        continue;
      }
      var touched = false;
      for (final providerName in providerNames) {
        if (providersConfig is Map && providersConfig[providerName] is Map) {
          final entry = Map<String, dynamic>.from(
            providersConfig[providerName],
          );
          final existing = entry['exclude-filter'] is String
              ? entry['exclude-filter'] as String
              : '';
          final escaped = RegExp.escape(name);
          if (!existing.split('|').contains(escaped)) {
            entry['exclude-filter'] = existing.isEmpty
                ? escaped
                : '$existing|$escaped';
            providersConfig[providerName] = entry;
          }
          touched = true;
        }
        // Синк в маркер — независимо от успеха правки конфига: параметры
        // пересборки должны знать об удалении даже если провайдер в
        // конфиге не нашёлся (misss считается по конфигу).
        if (params != null) {
          if (providerName == 'subscription') {
            providerExcludeAcc = _appendToRegexAlternatives(
              providerExcludeAcc,
              RegExp.escape(name),
            );
          } else {
            final subIndex = _paramsSubIndexForKey(providerName, params);
            if (subIndex != null) {
              _appendToExclude(params, subIndex, RegExp.escape(name));
            }
          }
        }
      }
      if (touched) {
        removed++;
      } else {
        misses.add(name);
      }
    }
  }

  if (removed == 0) {
    return _DeleteResult(0, misses.isEmpty ? deadNames : misses);
  }

  final dumped = yamlDump(config);
  final String newYaml;
  if (params != null) {
    // Генераторный конфиг: шапку собираем заново из синхронизированных
    // параметров — формат тот же, что у embedGeneratorMarker; ключ
    // providerExclude докидывается в JSON напрямую (поле params final,
    // а копировать объект ради одного поля избыточно).
    final json = generatorParamsToJson(params);
    json['providerExclude'] = providerExcludeAcc;
    newYaml =
        '$kGeneratorMarkerLine\n'
        '$kGeneratorParamsPrefix${jsonEncode(json)}\n'
        '$dumped';
  } else {
    // Не-генераторный: сохраняем исходные комментарии шапки как были
    // (loadYaml их теряет).
    final header = _extractYamlHeader(raw);
    newYaml = header.isEmpty ? dumped : '$header$dumped';
  }
  final newProfile = await profile.saveFileWithString(newYaml);
  globalState.appController.setProfileAndAutoApply(newProfile);
  return _DeleteResult(removed, misses);
}
