import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Обёртка карточки ноды: включает перетаскивание долгим нажатием.
///
/// Порядок применяется в момент drop: при наведении подсвечивается цель,
/// после отпускания вызывается [ProxyDragTile.onReorder] (откуда, куда) и
/// список перестраивается. Вне режима ручной сортировки ([enabled] == false)
/// ведёт себя как обычная карточка.
///
/// [ProxyDragTile.onHoldNoMove]: «удержание без движения» — drag стартует по
/// долгому нажатию, но если палец отпущен на месте (в пределах дрожания
/// руки), это трактуется как долгое нажатие на карточку, а не как
/// перетаскивание. Так в режиме ручной сортировки уживаются drag (удержал
/// и повёл) и удаление ноды (удержал и отпустил).
///
/// Движение пальца отслеживается ТОЛЬКО по глобальным координатам
/// (Listener.onPointerDown/Move + DragUpdateDetails.globalPosition).
/// Полагаться на offsets из onDragEnd/onDraggableCanceled нельзя: это
/// позиция левого верхнего угла аватара (globalPosition минус якорь
/// childDragAnchorStrategy), а не точка пальца — сравнение с точкой
/// нажатия давало дистанцию в десятки пикселей и «удержание на месте»
/// никогда не распознавалось.
class ProxyDragTile extends StatefulWidget {
  final String proxyName;
  final Widget child;
  final bool enabled;
  final void Function(String fromName, String toName)? onReorder;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onHoldNoMove;

  const ProxyDragTile({
    super.key,
    required this.proxyName,
    required this.child,
    this.enabled = false,
    this.onReorder,
    this.onDragStart,
    this.onDragEnd,
    this.onDragUpdate,
    this.onHoldNoMove,
  });

  @override
  State<ProxyDragTile> createState() => _ProxyDragTileState();
}

class _ProxyDragTileState extends State<ProxyDragTile> {
  /// Порог «палец не двигался»: отпускание ближе этого расстояния от точки
  /// нажатия считается удержанием на месте (жест удаления), а не переносом.
  static const double _holdSlop = 12.0;

  /// Глобальная точка первого касания (Listener.onPointerDown).
  Offset? _downPosition;

  /// Палец ушёл дальше [_holdSlop] от точки касания — это уже перенос,
  /// а не «удержание на месте».
  bool _movedFar = false;

  /// Защита от двойного срабатывания: при отмене drag'а флаттер вызывает
  /// и onDragEnd, и onDraggableCanceled — обрабатываем только первый из них.
  bool _holdHandled = true;

  void _handlePointerDown(PointerDownEvent event) {
    _downPosition = event.position;
    _movedFar = false;
    _holdHandled = false;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _trackMovement(event.position);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    // Системная отмена (входящий звонок, переключение приложения и т.п.) —
    // не жест удаления.
    _holdHandled = true;
  }

  void _trackMovement(Offset globalPosition) {
    final down = _downPosition;
    if (down == null || _movedFar) {
      return;
    }
    if ((globalPosition - down).distance > _holdSlop) {
      _movedFar = true;
    }
  }

  void _handleDragFinished() {
    widget.onDragEnd?.call();
    if (_holdHandled) {
      return;
    }
    _holdHandled = true;
    final onHoldNoMove = widget.onHoldNoMove;
    if (onHoldNoMove == null) {
      return;
    }
    // Сюда offset'ы из onDragEnd/onDraggableCanceled НЕ передаются — см.
    // комментарий к классу: это угол аватара, а не точка пальца.
    if (!_movedFar) {
      onHoldNoMove();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded =
            constraints.hasBoundedWidth && constraints.hasBoundedHeight;
        final tileSize = bounded
            ? Size(constraints.maxWidth, constraints.maxHeight)
            : null;
        return DragTarget<String>(
          onWillAcceptWithDetails: (details) =>
              details.data != widget.proxyName,
          onAcceptWithDetails: (details) =>
              widget.onReorder?.call(details.data, widget.proxyName),
          builder: (context, candidateData, rejectedData) {
            final isHovered = candidateData.isNotEmpty;
            final tile = isHovered
                ? Stack(
                    children: [
                      widget.child,
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
                : widget.child;
            Widget wrap(Widget w) {
              if (tileSize == null) return w;
              return SizedBox.fromSize(size: tileSize, child: w);
            }

            return LongPressDraggable<String>(
              data: widget.proxyName,
              maxSimultaneousDrags: 1,
              dragAnchorStrategy: childDragAnchorStrategy,
              onDragStarted: widget.onDragStart,
              onDragUpdate: (details) {
                _trackMovement(details.globalPosition);
                widget.onDragUpdate?.call(details.globalPosition);
              },
              onDragEnd: (details) => _handleDragFinished(),
              onDraggableCanceled: (_, __) => _handleDragFinished(),
              feedback: wrap(
                Material(
                  color: Colors.transparent,
                  child: _DragFeedbackShadow(
                    child: Opacity(opacity: 0.95, child: widget.child),
                  ),
                ),
              ),
              childWhenDragging: wrap(
                Opacity(opacity: 0.45, child: widget.child),
              ),
              child: Listener(
                onPointerDown: _handlePointerDown,
                onPointerMove: _handlePointerMove,
                onPointerCancel: _handlePointerCancel,
                child: wrap(tile),
              ),
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
