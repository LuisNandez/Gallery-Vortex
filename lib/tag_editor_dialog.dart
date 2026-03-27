import 'dart:ui'; // Necesario para el efecto Blur
import 'package:flutter/material.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'metadata_service.dart'; 

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
                TypeAheadField<String>(
                  controller: _typeAheadController,
                  emptyBuilder: (context) => const SizedBox.shrink(),
                  suggestionsCallback: (pattern) {
                    final allTags = widget.metadataService.getAllTags();
                    if (pattern.isEmpty) return [];
                    return allTags
                        .where((tag) => tag.toLowerCase().contains(pattern.toLowerCase()))
                        .toList();
                  },
                  itemBuilder: (context, suggestion) {
                    return ListTile(title: Text(suggestion, style: const TextStyle(color: Colors.white)));
                  },
                  onSelected: (suggestion) => _addTag(suggestion),
                  builder: (context, controller, focusNode) {
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: true,
                      onSubmitted: _addTag,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFF1C1C1E).withOpacity(0.8), // Fondo oscuro insertado
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