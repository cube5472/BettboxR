import 'dart:io';
import 'dart:math';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class Window {
  Future<void> init() async {
    final props = globalState.config.windowProps;
    if (system.isWindows) {
      protocol.register('clash');
      protocol.register('clashmeta');
      protocol.register('bettbox');
    }
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = WindowOptions(
      size: Size(props.width, props.height),
      minimumSize: const Size(380, 400),
    );
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setAlwaysOnTop(props.isPinned);
    if (!system.isMacOS) {
      final left = props.left ?? 0;
      final top = props.top ?? 0;
      final width = props.width;
      final height = props.height;
      if (left == 0 && top == 0) {
        await windowManager.setAlignment(Alignment.center);
      } else {
        bool hasRestoredPosition = false;
        try {
          final displays = await screenRetriever.getAllDisplays();
          if (displays.isNotEmpty) {
            final windowRect = Rect.fromLTWH(left, top, width, height);
            Display? bestDisplay;
            double maxOverlapArea = 0;

            for (final display in displays) {
              final visiblePos = display.visiblePosition ?? Offset.zero;
              final visibleSize = display.visibleSize ?? display.size;
              final displayRect = Rect.fromLTWH(
                visiblePos.dx,
                visiblePos.dy,
                visibleSize.width,
                visibleSize.height,
              );

              if (!windowRect.overlaps(displayRect)) continue;

              final overlapL = max(windowRect.left, displayRect.left);
              final overlapT = max(windowRect.top, displayRect.top);
              final overlapR = min(windowRect.right, displayRect.right);
              final overlapB = min(windowRect.bottom, displayRect.bottom);

              final overlapArea = (overlapR - overlapL) * (overlapB - overlapT);
              if (overlapArea > maxOverlapArea) {
                maxOverlapArea = overlapArea;
                bestDisplay = display;
              }
            }

            final windowArea = width * height;
            if (bestDisplay != null && (maxOverlapArea / windowArea) >= 0.3) {
              final visiblePos = bestDisplay.visiblePosition ?? Offset.zero;
              final visibleSize = bestDisplay.visibleSize ?? bestDisplay.size;

              final minX = visiblePos.dx;
              final maxX = max(minX, visiblePos.dx + visibleSize.width - 100);
              final safeLeft = left.clamp(minX, maxX);

              final minY = visiblePos.dy;
              final maxY = max(minY, visiblePos.dy + visibleSize.height - 40);
              final safeTop = top.clamp(minY, maxY);

              await windowManager.setPosition(Offset(safeLeft, safeTop));
              hasRestoredPosition = true;
            }
          }
        } catch (_) {}

        if (!hasRestoredPosition) {
          await windowManager.setAlignment(Alignment.center);
        }
      }
    }
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setPreventClose(true);
    });
  }

  void updateMacOSBrightness(Brightness brightness) {
  }

  Future<void> show() async {
    globalState.handleForeground();
    render?.resume();
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setSkipTaskbar(false);
    await globalState.resumeForegroundUpdates();
    await globalState.appController.syncWakelockIfNeeded();
  }

  Future<bool> get isVisible async {
    return await windowManager.isVisible();
  }

  Future<bool> get isMinimized async {
    return await windowManager.isMinimized();
  }

  Future<void> close() async {
    try {
      await trayManager.destroy();
      commonPrint.log('The tray icon has been destroyed.');
    } catch (e) {
      commonPrint.log('Failed to destroy the tray icon: $e');
    }

    exit(0);
  }

  Future<void> hide() async {
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
    await globalState.handleBackground();
  }
}

final window = system.isDesktop ? Window() : null;