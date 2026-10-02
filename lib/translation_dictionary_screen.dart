// translation_dictionary_screen.dart
//
// Pantalla de Ajustes para gestionar el diccionario de traducción al
// español que usa el etiquetado automático WD14 (ver wd14_tagger_service.dart).
// Muestra tres tipos de entradas, todas en una sola lista:
//   - "Base": el diccionario curado incorporado en el código de la app
//     (no se puede borrar, pero sí "editar" — eso crea una entrada
//     personalizada que la sustituye).
//   - "Personalizada": una traducción aprendida automáticamente por el
//     compositor genérico, o añadida/corregida a mano.
//   - "Pendiente": una etiqueta que la IA generó pero que no se pudo
//     traducir de ninguna forma; está a la espera de que el usuario le
//     asigne una traducción.
// Al editar una entrada, la traducción anterior se reemplaza también en
// todas las imágenes de la bóveda que ya la tuvieran asignada.
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';

import 'metadata_service.dart';
import 'ui_utils.dart';
import 'wd14_tagger_service.dart';

enum _DictOrigin { builtIn, custom, pending }

class _DictRow {
  final String enTag;
  final String esTranslation; // vacío solo si origin == pending
  final _DictOrigin origin;
  _DictRow(this.enTag, this.esTranslation, this.origin);

  // Texto de búsqueda normalizado, calculado una sola vez por fila (antes se
  // normalizaban ambos textos de las miles de filas en cada tecla).
  late final String searchKey = '${normalizeForSearch(enTag)}\n${normalizeForSearch(esTranslation)}';
}

class TranslationDictionaryScreen extends StatefulWidget {
  final MetadataService metadataService;

  const TranslationDictionaryScreen({super.key, required this.metadataService});

  @override
  State<TranslationDictionaryScreen> createState() => _TranslationDictionaryScreenState();
}

class _TranslationDictionaryScreenState extends State<TranslationDictionaryScreen> {
  final Wd14TaggerService _service = Wd14TaggerService.instance;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _enController = TextEditingController();
  final TextEditingController _esController = TextEditingController();

  bool _loading = true;
  bool _onlyPending = false;
  List<_DictRow> _allRows = [];
  List<_DictRow> _filteredRows = [];
  int _pendingCount = 0;
  Timer? _filterDebounce;
  bool _hadText = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchTextChanged);
    _load();
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    _searchController.dispose();
    _enController.dispose();
    _esController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final builtIn = _service.getBuiltInDictionary();
    final userDict = await _service.getEditableDictionary();
    final keys = <String>{...builtIn.keys, ...userDict.keys};

    final rows = keys.map((key) {
      final builtInVal = builtIn[key];
      final userVal = userDict[key];
      final hasOverride = userVal != null && userVal.isNotEmpty;
      if (hasOverride) {
        return _DictRow(key, userVal, _DictOrigin.custom);
      }
      if (builtInVal != null) {
        return _DictRow(key, builtInVal, _DictOrigin.builtIn);
      }
      return _DictRow(key, '', _DictOrigin.pending);
    }).toList()
      ..sort((a, b) {
        // Pendientes primero (son las que más urge revisar), luego alfabético.
        if (a.origin == _DictOrigin.pending && b.origin != _DictOrigin.pending) return -1;
        if (b.origin == _DictOrigin.pending && a.origin != _DictOrigin.pending) return 1;
        return a.enTag.compareTo(b.enTag);
      });

    if (!mounted) return;
    setState(() {
      _allRows = rows;
      _pendingCount = rows.where((r) => r.origin == _DictOrigin.pending).length;
      _loading = false;
      _applyFilter();
    });
  }

  void _onSearchTextChanged() {
    final bool hasText = _searchController.text.isNotEmpty;
    if (hasText != _hadText) {
      _hadText = hasText;
      setState(() {}); // solo para el botón de limpiar
    }
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 120), () {
      if (mounted) setState(_applyFilter);
    });
  }

  // Sin setState: lo llama quien ya lo hace.
  void _applyFilter() {
    final query = normalizeForSearch(_searchController.text);
    final result = <_DictRow>[];
    for (final r in _allRows) {
      if (_onlyPending && r.origin != _DictOrigin.pending) continue;
      if (query.isNotEmpty && !r.searchKey.contains(query)) continue;
      result.add(r);
    }
    _filteredRows = result;
  }

  Future<void> _showEntryDialog({_DictRow? existing}) async {
    final isNew = existing == null;
    _enController.text = existing?.enTag ?? '';
    _esController.text = existing != null && existing.origin != _DictOrigin.pending ? existing.esTranslation : '';

    final title = isNew
        ? 'Añadir Traducción'
        : existing.origin == _DictOrigin.pending
            ? 'Traducir Etiqueta'
            : 'Editar Traducción';

    final saved = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14.0),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              width: 340,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E).withOpacity(0.8),
                border: Border.all(color: Colors.white12, width: 0.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
                  if (!isNew && existing.origin == _DictOrigin.builtIn) ...[
                    const SizedBox(height: 6),
                    const Text(
                      'Esta traducción viene incorporada en la app. Si la cambias, se guardará '
                      'como una corrección personalizada que la sustituye.',
                      style: TextStyle(fontSize: 11.5, color: Colors.white54),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text('Etiqueta en inglés', style: TextStyle(fontSize: 11, color: Colors.white54)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _enController,
                    enabled: isNew, // la clave no se cambia una vez creada
                    autofocus: isNew,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1C1C1E).withOpacity(isNew ? 0.8 : 0.4),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      hintText: 'p. ej. blue_hair',
                      hintStyle: const TextStyle(color: Colors.white38),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text('Traducción al español', style: TextStyle(fontSize: 11, color: Colors.white54)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _esController,
                    autofocus: !isNew,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1C1C1E).withOpacity(0.8),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      hintText: 'p. ej. pelo azul',
                      hintStyle: const TextStyle(color: Colors.white38),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        style: TextButton.styleFrom(foregroundColor: Colors.white70),
                        child: const Text('Cancelar', style: TextStyle(fontWeight: FontWeight.w500)),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFF0A84FF)),
                        child: const Text('Guardar', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (saved != true) return;
    final enTag = _enController.text.trim().toLowerCase();
    final esText = _esController.text.trim();
    if (enTag.isEmpty || esText.isEmpty) return;

    // Lo que estaba mostrándose hasta ahora para esta etiqueta (base,
    // personalizada o el texto en inglés de respaldo si estaba pendiente),
    // para poder renombrarlo también en las imágenes que ya lo tuvieran.
    final previousDisplay = existing != null && existing.origin != _DictOrigin.pending
        ? existing.esTranslation
        : enTag.replaceAll('_', ' ').trim();

    await _service.setDictionaryEntry(enTag, esText);
    if (previousDisplay.isNotEmpty && previousDisplay != esText) {
      await widget.metadataService.renameTagGlobal(previousDisplay, esText);
    }
    await _load();
    if (mounted) {
      showGlassSnackBar(
        context,
        previousDisplay.isNotEmpty && previousDisplay != esText
            ? 'Traducción guardada y aplicada a las imágenes ya etiquetadas'
            : 'Traducción guardada',
        icon: Icons.check_circle_outline,
      );
    }
  }

  Future<void> _deleteEntry(_DictRow row) async {
    // Para una entrada "base" sin corrección esto no debería llamarse (el
    // botón de borrar está deshabilitado), pero por si acaso no hacemos
    // nada destructivo: solo se puede quitar del diccionario del usuario.
    if (row.origin == _DictOrigin.builtIn) return;
    await _service.deleteDictionaryEntry(row.enTag);
    await _load();
  }

  Future<void> _confirmClearCustom() async {
    final customCount = _allRows.where((r) => r.origin != _DictOrigin.builtIn).length;
    if (customCount == 0) return;
    final confirm = await showDialog<bool>(
          context: context,
          barrierColor: Colors.black.withOpacity(0.4),
          builder: (context) => Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14.0),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  width: 320,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E).withOpacity(0.8),
                    border: Border.all(color: Colors.white12, width: 0.5),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 28),
                      const SizedBox(height: 12),
                      const Text('Vaciar diccionario',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      Text(
                        'Se eliminarán las $customCount traducciones personalizadas/pendientes '
                        '(aprendidas y manuales). El diccionario base incorporado en la app NO se '
                        'toca. Las etiquetas ya guardadas en tus imágenes tampoco cambian. ¿Continuar?',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            style: TextButton.styleFrom(foregroundColor: Colors.white70),
                            child: const Text('Cancelar', style: TextStyle(fontWeight: FontWeight.w500)),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                            child: const Text('Vaciar todo', style: TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ) ??
        false;

    if (confirm) {
      await _service.clearDictionary();
      await _load();
      if (mounted) {
        showGlassSnackBar(context, 'Diccionario personalizado vaciado', icon: Icons.delete_outline, iconColor: Colors.redAccent);
      }
    }
  }

  Widget _originChip(_DictOrigin origin) {
    late final String label;
    late final Color color;
    switch (origin) {
      case _DictOrigin.builtIn:
        label = 'Base';
        color = Colors.white38;
        break;
      case _DictOrigin.custom:
        label = 'Personalizada';
        color = const Color(0xFF0A84FF);
        break;
      case _DictOrigin.pending:
        label = 'Pendiente';
        color = Colors.amber;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(label, style: TextStyle(fontSize: 9.5, color: color, fontWeight: FontWeight.w600)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diccionario de Traducción (ES)', style: TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined, color: Colors.redAccent),
            tooltip: 'Vaciar diccionario personalizado',
            onPressed: _confirmClearCustom,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF0A84FF),
        onPressed: () => _showEntryDialog(),
        tooltip: 'Añadir traducción',
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1C1C1E),
                      prefixIcon: const Icon(Icons.search, color: Colors.white54, size: 20),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.cancel, color: Colors.white54, size: 16),
                              onPressed: () {
                                _searchController.clear();
                                FocusScope.of(context).unfocus();
                              },
                            )
                          : null,
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      hintText: 'Buscar en inglés o español...',
                      hintStyle: const TextStyle(color: Colors.white54),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: Text(_pendingCount > 0 ? 'Pendientes ($_pendingCount)' : 'Pendientes'),
                  labelStyle: TextStyle(fontSize: 11.5, color: _onlyPending ? Colors.black : Colors.amber),
                  backgroundColor: const Color(0xFF1C1C1E),
                  selectedColor: Colors.amber,
                  selected: _onlyPending,
                  onSelected: (v) {
                    setState(() {
                      _onlyPending = v;
                      _applyFilter();
                    });
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A84FF)))
                : _filteredRows.isEmpty
                    ? Center(
                        child: Text(
                          _onlyPending
                              ? 'No hay etiquetas pendientes de traducir.'
                              : 'No se encontraron coincidencias.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white54),
                        ),
                      )
                    // Filas de altura fija y ligeras: sin ListTile, Divider ni
                    // Tooltip por fila, para que el scroll sea fluido.
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                        itemCount: _filteredRows.length,
                        itemExtent: 60,
                        cacheExtent: 500,
                        addAutomaticKeepAlives: false,
                        addSemanticIndexes: false,
                        itemBuilder: (context, index) {
                          final row = _filteredRows[index];
                          return _DictRowTile(
                            key: ValueKey(row.enTag),
                            row: row,
                            chip: _originChip(row.origin),
                            onEdit: () => _showEntryDialog(existing: row),
                            onDelete: row.origin == _DictOrigin.builtIn ? null : () => _deleteEntry(row),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

/// Fila ligera del diccionario (reemplaza a ListTile + 2 IconButton con Tooltip).
class _DictRowTile extends StatelessWidget {
  final _DictRow row;
  final Widget chip;
  final VoidCallback onEdit;
  final VoidCallback? onDelete; // null = entrada base (no se puede borrar)

  const _DictRowTile({
    super.key,
    required this.row,
    required this.chip,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isPending = row.origin == _DictOrigin.pending;
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        isPending ? 'Sin traducir' : row.esTranslation,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: isPending ? Colors.amber : Colors.white,
                          fontStyle: isPending ? FontStyle.italic : FontStyle.normal,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    chip,
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  row.enTag,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                ),
              ],
            ),
          ),
          _iconButton(
            icon: isPending ? Icons.add_circle_outline : Icons.edit_outlined,
            color: isPending ? Colors.amber : Colors.white54,
            label: isPending ? 'Añadir traducción' : 'Editar',
            onTap: onEdit,
          ),
          _iconButton(
            icon: Icons.delete_outline,
            color: onDelete == null ? Colors.white24 : Colors.redAccent,
            label: onDelete == null ? 'No se puede eliminar (es del diccionario base)' : 'Eliminar',
            onTap: onDelete,
          ),
        ],
      ),
    );
  }

  static Widget _iconButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback? onTap,
  }) {
    return Semantics(
      label: label,
      button: true,
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}