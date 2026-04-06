import 'dart:ui'; // Necesario para el efecto Blur
import 'package:flutter/material.dart';
import 'metadata_service.dart'; 
import 'package:flutter/rendering.dart';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'ui_utils.dart';

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
  
  // NUEVO 1: Portapapeles estático de la app.
  // Al ser 'static', recuerda las etiquetas copiadas entre diferentes diálogos
  // pero ignora completamente el portapapeles de Windows/Mac.
  static List<String> _appCopiedTags = [];
  
  String? _clipboardPreview;

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
    
    // Al abrir el diálogo, leemos nuestro portapapeles interno
    _checkClipboardStatus();
  }

  // NUEVO 2: Función que formatea las primeras 8 etiquetas
  void _checkClipboardStatus() {
    if (_appCopiedTags.isNotEmpty) {
      // Tomamos solo las primeras 8
      final displayTags = _appCopiedTags.take(8).toList();
      String preview = displayTags.join(', ');
      
      // Si había más de 8, agregamos el indicador
      if (_appCopiedTags.length > 8) {
        final extras = _appCopiedTags.length - 8;
        preview += '... (+$extras)';
      }
      
      if (mounted) {
        setState(() {
          _clipboardPreview = preview;
        });
      }
    } else {
      if (mounted) setState(() => _clipboardPreview = null);
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      
      final RenderBox? renderBox = _dialogKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null) return;

      final screenSize = MediaQuery.of(context).size;
      final currentHeight = renderBox.size.height;
      const double dialogWidth = 340.0;

      final double dynamicMaxX = math.max(0.0, (screenSize.width - dialogWidth) / 2);
      final double dynamicMaxY = math.max(0.0, (screenSize.height - currentHeight) / 2);

      double fixedDx = _dialogPosition.dx.clamp(-dynamicMaxX, dynamicMaxX);
      double fixedDy = _dialogPosition.dy.clamp(-dynamicMaxY, dynamicMaxY);

      if (fixedDx != _dialogPosition.dx || fixedDy != _dialogPosition.dy) {
        setState(() {
          _dialogPosition = Offset(fixedDx, fixedDy);
        });
      }
    });
  }

  // NUEVO 3: Actualizamos la función de copiar
  Future<void> _copyTags() async {
    if (_currentTags.isEmpty) return;
    
    _appCopiedTags = _currentTags.toList();
    final tagsString = _currentTags.join(', ');
    await Clipboard.setData(ClipboardData(text: tagsString));
    
    _checkClipboardStatus();
    
    if (mounted) {
      // INVOCAMOS LA UTILIDAD GLOBAL
      showGlassSnackBar(context, 'Etiquetas copiadas', icon: Icons.copy);
    }
  }
  // NUEVO 4: Actualizamos la función de pegar para que use la memoria interna
  void _pasteTags() {
    if (_appCopiedTags.isNotEmpty) {
      for (final tag in _appCopiedTags) {
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
    final screenSize = MediaQuery.of(context).size;
    const double dialogWidth = 340.0; 
    if (_lastScreenSize != null && _lastScreenSize != screenSize) {
      _ensureWithinBounds(); 
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
              width: dialogWidth, 
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
                  MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: GestureDetector(
                      onPanUpdate: (details) {
                        setState(() {
                          final RenderBox? renderBox = _dialogKey.currentContext?.findRenderObject() as RenderBox?;
                          final currentHeight = renderBox?.size.height ?? 400.0; 
                          final double dynamicMaxX = math.max(0.0, (screenSize.width - dialogWidth) / 2);
                          final double dynamicMaxY = math.max(0.0, (screenSize.height - currentHeight) / 2);
                          double newDx = _dialogPosition.dx + details.delta.dx;
                          double newDy = _dialogPosition.dy + details.delta.dy;
                          newDx = newDx.clamp(-dynamicMaxX, dynamicMaxX);
                          newDy = newDy.clamp(-dynamicMaxY, dynamicMaxY);
                          _dialogPosition = Offset(newDx, newDy);
                        });
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.only(top: 20, bottom: 10), 
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
                              // Si hay etiquetas actuales, brilla. Si no, se apaga.
                              color: _currentTags.isNotEmpty ? Colors.white : Colors.white24,
                              tooltip: 'Copiar etiquetas',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              // Desactiva el clic si no hay etiquetas
                              onPressed: _currentTags.isEmpty ? null : _copyTags, 
                            ),
                            const SizedBox(width: 16),
                            
                            // NUEVO 5: Botón Pegar reactivo a nuestra variable estática
                            IconButton(
                              icon: const Icon(Icons.paste, size: 18),
                              color: _clipboardPreview != null ? Colors.white : Colors.white24,
                              tooltip: _clipboardPreview != null 
                                  ? 'Pegar: $_clipboardPreview' 
                                  : 'Portapapeles vacío',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: _clipboardPreview != null ? _pasteTags : null,
                            ),
                            const SizedBox(width: 4), 
                          ],
                        ),
                      ),
                    ),
                  ),
                
                  RawAutocomplete<String>(
                    textEditingController: _typeAheadController,
                    focusNode: _focusNode,
                    optionsBuilder: (TextEditingValue textEditingValue) {
                      final pattern = textEditingValue.text.trim().toLowerCase();
                      if (pattern.isEmpty) return const Iterable<String>.empty();
                      
                      final allTags = widget.metadataService.getAllTags();
                      
                      // 1. Filtramos las etiquetas que coinciden con la búsqueda (contienen el texto)
                      final filteredTags = allTags
                          .where((tag) => tag.toLowerCase().contains(pattern))
                          .toList();
                          
                      // 2. Ordenamiento inteligente (Ponderado + Alfabético)
                      filteredTags.sort((a, b) {
                        final aLower = a.toLowerCase();
                        final bLower = b.toLowerCase();
                        
                        final aStarts = aLower.startsWith(pattern);
                        final bStarts = bLower.startsWith(pattern);
                        
                        // Si 'a' empieza con el texto y 'b' no, 'a' va primero
                        if (aStarts && !bStarts) {
                          return -1;
                        } 
                        // Si 'b' empieza con el texto y 'a' no, 'b' va primero
                        else if (!aStarts && bStarts) {
                          return 1;
                        } 
                        // Si ambas empiezan con el texto, o ninguna empieza con el texto, orden alfabético normal
                        else {
                          return aLower.compareTo(bLower);
                        }
                      });
                      
                      return filteredTags;
                    },
                    onSelected: (String suggestion) {
                      _addTag(suggestion);
                      Future.microtask(() {
                        _typeAheadController.clear();
                      });
                      _focusNode.requestFocus(); 
                    },
                    fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        autofocus: true,
                        onSubmitted: (value) {
                          onFieldSubmitted(); 
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
                          width: 300, 
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
                  
                  Flexible(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(), 
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8.0), 
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
                  
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(foregroundColor: const Color(0xFF0A84FF)), 
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