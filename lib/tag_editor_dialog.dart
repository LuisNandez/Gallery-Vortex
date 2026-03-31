import 'dart:ui'; // Necesario para el efecto Blur
import 'package:flutter/material.dart';
import 'metadata_service.dart'; 
import 'package:flutter/rendering.dart';

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
  }

  void _removeTag(String tag) {
    setState(() {
      _currentTags.remove(tag);
    });
    for (final imageId in widget.imageIds) {
      widget.metadataService.removeTagFromImage(imageId, tag);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent, // Hacemos el fondo nativo invisible
      elevation: 0, // Quitamos las sombras nativas
      insetPadding: const EdgeInsets.all(20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12.0),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15), // EFECTO CRISTAL
          child: Container(
            width: 400, // Ancho fijo estilo panel de Mac
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF252525).withOpacity(0.65), // Translúcido
              border: Border.all(color: Colors.white12, width: 0.5), // Borde súper fino
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Etiquetas para ${widget.imageIds.length} imagen(es)',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)
                ),
                const SizedBox(height: 16),
                
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
                        width: 352, 
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
                const SizedBox(height: 20),
                
                // --- Lista de etiquetas actuales (Chips estilo píldora) ---
                if (_currentTags.isEmpty)
                  const Text('No hay etiquetas asignadas.', style: TextStyle(color: Colors.white54))
                else
                  Wrap(
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