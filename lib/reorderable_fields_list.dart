import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Firma del constructor de campos que ya existe en tus diálogos
/// (`_buildField(label, ctrl)` y `_buildTextField(hint, ctrl)`).
typedef FieldBuilder = Widget Function(
    String label, TextEditingController controller);

/// Lista de "Campos Extra" con drag & drop de nivel profesional.
///
/// Mejoras sobre el `ReorderableListView` plano que había antes:
///  • Tirador (handle) con área de toque real, hover, cursor grab/grabbing.
///  • Feedback de elevación al arrastrar (sombra, halo de color, escala).
///  • El resto de filas se atenúan para que la fila arrastrada destaque.
///  • Auto-scroll del diálogo al arrastrar cerca del borde superior/inferior
///    (esto es lo que el ReorderableListView anidado NO hace por sí solo).
///  • Animación de entrada al añadir un campo nuevo.
///  • Índices ya normalizados en [onReorder]: no hay que restar 1.
class ReorderableFieldsList extends StatefulWidget {
  const ReorderableFieldsList({
    super.key,
    required this.keyControllers,
    required this.valueControllers,
    required this.fieldBuilder,
    required this.onReorder,
    required this.onRemove,
    this.parentScrollController,
    this.keyLabel = 'Propiedad',
    this.valueLabel = 'Valor',
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.controlsTopPadding = 0,
    this.accentColor = const Color(0xFF0A84FF),
    this.handleIconSize = 20,
    this.deleteIconSize = 20,
    this.fieldSpacing = 8,
    this.showIndexBadge = false,
    this.autoScrollEdgeSize = 0,
    this.autoScrollMaxStep = 5,
  });

  /// Controladores de la columna "Propiedad".
  final List<TextEditingController> keyControllers;

  /// Controladores de la columna "Valor".
  final List<TextEditingController> valueControllers;

  /// Reutiliza el builder de campos del diálogo para no romper el estilo.
  final FieldBuilder fieldBuilder;

  /// Índices YA normalizados (mueve `oldIndex` a `newIndex` directamente).
  final void Function(int oldIndex, int newIndex) onReorder;

  /// Eliminar la fila `index` (acuérdate de hacer `dispose()` allí).
  final void Function(int index) onRemove;

  /// Scroll del diálogo que contiene la lista. Necesario para el auto-scroll.
  final ScrollController? parentScrollController;

  final String keyLabel;
  final String valueLabel;
  final CrossAxisAlignment crossAxisAlignment;

  /// Desplazamiento vertical del handle y del botón borrar, para alinearlos
  /// con el campo cuando este lleva una etiqueta encima (usa ~26 en ese caso).
  final double controlsTopPadding;

  final Color accentColor;
  final double handleIconSize;
  final double deleteIconSize;
  final double fieldSpacing;
  final bool showIndexBadge;
  final double autoScrollEdgeSize;
  final double autoScrollMaxStep;

  @override
  State<ReorderableFieldsList> createState() => _ReorderableFieldsListState();
}

class _ReorderableFieldsListState extends State<ReorderableFieldsList> {
  int? _dragIndex;
  int? _hoverIndex;
  Timer? _autoScrollTimer;
  double? _pointerY;

  @override
  void dispose() {
    _stopAutoScroll();
    super.dispose();
  }

  // ---------------------------------------------------------------- drag ---

  void _handleDragStart(int index) {
    HapticFeedback.selectionClick();
    setState(() {
      _dragIndex = index;
      _hoverIndex = null;
    });
    _startAutoScroll();
  }

  void _handleDragEnd(int index) {
    HapticFeedback.selectionClick();
    _stopAutoScroll();
    if (mounted) setState(() => _dragIndex = null);
  }

  // ---------------------------------------------------------- auto-scroll ---

  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    if (widget.parentScrollController == null) return;
    _autoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScrollTick(),
    );
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _pointerY = null;
  }

  void _autoScrollTick() {
    final ScrollController? controller = widget.parentScrollController;
    final double? pointerY = _pointerY;
    if (!mounted ||
        _dragIndex == null ||
        pointerY == null ||
        controller == null ||
        !controller.hasClients) {
      return;
    }

    // Límites visibles del scroll del diálogo (no de la lista interna).
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    final RenderObject? render = scrollable?.context.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return;

    final double top = render.localToGlobal(Offset.zero).dy;
    final double bottom = top + render.size.height;
    final double edge = widget.autoScrollEdgeSize;

    double step = 0;
    if (pointerY < top + edge) {
      final double factor = ((top + edge - pointerY) / edge).clamp(0.0, 1.0);
      step = -widget.autoScrollMaxStep * factor;
    } else if (pointerY > bottom - edge) {
      final double factor =
          ((pointerY - (bottom - edge)) / edge).clamp(0.0, 1.0);
      step = widget.autoScrollMaxStep * factor;
    }
    if (step == 0) return;

    final ScrollPosition position = controller.position;
    final double target = (position.pixels + step)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() > 0.1) position.jumpTo(target);
  }

  // --------------------------------------------------------------- build ---

  @override
  Widget build(BuildContext context) {
    final int count = widget.keyControllers.length < widget.valueControllers.length
        ? widget.keyControllers.length
        : widget.valueControllers.length;
    if (count == 0) return const SizedBox.shrink();

    return Listener(
      onPointerDown: (event) => _pointerY = event.position.dy,
      onPointerMove: (event) => _pointerY = event.position.dy,
      onPointerUp: (_) => _stopAutoScroll(),
      onPointerCancel: (_) => _stopAutoScroll(),
      child: ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: count,
        onReorderStart: _handleDragStart,
        onReorderEnd: _handleDragEnd,
        proxyDecorator: _proxyDecorator,
        onReorder: (int oldIndex, int newIndex) {
          if (newIndex > oldIndex) newIndex -= 1;
          if (oldIndex == newIndex) return;
          widget.onReorder(oldIndex, newIndex);
        },
        itemBuilder: (context, index) => _buildRow(index),
      ),
    );
  }

  /// Aspecto de la fila mientras "vuela" sobre la lista.
  Widget _proxyDecorator(Widget child, int index, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final double t = Curves.easeOutCubic.transform(animation.value);
        return Transform.scale(
          scale: 1.0 + 0.025 * t,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              decoration: BoxDecoration(
                color: Color.lerp(
                    Colors.transparent, const Color(0xFF1B1B1E), 0.95 * t),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: widget.accentColor.withOpacity(0.55 * t),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.45 * t),
                    blurRadius: 26 * t,
                    offset: Offset(0, 10 * t),
                  ),
                  BoxShadow(
                    color: widget.accentColor.withOpacity(0.18 * t),
                    blurRadius: 24 * t,
                  ),
                ],
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }

  Widget _buildRow(int index) {
    final TextEditingController keyCtrl = widget.keyControllers[index];
    final TextEditingController valCtrl = widget.valueControllers[index];
    final bool isDragging = _dragIndex == index;
    final bool dimmed = _dragIndex != null && !isDragging;
    final bool hovered = _hoverIndex == index && _dragIndex == null;

    return _RowEntryAnimation(
      key: ObjectKey(keyCtrl),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: dimmed ? 0.45 : 1.0,
        child: MouseRegion(
          onEnter: (_) => _setHover(index),
          onExit: (_) => _setHover(null),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            decoration: BoxDecoration(
              color: hovered
                  ? Colors.white.withOpacity(0.035)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: widget.crossAxisAlignment,
              children: [
                _buildHandle(index, isDragging, hovered),
                if (widget.showIndexBadge) _buildIndexBadge(index, isDragging),
                Expanded(child: widget.fieldBuilder(widget.keyLabel, keyCtrl)),
                SizedBox(width: widget.fieldSpacing),
                Expanded(child: widget.fieldBuilder(widget.valueLabel, valCtrl)),
                _buildDeleteButton(index),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _setHover(int? index) {
    if (_hoverIndex == index) return;
    setState(() => _hoverIndex = index);
  }

  Widget _buildHandle(int index, bool isDragging, bool hovered) {
    return Padding(
      padding: EdgeInsets.only(top: widget.controlsTopPadding, right: 4),
      child: ReorderableDragStartListener(
        index: index,
        child: MouseRegion(
          cursor: isDragging
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.grab,
          // OJO: aquí NO puede haber un Tooltip. Al empezar el arrastre la fila
          // se reconstruye dentro del Overlay y el Tooltip intenta medir un
          // RenderBox sin layout -> assert en RenderBox.size.
          child: Semantics(
            label: 'Arrastra para reordenar el campo',
            button: true,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 26,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isDragging
                    ? widget.accentColor.withOpacity(0.20)
                    : hovered
                        ? Colors.white.withOpacity(0.08)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(
                Icons.drag_indicator,
                size: widget.handleIconSize,
                color: isDragging
                    ? widget.accentColor
                    : hovered
                        ? Colors.white70
                        : Colors.white38,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIndexBadge(int index, bool isDragging) {
    return Padding(
      padding: EdgeInsets.only(top: widget.controlsTopPadding, right: 8),
      child: Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isDragging
              ? widget.accentColor.withOpacity(0.25)
              : Colors.white.withOpacity(0.06),
          shape: BoxShape.circle,
        ),
        child: Text(
          '${index + 1}',
          style: TextStyle(
            fontSize: 10,
            color: isDragging ? widget.accentColor : Colors.white54,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildDeleteButton(int index) {
    return Padding(
      padding: EdgeInsets.only(top: widget.controlsTopPadding, left: 2),
      child: SizedBox(
        width: 32,
        height: 32,
        child: Semantics(
          label: 'Eliminar campo',
          button: true,
          child: IconButton(
            padding: EdgeInsets.zero,
            splashRadius: 16,
            // Sin `tooltip:` por el mismo motivo que el handle: el IconButton
            // envuelve su icono en un Tooltip y revienta al arrastrar la fila.
            icon: Icon(Icons.remove_circle,
                color: Colors.redAccent, size: widget.deleteIconSize),
            onPressed: () => widget.onRemove(index),
          ),
        ),
      ),
    );
  }
}

/// Aparición suave de una fila recién añadida (solo la primera vez que se
/// monta; al reordenar se conserva el estado gracias a la `ObjectKey`).
class _RowEntryAnimation extends StatefulWidget {
  const _RowEntryAnimation({super.key, required this.child});

  final Widget child;

  @override
  State<_RowEntryAnimation> createState() => _RowEntryAnimationState();
}

class _RowEntryAnimationState extends State<_RowEntryAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  late final Animation<double> _curve =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: SizeTransition(
        sizeFactor: _curve,
        axisAlignment: -1,
        child: widget.child,
      ),
    );
  }
}