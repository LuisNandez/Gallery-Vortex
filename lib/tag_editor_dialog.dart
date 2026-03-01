import 'package:flutter/material.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'metadata_service.dart'; // Asegúrate de que importa el servicio correcto

class TagEditorDialog extends StatefulWidget {
  final List<String> imageIds;
  final MetadataService metadataService; // Usa el servicio de metadatos

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
    // Si solo hay una imagen, mostramos sus etiquetas.
    // Si hay varias, mostramos solo las etiquetas que tienen en COMÚN.
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
    return AlertDialog(
      title: Text('Etiquetas para ${widget.imageIds.length} imagen(es)'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Campo de texto con autocompletado ---
            TypeAheadField<String>(
              controller: _typeAheadController,
              suggestionsCallback: (pattern) {
                final allTags = widget.metadataService.getAllTags();
                if (pattern.isEmpty) {
                  return [];
                }
                return allTags
                    .where((tag) => tag.toLowerCase().contains(pattern.toLowerCase()))
                    .toList();
              },
              itemBuilder: (context, suggestion) {
                return ListTile(title: Text(suggestion));
              },
              onSelected: (suggestion) {
                _addTag(suggestion);
              },
              builder: (context, controller, focusNode) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: true,
                  onSubmitted: _addTag,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Añadir etiqueta',
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            // --- Lista de etiquetas actuales (Chips) ---
            if (_currentTags.isEmpty)
              const Text('No hay etiquetas asignadas.')
            else
              Wrap(
                spacing: 8.0,
                runSpacing: 4.0,
                children: _currentTags.map((tag) {
                  return Chip(
                    label: Text(tag),
                    onDeleted: () => _removeTag(tag),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}