import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
class ProxiesProfileSwitcher extends ConsumerWidget {
  const ProxiesProfileSwitcher({super.key});

  Future<void> _handleSwitch(WidgetRef ref, Profile profile) async {
    if (ref.read(currentProfileIdProvider) == profile.id) {
      return;
    }
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
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
          return Padding(
            padding: EdgeInsets.only(right: index == profiles.length - 1 ? 0 : 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: CommonCard(
                isSelected: isSelected,
                radius: 16,
                onPressed: () => _handleSwitch(ref, profile),
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
