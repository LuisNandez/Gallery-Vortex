import 'dart:ui'; // Necesario para el efecto Blur
import 'package:flutter/material.dart';
import 'metadata_service.dart'; 
import 'package:flutter/rendering.dart';
import 'dart:math' as math;
import 'package:flutter/services.dart';

class TagEditorDialog extends StatefulWidget {
  final List<String> imageIds;
  final MetadataService metadataService;

  const TagEditorDialog({
    super.key,
    required this.imageIds,
    required this.metadataService,
  });

  @override
  State<TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<TagEditorDialog> {
  late Set<String> _currentTags;
  final TextEditingController _typeAheadController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Offset _dialogPosition = Offset.zero;
  final GlobalKey _dialogKey = GlobalKey();
  Size? _lastScreenSize;

  @override
  void dispose() {
    _typeAheadController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.imageIds.length == 1) {
      _currentTags = widget.metadataService.getMetadataForImage(widget.imageIds.first).tags.toSet();
    } else {
      final allTagsLists = widget.imageIds
          .map((id) => widget.metadataService.getMetadataForImage(id).tags.toSet());
      _currentTags = allTagsLists.reduce((a, b) => a.intersection(b));
    }
  }

  void _addTag(String tag) {
    final cleanTag = tag.trim().toLowerCase();
    if (cleanTag.isEmpty || _currentTags.contains(cleanTag)) {
      _typeAheadController.clear();
      return;
    }

    setState(() {
      _currentTags.add(cleanTag);
    });

    for (final imageId in widget.imageIds) {
      widget.metadataService.addTagToImage(imageId, cleanTag);
    }
    _typeAheadController.clear();
    _ensureWithinBounds();
  }

  void _ensureWithinBounds() {
    // Le pedimos a Flutter que espere a terminar de dibujar la nueva etiqueta
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      
      final RenderBox? renderBox = _dialogKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null) return;

      final screenSize = MediaQuery.of(context).size;
      final currentHeight = renderBox.size.height;
      const double dialogWidth = 340.0;

      // Calculamos las paredes actuales y evitamos valores negativos con math.max
      final double dynamicMaxX = math.max(0.0, (screenSize.width - dialogWidth) / 2);
      final double dynamicMaxY = math.max(0.0, (screenSize.height - currentHeight) / 2);

      // Verificamos si la posición actual se salió de estas nuevas paredes
      double fixedDx = _dialogPosition.dx.clamp(-dynamicMaxX, dynamicMaxX);
      double fixedDy = _dialogPosition.dy.clamp(-dynamicMaxY, dynamicMaxY);

      // Si se salió, actualizamos la posición para "empujarla" adentro
      if (fixedDx != _dialogPosition.dx || fixedDy != _dialogPosition.dy) {
        setState(() {
          _dialogPosition = Offset(fixedDx, fixedDy);
        });
      }
    });
  }

  // --- NUEVO: FUNCIONES DE PORTAPAPELES ---
  Future<void> _copyTags() async {
    if (_currentTags.isEmpty) return;
    
    // Convertimos la lista de etiquetas a texto: "paisaje, atardecer, playa"
    final tagsString = _currentTags.join(', ');
    await Clipboard.setData(ClipboardData(text: tagsString));
    
    if (mounted) {
      // Mostramos un pequeño aviso flotante
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Etiquetas copiadas', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
          backgroundColor: const Color(0xFF3A3A3C),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _pasteTags() async {
    // Obtenemos el texto del portapapeles
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null) {
      // Separamos por comas, limpiamos espacios vacíos y filtramos
      final pastedTags = data.text!
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty);
          
      // Usamos tu función existente _addTag para agregar cada una con toda su lógica
      for (final tag in pastedTags) {
        _addTag(tag); 
      }
    }
  }

  void _removeTag(String tag) {
    setState(() {
      _currentTags.remove(tag);
    });
    for (final imageId in widget.imageIds) {
      widget.metadataService.removeTagFromImage(imageId, tag);
    }
    _ensureWithinBounds();
  }

  @override
  Widget build(BuildContext context) {
    // 1. Obtenemos el tamaño de la pantalla
    final screenSize = MediaQuery.of(context).size;
    
    // 2. Definimos las nuevas dimensiones (más pequeñas)
    const double dialogWidth = 340.0; 
    if (_lastScreenSize != null && _lastScreenSize != screenSize) {
      _ensureWithinBounds(); // Forzamos a que se meta a la ventana
    }
    _lastScreenSize = screenSize;

    return Transform.translate(
      offset: _dialogPosition,
      child: Dialog(
        backgroundColor: Colors.transparent, 
        elevation: 0, 
        insetPadding: const EdgeInsets.all(20),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12.0),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15), 
            child: Container(
              key: _dialogKey,
              width: dialogWidth, // Usamos la variable más pequeña
              constraints: BoxConstraints(
                maxHeight: math.max(200.0, screenSize.height - 40.0),
              ),

              padding: const EdgeInsets.only(left: 20, right: 20, bottom: 20, top: 0),
              decoration: BoxDecoration(
                color: const Color(0xFF252525).withOpacity(0.65), 
                border: Border.all(color: Colors.white12, width: 0.5), 
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  
                  // --- CABECERA ARRASTRABLE CON PAREDES ---
                  MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: GestureDetector(
                      onPanUpdate: (details) {
                        setState(() {
                          // 3. MEDIMOS EL TAMAÑO REAL EN ESTE INSTANTE
                          final RenderBox? renderBox = _dialogKey.currentContext?.findRenderObject() as RenderBox?;
                          // Si por alguna razón no puede medirlo, usa 400.0 como salvavidas
                          final currentHeight = renderBox?.size.height ?? 400.0; 

                          // 4. CALCULAMOS LAS PAREDES DINÁMICAS (Protegidas)
                          final double dynamicMaxX = math.max(0.0, (screenSize.width - dialogWidth) / 2);
                          final double dynamicMaxY = math.max(0.0, (screenSize.height - currentHeight) / 2);

                          // 5. Calculamos el nuevo movimiento
                          double newDx = _dialogPosition.dx + details.delta.dx;
                          double newDy = _dialogPosition.dy + details.delta.dy;

                          // 6. Aplicamos el choque (clamp) contra las paredes frescas
                          newDx = newDx.clamp(-dynamicMaxX, dynamicMaxX);
                          newDy = newDy.clamp(-dynamicMaxY, dynamicMaxY);

                          _dialogPosition = Offset(newDx, newDy);
                        });
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.only(top: 20, bottom: 10), // Más compacto
                        color: Colors.transparent, 
                        child: Row(
                          children: [
                            const Icon(Icons.drag_indicator, color: Colors.white54, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                widget.imageIds.length == 1 
                                    ? 'Etiquetas del archivo' 
                                    : 'Etiquetas para (${widget.imageIds.length}) archivos',
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 18),
                              color: Colors.white54,
                              disabledColor: Colors.white24,
                              tooltip: 'Copiar etiquetas',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(), // Quita el padding gigante por defecto
                              onPressed: _currentTags.isEmpty ? null : _copyTags, // Se desactiva si no hay etiquetas
                            ),
                            const SizedBox(width: 16),
                            IconButton(
                              icon: const Icon(Icons.paste, size: 18),
                              color: Colors.white54,
                              tooltip: 'Pegar etiquetas',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: _pasteTags,
                            ),
                            const SizedBox(width: 4), // Margen final
                          ],
                        ),
                      ),
                    ),
                  ),
                
                // --- Campo de texto estilo Buscador Mac ---
                RawAutocomplete<String>(
                  textEditingController: _typeAheadController,
                  focusNode: _focusNode,
                  optionsBuilder: (TextEditingValue textEditingValue) {
                    final pattern = textEditingValue.text.trim().toLowerCase();
                    if (pattern.isEmpty) return const Iterable<String>.empty();
                    
                    final allTags = widget.metadataService.getAllTags();
                    return allTags.where((tag) => tag.toLowerCase().contains(pattern));
                  },
                  onSelected: (String suggestion) {
                    _addTag(suggestion);
                    _focusNode.requestFocus(); // Mantiene el cursor tras elegir con Enter
                  },
                  fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: true,
                      onSubmitted: (value) {
                        // 1. Avisamos al Autocomplete que intente seleccionar la opción resaltada
                        onFieldSubmitted(); 
                        
                        // 2. Si no había ninguna opción resaltada, el texto se mantiene. 
                        // Lo procesamos como una etiqueta nueva.
                        Future.microtask(() {
                          if (controller.text.isNotEmpty) {
                            _addTag(controller.text);
                            focusNode.requestFocus();
                          }
                        });
                      },
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFF1C1C1E).withOpacity(0.8), 
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        hintText: 'Añadir etiqueta...',
                        hintStyle: const TextStyle(color: Colors.white54),
                      ),
                    );
                  },
                  optionsViewBuilder: (context, onSelected, options) {
                    return Align(
                      alignment: Alignment.topLeft,
                      child: Container(
                        width: 300, // Ancho del menú de sugerencias
                        margin: const EdgeInsets.only(top: 8),
                        child: Material(
                          color: const Color(0xFF252525), 
                          elevation: 8,
                          shadowColor: Colors.black.withOpacity(0.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: Colors.white12, width: 0.5),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 200),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: options.length,
                              itemBuilder: (context, index) {
                                final option = options.elementAt(index);
                                
                                return Builder(
                                  builder: (BuildContext context) {
                                    final bool isHighlighted = AutocompleteHighlightedOption.of(context) == index;
                                    
                                    // 3. Envolvemos el elemento en el Vigía de Scroll
                                    return _ScrollToVisible(
                                      isHighlighted: isHighlighted,
                                      child: InkWell(
                                        onTap: () => onSelected(option),
                                        hoverColor: Colors.white.withOpacity(0.08), 
                                        child: Container(
                                          color: isHighlighted 
                                              ? const Color(0xFF0A84FF).withOpacity(0.3) 
                                              : null,
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                          child: Text(option, style: const TextStyle(color: Colors.white)),
                                        ),
                                      ),
                                    );
                                  }
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                
                // --- Lista de etiquetas actuales (Chips estilo píldora) ---
                Flexible(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(), 
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8.0), // Pequeño respiro al final del scroll
                        child: _currentTags.isEmpty
                          ? const Text('No hay etiquetas asignadas.', style: TextStyle(color: Colors.white54))
                          : Wrap(
                              spacing: 8.0,
                              runSpacing: 8.0,
                              children: _currentTags.map((tag) {
                                return Chip(
                                  label: Text(tag, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white)),
                                  backgroundColor: const Color(0xFF3A3A3C).withOpacity(0.8),
                                  side: BorderSide.none,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                                  deleteIcon: const Icon(Icons.cancel, size: 16, color: Colors.white54),
                                  onDeleted: () => _removeTag(tag),
                                );
                              }).toList(),
                            ),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                
                // --- Botón de Cerrar estilo Cupertino ---
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFF0A84FF)), // Azul Mac
                    child: const Text('Cerrar', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      )
    );
  }
}

class _ScrollToVisible extends StatefulWidget {
  final bool isHighlighted;
  final Widget child;

  const _ScrollToVisible({required this.isHighlighted, required this.child});

  @override
  State<_ScrollToVisible> createState() => _ScrollToVisibleState();
}

class _ScrollToVisibleState extends State<_ScrollToVisible> {
  @override
  void didUpdateWidget(covariant _ScrollToVisible oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isHighlighted && !oldWidget.isHighlighted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;

        final renderObject = context.findRenderObject();
        final viewport = RenderAbstractViewport.of(renderObject);
        final scrollableState = Scrollable.of(context);

        if (renderObject != null && viewport != null && scrollableState != null) {
          final position = scrollableState.position;

          // Obtenemos los offsets matemáticos: 
          // itemTop = El nivel de scroll exacto para que la opción toque el techo
          // itemBottom = El nivel de scroll exacto para que la opción toque el suelo
          final itemTop = viewport.getOffsetToReveal(renderObject, 0.0).offset;
          final itemBottom = viewport.getOffsetToReveal(renderObject, 1.0).offset;

          // Si el scroll actual está por encima del ítem (el ítem está oculto arriba)
          if (position.pixels > itemTop) {
            position.jumpTo(itemTop);
          } 
          // Si el scroll actual está por debajo del ítem (el ítem está oculto abajo)
          else if (position.pixels < itemBottom) {
            position.jumpTo(itemBottom);
          }
          // Si no se cumple ninguna, significa que el ítem YA es visible, ¡así que no hacemos nada!
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}