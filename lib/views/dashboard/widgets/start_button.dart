import 'dart:async';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/plugins/vpn.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:bett_box/views/profiles/add_profile.dart';

class StartButton extends ConsumerStatefulWidget {
  const StartButton({super.key});

  @override
  ConsumerState<StartButton> createState() => _StartButtonState();
}

class _StartButtonState extends ConsumerState<StartButton> {
  bool _isDisabled = false;
  bool? _optimisticStart;

  @override
  void initState() {
    super.initState();
    // Пауза: подписка на пуш-обновления канала + стартовый sync.
    VpnPauseState.ensureInitialized();
    VpnPauseState.untilTs.addListener(_onPauseChanged);
  }

  @override
  void dispose() {
    VpnPauseState.untilTs.removeListener(_onPauseChanged);
    super.dispose();
  }

  void _onPauseChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _handleResumeNow() async {
    await VpnPauseState.resumeNow();
  }

  void _showPauseMenu() {
    showSheet(
      context: context,
      builder: (_, type) {
        return AdaptiveSheetScaffold(
          type: type,
          title: appLocalizations.pause,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final minutes in const [5, 15, 30])
                ListTile(
                  leading: Icon(
                    Icons.pause_circle_outline,
                    color: context.colorScheme.primary,
                  ),
                  title: Text(appLocalizations.pauseForMinutes(minutes)),
                  onTap: () {
                    Navigator.of(context, rootNavigator: true).pop();
                    VpnPauseState.pause(minutes);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _handleStart() async {
    if (_isDisabled) return;
    final isStart = ref.read(runTimeProvider) != null;
    final newState = !isStart;
    setState(() {
      _isDisabled = true;
      _optimisticStart = newState;
    });

    try {
      await globalState.appController.updateStatus(newState);
    } catch (e) {
      commonPrint.log('updateStatus failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isDisabled = false;
          _optimisticStart = null;
        });
      }
    }
  }

  Future<void> _handleLongPress() async {
    final isStart = ref.read(runTimeProvider) != null;
    if (!isStart) return;

    final result = await globalState.showCommonDialog<bool>(
      child: CommonDialog(
        title: appLocalizations.restartCoreTitle,
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
            child: Text(appLocalizations.confirm),
          ),
        ],
        child: Text(appLocalizations.restartCoreDesc),
      ),
    );

    if (result == true) {
      await globalState.appController.restartCore();
      globalState.showNotifier(appLocalizations.success);
    }
  }

  void _handleShowAddProfile() {
    showExtend(
      context,
      builder: (_, type) {
        return AdaptiveSheetScaffold(
          type: type,
          body: AddProfileView(
            context: context,
          ),
          title: appLocalizations.add,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(startButtonSelectorStateProvider);
    final isSmartStopped = ref.watch(isSmartStoppedProvider);
    final isRestarting = ref.watch(isRestartingCoreProvider);

    return ValueListenableBuilder<int>(
      valueListenable: dashboardRefreshManager.tick1s,
      builder: (_, _, _) {
        final runTime = ref.read(runTimeProvider);
        final isStart = runTime != null;
        final pauseUntilTs = VpnPauseState.untilTs.value;
        final isPausedNow = pauseUntilTs > DateTime.now().millisecondsSinceEpoch;
        final displayStart =
            isSmartStopped ? false : (_optimisticStart ?? isStart);
        return SizedBox(
          height: getWidgetHeight(1),
          child: CommonCard(
            info: Info(
              label: isPausedNow
                  ? appLocalizations.pause
                  : isSmartStopped
                  ? appLocalizations.coreSuspended
                  : isRestarting
                  ? appLocalizations.restartCoreTitle
                  : displayStart
                  ? appLocalizations.runTime
                  : appLocalizations.powerSwitch,
              iconData: Icons.power_settings_new,
            ),
            onPressed: state.isInit &&
                    state.hasProfile &&
                    !_isDisabled &&
                    (!isSmartStopped || isPausedNow)
                ? (isPausedNow ? _handleResumeNow : _handleStart)
                : state.isInit && !state.hasProfile && !_isDisabled && !isSmartStopped
                    ? _handleShowAddProfile
                    : null,
            onLongPress:
                state.isInit && state.hasProfile && !_isDisabled && !isSmartStopped
                    ? _handleLongPress
                    : null,
            child: Container(
              padding: baseInfoEdgeInsets.copyWith(top: 0),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    height: globalState.measure.bodyMediumHeight + 2,
                    child: FadeThroughBox(
                      child: _buildContent(
                        context,
                        ref,
                        state,
                        isStart,
                        runTime,
                        isRestarting,
                        _isDisabled,
                        isSmartStopped,
                        isPausedNow,
                        pauseUntilTs,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    StartButtonSelectorState state,
    bool isStart,
    int? runTime,
    bool isRestarting,
    bool isDisabled,
    bool isSmartStopped,
    bool isPausedNow,
    int pauseUntilTs,
  ) {
    if (isPausedNow) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Icon(
            Icons.pause_circle,
            size: 20,
            color: context.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _formatRemaining(
                pauseUntilTs - DateTime.now().millisecondsSinceEpoch,
              ),
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.colorScheme.primary,
              ).adjustSize(1),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    if (isSmartStopped) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Icon(
            Icons.pause_circle_outline,
            size: 20,
            color: context.colorScheme.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Suspended',
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.colorScheme.outline,
              ).adjustSize(1),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    if (!state.isInit || isDisabled) {
      return Container(
        padding: const EdgeInsets.all(2),
        child: Center(
          child: OverflowBox(
            maxWidth: 30,
            maxHeight: 16,
            child: SpinKitThreeBounce(
              color: context.colorScheme.primary,
              size: 16,
            ),
          ),
        ),
      );
    }

    if (!state.hasProfile) {
      return Text(
        appLocalizations.checkOrAddProfile,
        style: context.textTheme.bodyMedium?.toLight.adjustSize(1),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    if (isRestarting) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 16,
          height: 16,
          child: OverflowBox(
            maxWidth: 30,
            maxHeight: 16,
            child: SpinKitThreeBounce(
              color: context.colorScheme.primary,
              size: 16,
            ),
          ),
        ),
      );
    }

    if (!isStart) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Icon(Icons.play_arrow, size: 16, color: context.colorScheme.primary),
          SizedBox(width: 4),
          Expanded(
            child: Text(
              appLocalizations.serviceReady,
              style: context.textTheme.bodyMedium?.toLight.adjustSize(1),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    // Started state: tappable pause icon (5/15/30 min) + run time
    final timeText = _formatRunTime(runTime);
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _showPauseMenu,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Icon(Icons.pause, size: 16, color: context.colorScheme.primary),
          ),
        ),
        Expanded(
          child: Text(
            timeText,
            style: context.textTheme.bodyMedium?.toLight.adjustSize(1),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  String _formatRemaining(int ms) {
    if (ms < 0) ms = 0;
    final totalSeconds = (ms / 1000).ceil();
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  String _formatRunTime(int? timeStamp) {
    if (timeStamp == null) return '00:00:00';

    final diff = timeStamp / 1000;
    int inHours = (diff / 3600).floor();
    int inMinutes = (diff / 60 % 60).floor();
    int inSeconds = (diff % 60).floor();

    // Limit maximum display to 999:59:59
    if (inHours > 999) {
      inHours = 999;
      inMinutes = 59;
      inSeconds = 59;
    }

    // If less than 100 hours, show 2 digits; otherwise 3
    final hourStr = inHours < 100
        ? inHours.toString().padLeft(2, '0')
        : inHours.toString().padLeft(3, '0');

    return '$hourStr:${inMinutes.toString().padLeft(2, '0')}:${inSeconds.toString().padLeft(2, '0')}';
  }
}
