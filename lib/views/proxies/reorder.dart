import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:flutter/material.dart';

/// Обёртка карточки ноды: включает перетаскивание долгим нажатием.
///
/// Порядок применяется в момент drop: при наведении подсвечивается цель,
/// после отпускания вызывается [onReorder] (откуда, куда) и список
/// перестраивается. Вне режима ручной сортировки ([enabled] == false)
/// ведёт себя как обычная карточка.
class ProxyDragTile extends StatelessWidget {
  final String proxyName;
  final Widget child;
  final bool enabled;
  final void Function(String fromName, String toName)? onReorder;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;
  final ValueChanged<Offset>? onDragUpdate;

  const ProxyDragTile({
    super.key,
    required this.proxyName,
    required this.child,
    this.enabled = false,
    this.onReorder,
    this.onDragStart,
    this.onDragEnd,
    this.onDragUpdate,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return child;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded =
            constraints.hasBoundedWidth && constraints.hasBoundedHeight;
        final tileSize = bounded
            ? Size(constraints.maxWidth, constraints.maxHeight)
            : null;
        return DragTarget<String>(
          onWillAcceptWithDetails: (details) => details.data != proxyName,
          onAcceptWithDetails: (details) =>
              onReorder?.call(details.data, proxyName),
          builder: (context, candidateData, rejectedData) {
            final isHovered = candidateData.isNotEmpty;
            final tile = isHovered
                ? Stack(
                    children: [
                      child,
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            margin: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: context.colorScheme.primary,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : child;
            Widget wrap(Widget widget) {
              if (tileSize == null) return widget;
              return SizedBox.fromSize(size: tileSize, child: widget);
            }

            return LongPressDraggable<String>(
              data: proxyName,
              maxSimultaneousDrags: 1,
              dragAnchorStrategy: childDragAnchorStrategy,
              onDragStarted: onDragStart,
              onDragUpdate: (details) =>
                  onDragUpdate?.call(details.globalPosition),
              onDragEnd: (_) => onDragEnd?.call(),
              onDraggableCanceled: (_, _) => onDragEnd?.call(),
              feedback: wrap(
                Material(
                  color: Colors.transparent,
                  child: _DragFeedbackShadow(
                    child: Opacity(opacity: 0.95, child: child),
                  ),
                ),
              ),
              childWhenDragging: wrap(Opacity(opacity: 0.45, child: child)),
              child: wrap(tile),
            );
          },
        );
      },
    );
  }
}

class _DragFeedbackShadow extends StatelessWidget {
  final Widget child;

  const _DragFeedbackShadow({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 12,
            spreadRadius: 2,
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Автопрокрутка при перетаскивании: пока идёт drag и курсор находится
/// у верхней/нижней кромки вьюпорта — плавно прокручивает список.
class DragAutoScroller {
  DragAutoScroller({
    required ScrollController scrollController,
    required GlobalKey viewportKey,
  }) : _scrollController = scrollController,
       _viewportKey = viewportKey;

  final ScrollController _scrollController;
  final GlobalKey _viewportKey;
  Timer? _timer;
  Offset? _pointerPosition;

  void start() {
    _timer ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
  }

  void update(Offset globalPosition) {
    _pointerPosition = globalPosition;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _pointerPosition = null;
  }

  void dispose() {
    stop();
  }

  void _tick() {
    final pointer = _pointerPosition;
    if (pointer == null) {
      return;
    }
    final context = _viewportKey.currentContext;
    if (context == null) {
      return;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return;
    }
    final controller = _scrollController;
    if (!controller.hasClients) {
      return;
    }
    final position = controller.position;
    final local = renderObject.globalToLocal(pointer);
    const edge = 64.0;
    const maxStep = 14.0;
    final bottomEdge = renderObject.size.height - edge;
    double? target;
    if (local.dy < edge && position.pixels > 0) {
      final intensity = ((edge - local.dy) / edge).clamp(0.0, 1.0);
      target = (position.pixels - maxStep * intensity).clamp(
        0.0,
        position.maxScrollExtent,
      );
    } else if (local.dy > bottomEdge &&
        position.pixels < position.maxScrollExtent) {
      final intensity = ((local.dy - bottomEdge) / edge).clamp(0.0, 1.0);
      target = (position.pixels + maxStep * intensity).clamp(
        0.0,
        position.maxScrollExtent,
      );
    }
    if (target != null) {
      controller.jumpTo(target);
    }
  }
}
