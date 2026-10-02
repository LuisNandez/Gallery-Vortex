import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui'; // ImageFilter.blur, ImmutableBuffer, ImageDescriptor
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'main.dart';
import 'metadata_service.dart';
import 'rating_stars_display.dart';
import 'thumbnail_service.dart';
import 'ui_utils.dart';

const Color _accent = Color(0xFF0A84FF);

// ---------------------------------------------------------------------------
// MODELOS
// ---------------------------------------------------------------------------

/// Criterio para decidir qué copia de cada grupo se conserva.
enum KeepStrategy { resolution, fileSize, newest, oldest, rating }

/// Orden de los grupos en la lista.
enum GroupSort { reclaimable, count }

class DuplicateGroup {
  List<File> files;
  File bestFile;
  Set<String> pathsToDelete;

  DuplicateGroup({required this.files})
      : bestFile = files.first,
        pathsToDelete = <String>{};
}

/// Datos baratos de un archivo, cacheados para no tocar el disco en cada build.
class _FileInfo {
  final int bytes;
  final DateTime modified;
  int width = 0;
  int height = 0;

  _FileInfo(this.bytes, this.modified);

  int get pixels => width * height;

  factory _FileInfo.read(File f) {
    try {
      final s = f.statSync();
      return _FileInfo(s.size, s.modified);
    } catch (_) {
      return _FileInfo(0, DateTime.fromMillisecondsSinceEpoch(0));
    }
  }
}

String _fmtBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

// ---------------------------------------------------------------------------
// PANTALLA PRINCIPAL
// ---------------------------------------------------------------------------

class DuplicateScannerScreen extends StatefulWidget {
  final Directory vaultDir;
  final MetadataService metadataService;
  final ThumbnailService thumbnailService;

  const DuplicateScannerScreen({
    super.key,
    required this.vaultDir,
    required this.metadataService,
    required this.thumbnailService,
  });

  @override
  State<DuplicateScannerScreen> createState() => _DuplicateScannerScreenState();
}

class _DuplicateScannerScreenState extends State<DuplicateScannerScreen> {
  // Claves de preferencias (persisten entre sesiones)
  static const _kStrategy = 'dup_keep_strategy';
  static const _kSort = 'dup_sort';
  static const _kThreshold = 'dup_threshold';
  static const _kMerge = 'dup_merge_metadata';
  static const _kIgnored = 'dup_ignored_groups';

  // Escaneo
  bool _isScanning = true;
  String _statusText = 'Preparando escaneo...';
  double _progress = 0.0;
  String _etaText = 'Calculando...';
  ReceivePort? _receivePort;
  Isolate? _isolate;

  // Resultados
  Map<String, int> _hashes = {};
  List<List<String>> _rawGroups = [];
  List<DuplicateGroup> _groups = [];
  final Map<String, _FileInfo> _info = {};
  final Map<String, Future<File>> _thumbFutures = {};
  int _hiddenCount = 0;
  bool _regrouping = false;

  // Preferencias
  KeepStrategy _strategy = KeepStrategy.resolution;
  GroupSort _sort = GroupSort.reclaimable;
  int _threshold = 5;
  bool _mergeMetadata = true;
  Set<String> _ignored = {};

  // Borrado
  bool _deleting = false;
  int _deleteDone = 0;
  int _deleteTotal = 0;
  int _freedBytes = 0; // acumulado de la sesión
  int _deletedTotal = 0;

  // --- Estadísticas globales ---
  int get _totalMarked =>
      _groups.fold(0, (s, g) => s + g.pathsToDelete.length);
  int get _totalMarkedBytes => _groups.fold(0, (s, g) => s + _markedBytes(g));

  int _markedBytes(DuplicateGroup g) => g.pathsToDelete
      .fold(0, (s, path) => s + (_info[path]?.bytes ?? 0));

  _FileInfo _infoFor(File f) => _info.putIfAbsent(f.path, () => _FileInfo.read(f));
  String _relId(File f) => p.relative(f.path, from: widget.vaultDir.path);
  Future<File> _thumbFor(File f) =>
      _thumbFutures.putIfAbsent(f.path, () => widget.thumbnailService.getThumbnail(f));

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _receivePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // PREFERENCIAS
  // -------------------------------------------------------------------------

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getInt(_kStrategy);
      if (s != null && s >= 0 && s < KeepStrategy.values.length) {
        _strategy = KeepStrategy.values[s];
      }
      final so = prefs.getInt(_kSort);
      if (so != null && so >= 0 && so < GroupSort.values.length) {
        _sort = GroupSort.values[so];
      }
      _threshold = prefs.getInt(_kThreshold) ?? 5;
      _mergeMetadata = prefs.getBool(_kMerge) ?? true;
      _ignored = (prefs.getStringList(_kIgnored) ?? const []).toSet();
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kStrategy, _strategy.index);
      await prefs.setInt(_kSort, _sort.index);
      await prefs.setInt(_kThreshold, _threshold);
      await prefs.setBool(_kMerge, _mergeMetadata);
      await prefs.setStringList(_kIgnored, _ignored.toList());
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // ESCANEO
  // -------------------------------------------------------------------------

  String _formatETA(double etaMs) {
    if (etaMs < 0 || etaMs.isNaN) return 'Calculando...';
    final duration = Duration(milliseconds: etaMs.toInt());
    if (duration.inMinutes > 0) {
      return '${duration.inMinutes} min ${duration.inSeconds.remainder(60)} seg';
    }
    return '${duration.inSeconds} seg';
  }

  Future<void> _startScan() async {
    _receivePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
    if (mounted) {
      setState(() {
        _isScanning = true;
        _progress = 0;
        _statusText = 'Preparando escaneo...';
        _etaText = 'Calculando...';
      });
    }

    try {
      await _loadPrefs();

      final allEntities = await widget.vaultDir.list(recursive: true).toList();
      final imageFiles = allEntities.whereType<File>().where((file) {
        final realExt = _getRealExtensionForScanner(file.path);
        if (['.mp4', '.mov', '.avi', '.mkv', '.webm'].contains(realExt)) return false;
        if (realExt == '.gif') return false;
        if (realExt == '.webp' && _isAnimatedWebp(file.path)) return false;
        return ['.jpg', '.jpeg', '.png', '.webp', '.bmp'].contains(realExt);
      }).toList();

      if (imageFiles.isEmpty) {
        if (mounted) {
          setState(() {
            _groups = [];
            _isScanning = false;
          });
        }
        return;
      }

      final paths = imageFiles.map((e) => e.path).toList();
      final supportDir = await getApplicationSupportDirectory();
      final thumbDirPath = p.join(supportDir.path, 'thumbnails');

      _receivePort = ReceivePort();
      _isolate = await Isolate.spawn(
          vortexScannerWorker, [_receivePort!.sendPort, paths, thumbDirPath, _threshold]);

      _receivePort!.listen((message) async {
        if (!mounted || message is! Map) return;
        final type = message['type'];

        if (type == 'progress') {
          setState(() {
            _progress = message['progress'];
            _etaText = _formatETA(message['etaMs']);
            _statusText = 'Analizando ${message['processed']} de ${message['total']} imágenes';
          });
        } else if (type == 'status') {
          setState(() {
            _progress = 1.0;
            _statusText = message['message'];
            _etaText = 'Casi listo';
          });
        } else if (type == 'done') {
          _receivePort?.close();
          _isolate?.kill();

          _rawGroups = (message['groups'] as List)
              .map((g) => (g as List).cast<String>().toList())
              .toList();
          _hashes = Map<String, int>.from(message['hashes'] as Map);

          await _buildGroups();
          if (mounted) setState(() => _isScanning = false);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isScanning = false);
        showGlassSnackBar(context, 'Error al escanear: $e', icon: Icons.error_outline);
      }
    }
  }

  /// Convierte los grupos crudos (rutas) en modelos, lee resoluciones,
  /// oculta los grupos ignorados y aplica el criterio de conservación.
  Future<void> _buildGroups() async {
    final groups = <DuplicateGroup>[];
    final allFiles = <File>[];
    var hidden = 0;

    for (final paths in _rawGroups) {
      final files = paths.map((x) => File(x)).where((f) => f.existsSync()).toList();
      if (files.length < 2) continue;
      if (_ignored.contains(_groupKey(files))) {
        hidden++;
        continue;
      }
      groups.add(DuplicateGroup(files: files));
      allFiles.addAll(files);
    }

    await _loadDimensions(allFiles);

    for (final g in groups) {
      _orderGroup(g);
    }

    if (!mounted) return;
    setState(() {
      _groups = groups;
      _hiddenCount = hidden;
      _sortGroups();
    });
  }

  String _groupKey(List<File> files) {
    final ids = files.map(_relId).toList()..sort();
    return ids.join('|');
  }

  Future<void> _loadDimensions(List<File> files) async {
    var done = 0;
    for (final f in files) {
      final info = _infoFor(f);
      if (info.width == 0) {
        final size = await _readDimensions(f.path);
        if (size != null) {
          info.width = size.width.toInt();
          info.height = size.height.toInt();
        }
      }
      done++;
      if (mounted && done % 40 == 0) {
        setState(() => _statusText = 'Leyendo resoluciones ($done de ${files.length})');
      }
    }
  }

  /// Lee ancho/alto sin decodificar la imagen completa.
  Future<Size?> _readDimensions(String path) async {
    ImmutableBuffer? buffer;
    ImageDescriptor? descriptor;
    try {
      buffer = await ImmutableBuffer.fromFilePath(path);
      descriptor = await ImageDescriptor.encoded(buffer);
      return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
    } catch (_) {
      return null;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  // -------------------------------------------------------------------------
  // SELECCIÓN INTELIGENTE
  // -------------------------------------------------------------------------

  int _compare(File a, File b, KeepStrategy s) {
    final ia = _infoFor(a), ib = _infoFor(b);
    int byRes() => ib.pixels.compareTo(ia.pixels);
    int bySize() => ib.bytes.compareTo(ia.bytes);

    int r;
    switch (s) {
      case KeepStrategy.resolution:
        r = byRes();
        if (r == 0) r = bySize();
        break;
      case KeepStrategy.fileSize:
        r = bySize();
        if (r == 0) r = byRes();
        break;
      case KeepStrategy.newest:
        r = ib.modified.compareTo(ia.modified);
        break;
      case KeepStrategy.oldest:
        r = ia.modified.compareTo(ib.modified);
        break;
      case KeepStrategy.rating:
        final ra = widget.metadataService.getMetadataForImage(_relId(a)).rating;
        final rb = widget.metadataService.getMetadataForImage(_relId(b)).rating;
        r = rb.compareTo(ra);
        if (r == 0) r = byRes();
        if (r == 0) r = bySize();
        break;
    }
    return r != 0 ? r : a.path.compareTo(b.path);
  }

  /// Ordena el grupo según el criterio y marca todo menos el mejor.
  void _orderGroup(DuplicateGroup g, {KeepStrategy? strategy}) {
    final s = strategy ?? _strategy;
    g.files.sort((a, b) => _compare(a, b, s));
    g.bestFile = g.files.first;
    g.pathsToDelete =
        g.files.where((f) => f.path != g.bestFile.path).map((f) => f.path).toSet();
  }

  void _applyStrategyToAll(KeepStrategy s) {
    setState(() {
      _strategy = s;
      for (final g in _groups) {
        _orderGroup(g);
      }
      _sortGroups();
    });
    _savePrefs();
  }

  void _sortGroups() {
    switch (_sort) {
      case GroupSort.reclaimable:
        _groups.sort((a, b) => _markedBytes(b).compareTo(_markedBytes(a)));
        break;
      case GroupSort.count:
        _groups.sort((a, b) => b.files.length.compareTo(a.files.length));
        break;
    }
  }

  void _toggleFile(DuplicateGroup g, File f) {
    final marked = g.pathsToDelete.contains(f.path);
    if (!marked && g.pathsToDelete.length >= g.files.length - 1) {
      showGlassSnackBar(context, 'Debes conservar al menos una copia por grupo.',
          icon: Icons.info_outline, iconColor: Colors.amber);
      return;
    }
    setState(() => marked ? g.pathsToDelete.remove(f.path) : g.pathsToDelete.add(f.path));
  }

  void _keepOnly(DuplicateGroup g, File f) {
    setState(() {
      g.bestFile = f;
      g.pathsToDelete =
          g.files.where((x) => x.path != f.path).map((x) => x.path).toSet();
    });
  }

  void _ignoreGroup(DuplicateGroup g) {
    setState(() {
      _ignored.add(_groupKey(g.files));
      _groups.remove(g);
      _hiddenCount++;
    });
    _savePrefs();
    showGlassSnackBar(context, 'Grupo ocultado: no se volverá a sugerir.',
        icon: Icons.visibility_off_outlined);
  }

  Future<void> _restoreIgnored() async {
    setState(() {
      _ignored.clear();
      _isScanning = true;
      _statusText = 'Restaurando grupos ocultos...';
    });
    await _savePrefs();
    await _buildGroups();
    if (mounted) setState(() => _isScanning = false);
  }

  /// Cambia la sensibilidad reagrupando los hashes ya calculados (sin releer imágenes).
  Future<void> _changeThreshold(int t) async {
    if (t == _threshold || _regrouping) return;
    setState(() {
      _threshold = t;
      _regrouping = true;
    });
    _savePrefs();
    final hashes = _hashes;
    final raw = await Isolate.run(() => groupHashes(hashes, t));
    _rawGroups = raw;
    await _buildGroups();
    if (mounted) setState(() => _regrouping = false);
  }

  // -------------------------------------------------------------------------
  // BORRADO
  // -------------------------------------------------------------------------

  Future<bool> _confirmDelete() async {
    final groupsAffected = _groups.where((g) => g.pathsToDelete.isNotEmpty).length;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Colors.white12, width: 0.5),
          ),
          title: const Text('Eliminar duplicados',
              style: TextStyle(color: Colors.white, fontSize: 16)),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Se eliminarán $_totalMarked archivos de $groupsAffected grupos '
                  'y recuperarás ${_fmtBytes(_totalMarkedBytes)}.',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  activeColor: _accent,
                  value: _mergeMetadata,
                  onChanged: (v) {
                    setD(() => _mergeMetadata = v ?? true);
                    setState(() {});
                  },
                  title: const Text('Pasar etiquetas, perfiles y estrellas a la copia que se conserva',
                      style: TextStyle(color: Colors.white, fontSize: 12.5)),
                ),
                const SizedBox(height: 6),
                const Text('Esta acción no se puede deshacer.',
                    style: TextStyle(color: Colors.white38, fontSize: 11.5)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              child: const Text('Eliminar', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
    _savePrefs();
    return result ?? false;
  }

  Future<void> _onDeletePressed() async {
    if (_deleting || _totalMarked == 0) return;
    if (await _confirmDelete()) await _deleteAllSelected();
  }

  /// Pasa tags, personajes, perfil y la mejor valoración del duplicado a la copia conservada.
  Future<void> _mergeInto(String keeperId, String dupId) async {
    final ms = widget.metadataService;
    final dup = ms.getMetadataForImage(dupId);
    final keep = ms.getMetadataForImage(keeperId);

    if (dup.tags.isNotEmpty) await ms.addTagsToImage(keeperId, List<String>.from(dup.tags));
    if (dup.rating > keep.rating) await ms.setRatingForImage(keeperId, dup.rating);
    for (final cid in List<int>.from(dup.characterIds)) {
      await ms.addCharacterToImage(keeperId, cid);
    }
    if (keep.profile.isEmpty && dup.profile.isNotEmpty) {
      await ms.setProfileForImage(keeperId, Map<String, String>.from(dup.profile));
    }
  }

  Future<bool> _tryDelete(File file) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await FileImage(file).evict();
        if (await file.exists()) await file.delete();
        return true;
      } catch (_) {
        // Windows a veces tarda en soltar el archivo: un reintento corto basta.
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
    return false;
  }

  Future<void> _deleteAllSelected() async {
    setState(() {
      _deleting = true;
      _deleteDone = 0;
      _deleteTotal = _totalMarked;
    });

    var deleted = 0, failed = 0, freed = 0;

    for (final group in _groups.toList()) {
      final toDelete =
          group.files.where((f) => group.pathsToDelete.contains(f.path)).toList();
      if (toDelete.isEmpty) continue;

      final keepers = group.files.where((f) => !group.pathsToDelete.contains(f.path));
      if (keepers.isEmpty) continue; // seguridad: nunca borrar el grupo entero
      final keeperId = _relId(keepers.first);

      final removed = <String>{};
      for (final file in toDelete) {
        final id = _relId(file);
        final bytes = _infoFor(file).bytes;

        if (await _tryDelete(file)) {
          try {
            if (_mergeMetadata) await _mergeInto(keeperId, id);
            await widget.metadataService.deleteMetadata(id);
            await widget.thumbnailService.clearThumbnail(p.basename(file.path));
          } catch (e) {
            debugPrint('Metadatos no limpiados para $id: $e');
          }
          removed.add(file.path);
          deleted++;
          freed += bytes;
        } else {
          failed++;
          debugPrint('No se pudo borrar (bloqueado): ${file.path}');
        }

        _deleteDone++;
        if (mounted && (_deleteDone % 4 == 0 || _deleteDone == _deleteTotal)) {
          setState(() {});
        }
      }

      if (!mounted) return;
      setState(() {
        group.files.removeWhere((f) => removed.contains(f.path));
        group.pathsToDelete.removeWhere((x) => removed.contains(x));
        for (final r in removed) {
          _info.remove(r);
          _thumbFutures.remove(r);
        }
        if (group.files.length <= 1) {
          _groups.remove(group);
        } else {
          if (!group.files.any((f) => f.path == group.bestFile.path)) {
            group.bestFile = group.files.first;
          }
          // Los que fallaron quedan sin marcar para que no den errores gráficos.
          group.pathsToDelete.clear();
        }
      });
    }

    if (!mounted) return;
    setState(() {
      _deleting = false;
      _freedBytes += freed;
      _deletedTotal += deleted;
    });

    if (failed > 0) {
      showGlassSnackBar(
          context, '$deleted eliminados (${_fmtBytes(freed)}). $failed estaban en uso por Windows.',
          icon: Icons.warning_amber_rounded, iconColor: Colors.amber);
    } else if (deleted > 0) {
      showGlassSnackBar(context, '$deleted duplicados eliminados · ${_fmtBytes(freed)} liberados.',
          icon: Icons.auto_delete_outlined);
    }
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_deleting,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.delete): _onDeletePressed,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: const Color(0xFF000000),
            appBar: AppBar(
              backgroundColor: const Color(0xE61C1C1E),
              title: const Text('Limpieza de Vórtice', style: TextStyle(fontSize: 14)),
              centerTitle: true,
              actions: [
                if (!_isScanning && _groups.isNotEmpty) ...[
                  IconButton(
                    tooltip: 'Aplicar criterio a todos los grupos',
                    icon: const Icon(Icons.auto_awesome, size: 20),
                    onPressed: _deleting ? null : () => _applyStrategyToAll(_strategy),
                  ),
                  IconButton(
                    tooltip: 'Desmarcar todo',
                    icon: const Icon(Icons.deselect, size: 20),
                    onPressed: _deleting
                        ? null
                        : () => setState(() {
                              for (final g in _groups) {
                                g.pathsToDelete.clear();
                              }
                            }),
                  ),
                ],
                IconButton(
                  tooltip: 'Volver a escanear',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: (_isScanning || _deleting) ? null : _startScan,
                ),
                const SizedBox(width: 8),
              ],
            ),
            body: _isScanning ? _buildLoadingState() : _buildResultsState(),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: const Color(0xFF151515),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12, width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.layers_clear_outlined, size: 60, color: Colors.white70),
            const SizedBox(height: 24),
            Text(_statusText,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
            const SizedBox(height: 24),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 6,
                backgroundColor: Colors.white10,
                valueColor: const AlwaysStoppedAnimation<Color>(_accent),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${(_progress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
                Text(_etaText, style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 20),
            TextButton(
              onPressed: () => Navigator.maybePop(context),
              child: const Text('Cancelar', style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle_outline, size: 60, color: Colors.white54),
          const SizedBox(height: 16),
          Text(_deletedTotal > 0 ? 'Limpieza completada' : 'Vórtice optimizado',
              style: const TextStyle(fontSize: 16, color: Colors.white)),
          const SizedBox(height: 8),
          Text(
            _deletedTotal > 0
                ? '$_deletedTotal duplicados eliminados · ${_fmtBytes(_freedBytes)} liberados'
                : 'No se encontraron imágenes redundantes.',
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
          if (_hiddenCount > 0) ...[
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _restoreIgnored,
              icon: const Icon(Icons.visibility_outlined, size: 16),
              label: Text('Mostrar $_hiddenCount grupos ocultos'),
            ),
          ],
          if (_threshold < 8) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => _changeThreshold(8),
              child: const Text('Probar con sensibilidad flexible',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final redundant = _groups.fold<int>(0, (s, g) => s + g.files.length - 1);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: const BoxDecoration(
        color: Color(0xFF0E0E0E),
        border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${_groups.length} grupos · $redundant redundantes',
            style: const TextStyle(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
          _MenuChip<KeepStrategy>(
            icon: Icons.auto_awesome,
            prefix: 'Conservar',
            current: _strategy,
            onSelected: _deleting ? (_) {} : _applyStrategyToAll,
            options: const [
              _Opt(KeepStrategy.resolution, 'Mayor resolución', Icons.high_quality_outlined),
              _Opt(KeepStrategy.fileSize, 'Mayor peso', Icons.sd_storage_outlined),
              _Opt(KeepStrategy.newest, 'Más reciente', Icons.update),
              _Opt(KeepStrategy.oldest, 'Más antigua', Icons.history),
              _Opt(KeepStrategy.rating, 'Mejor valorada', Icons.star_outline),
            ],
          ),
          _MenuChip<GroupSort>(
            icon: Icons.sort,
            prefix: 'Orden',
            current: _sort,
            onSelected: (v) {
              setState(() {
                _sort = v;
                _sortGroups();
              });
              _savePrefs();
            },
            options: const [
              _Opt(GroupSort.reclaimable, 'Más espacio recuperable', Icons.compress),
              _Opt(GroupSort.count, 'Más copias', Icons.filter_none),
            ],
          ),
          _MenuChip<int>(
            icon: Icons.tune,
            prefix: 'Sensibilidad',
            current: _threshold,
            onSelected: _changeThreshold,
            options: const [
              _Opt(2, 'Estricta (casi idénticas)', Icons.lock_outline),
              _Opt(5, 'Normal', Icons.balance),
              _Opt(8, 'Flexible (más parecidas)', Icons.blur_on),
            ],
          ),
          if (_regrouping)
            const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38)),
          if (_hiddenCount > 0)
            TextButton.icon(
              onPressed: _restoreIgnored,
              style: TextButton.styleFrom(
                  foregroundColor: Colors.white38,
                  padding: const EdgeInsets.symmetric(horizontal: 8)),
              icon: const Icon(Icons.visibility_outlined, size: 14),
              label: Text('$_hiddenCount ocultos', style: const TextStyle(fontSize: 11.5)),
            ),
        ],
      ),
    );
  }

  Widget _buildResultsState() {
    if (_groups.isEmpty) return _buildEmptyState();

    return Column(
      children: [
        _buildToolbar(),
        Expanded(
          child: Stack(
            children: [
              ListView.builder(
                padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 110),
                itemCount: _groups.length,
                itemBuilder: (context, index) => _buildDuplicateCard(_groups[index]),
              ),
              if (_totalMarked > 0 && !_deleting) _buildFloatingBar(),
              if (_deleting) _buildDeletingOverlay(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFloatingBar() {
    return Positioned(
      bottom: 24,
      left: 0,
      right: 0,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF252525).withOpacity(0.85),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.white12, width: 0.5),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 20,
                      offset: const Offset(0, 10))
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.auto_delete_outlined, color: Colors.white70, size: 20),
                  const SizedBox(width: 12),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$_totalMarked seleccionados',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                      Text('Liberan ${_fmtBytes(_totalMarkedBytes)}',
                          style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
                    ],
                  ),
                  const SizedBox(width: 24),
                  ElevatedButton(
                    onPressed: _onDeletePressed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    ),
                    child: const Text('Eliminar',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeletingOverlay() {
    final value = _deleteTotal == 0 ? null : _deleteDone / _deleteTotal;
    return Positioned.fill(
      child: AbsorbPointer(
        child: Container(
          color: Colors.black54,
          child: Center(
            child: Container(
              width: 340,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12, width: 0.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Eliminando $_deleteDone de $_deleteTotal...',
                      style: const TextStyle(color: Colors.white, fontSize: 13.5)),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: value,
                      minHeight: 6,
                      backgroundColor: Colors.white10,
                      valueColor: const AlwaysStoppedAnimation<Color>(_accent),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _isExact(DuplicateGroup g) {
    final first = _infoFor(g.files.first);
    return g.files.every((f) {
      final i = _infoFor(f);
      return i.bytes == first.bytes && i.width == first.width && i.height == first.height;
    });
  }

  Widget _buildDuplicateCard(DuplicateGroup group) {
    final exact = _isExact(group);
    final reclaim = _markedBytes(group);

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                const Icon(Icons.difference_outlined, color: Colors.white54, size: 18),
                const SizedBox(width: 10),
                Text('${group.files.length} coincidencias',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                _Badge(
                  text: exact ? 'Copia exacta' : 'Similares',
                  color: exact ? const Color(0xFF30D158) : Colors.white38,
                ),
                const Spacer(),
                if (reclaim > 0)
                  Text('Libera ${_fmtBytes(reclaim)}',
                      style: const TextStyle(color: Colors.white38, fontSize: 11.5)),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz, color: Colors.white54, size: 20),
                  color: const Color(0xFF2C2C2E),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: Colors.white12, width: 0.5)),
                  tooltip: 'Opciones del grupo',
                  onSelected: (val) {
                    switch (val) {
                      case 'auto':
                        setState(() => _orderGroup(group));
                        break;
                      case 'clear':
                        setState(() => group.pathsToDelete.clear());
                        break;
                      case 'invert':
                        setState(() {
                          final inverted = group.files
                              .where((f) => !group.pathsToDelete.contains(f.path))
                              .map((f) => f.path)
                              .toSet();
                          // Nunca dejar el grupo entero marcado.
                          if (inverted.length < group.files.length) {
                            group.pathsToDelete = inverted;
                          }
                        });
                        break;
                      case 'ignore':
                        _ignoreGroup(group);
                        break;
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                        value: 'auto',
                        child: _MenuRow(Icons.auto_awesome, 'Aplicar criterio de conservación')),
                    PopupMenuItem(
                        value: 'invert', child: _MenuRow(Icons.swap_horiz, 'Invertir selección')),
                    PopupMenuItem(
                        value: 'clear', child: _MenuRow(Icons.deselect, 'Desmarcar todos')),
                    PopupMenuDivider(height: 1),
                    PopupMenuItem(
                        value: 'ignore',
                        child: _MenuRow(Icons.visibility_off_outlined, 'No son duplicados (ocultar)')),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          SizedBox(
            height: 200,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(16),
              itemCount: group.files.length,
              itemBuilder: (context, idx) {
                final file = group.files[idx];
                final meta = widget.metadataService.getMetadataForImage(_relId(file));
                return _DuplicateTile(
                  key: ValueKey(file.path),
                  info: _infoFor(file),
                  thumbnail: _thumbFor(file),
                  isBest: file.path == group.bestFile.path,
                  isMarked: group.pathsToDelete.contains(file.path),
                  rating: meta.rating,
                  tagCount: meta.tags.length,
                  onTap: () => _toggleFile(group, file),
                  onKeepOnly: () => _keepOnly(group, file),
                  onOpen: () => _openViewer(group, idx),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _openViewer(DuplicateGroup group, int idx) {
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        opaque: false,
        pageBuilder: (context, _, __) => FullScreenImageViewer(
          imageFiles: group.files,
          initialIndex: idx,
          instantTransition: true,
          vaultRootPath: widget.vaultDir.path,
          metadataService: widget.metadataService,
          exportCallback: (f) async {},
          onClose: () => Navigator.pop(context),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// WIDGETS AUXILIARES
// ---------------------------------------------------------------------------

class _DuplicateTile extends StatefulWidget {
  final _FileInfo info;
  final Future<File> thumbnail;
  final bool isBest;
  final bool isMarked;
  final int rating;
  final int tagCount;
  final VoidCallback onTap;
  final VoidCallback onKeepOnly;
  final VoidCallback onOpen;

  const _DuplicateTile({
    super.key,
    required this.info,
    required this.thumbnail,
    required this.isBest,
    required this.isMarked,
    required this.rating,
    required this.tagCount,
    required this.onTap,
    required this.onKeepOnly,
    required this.onOpen,
  });

  @override
  State<_DuplicateTile> createState() => _DuplicateTileState();
}

class _DuplicateTileState extends State<_DuplicateTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final marked = widget.isMarked;
    final info = widget.info;

    final sizeLine = widget.tagCount > 0
        ? '${_fmtBytes(info.bytes)} · ${widget.tagCount} etiq.'
        : _fmtBytes(info.bytes);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        // Clic derecho = ver a pantalla completa (sin el retraso de un doble toque).
        onSecondaryTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 150,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: marked ? Colors.white30 : _accent.withOpacity(0.9),
              width: 1.5,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: FutureBuilder<File>(
                  future: widget.thumbnail,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return Container(
                        color: const Color(0xFF1C1C1E),
                        child: const Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
                          ),
                        ),
                      );
                    }
                    return Image.file(
                      snapshot.data!,
                      fit: BoxFit.cover,
                      cacheWidth: 300,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: const Color(0xFF1C1C1E),
                        child: const Center(
                            child: Icon(Icons.broken_image, color: Colors.white24, size: 30)),
                      ),
                    );
                  },
                ),
              ),

              // Sombreado para los descartados
              AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: marked ? 1 : 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),

              // Checkbox
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: marked ? Colors.white : Colors.black45,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Icon(Icons.check,
                      size: 14, color: marked ? Colors.black : Colors.transparent),
                ),
              ),

              // Acciones rápidas al pasar el cursor
              Positioned(
                top: 6,
                left: 6,
                child: IgnorePointer(
                  ignoring: !_hover,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: _hover ? 1 : 0,
                    child: Row(
                      children: [
                        _MiniButton(
                            icon: Icons.open_in_full, tooltip: 'Ver en grande', onTap: widget.onOpen),
                        const SizedBox(width: 4),
                        _MiniButton(
                            icon: Icons.push_pin_outlined,
                            tooltip: 'Conservar solo esta',
                            onTap: widget.onKeepOnly),
                      ],
                    ),
                  ),
                ),
              ),

              // Información inferior
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(6), bottomRight: Radius.circular(6)),
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black.withOpacity(0.85), Colors.transparent],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.rating > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: RatingStarsDisplay(rating: widget.rating, iconSize: 10),
                        ),
                      if (info.width > 0)
                        Text('${info.width}×${info.height}',
                            style: TextStyle(
                                color: marked ? Colors.white54 : Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                      Text(sizeLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: marked ? Colors.white38 : Colors.white70, fontSize: 10)),
                      const SizedBox(height: 1),
                      if (marked)
                        const Text('Descartado',
                            style: TextStyle(
                                color: Colors.white54,
                                fontSize: 10,
                                decoration: TextDecoration.lineThrough))
                      else
                        Text(widget.isBest ? 'Recomendado' : 'Se conserva',
                            style: const TextStyle(
                                color: _accent, fontSize: 10, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _MiniButton({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white24, width: 0.5),
          ),
          child: Icon(icon, size: 13, color: Colors.white),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w600)),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MenuRow(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.white70),
        const SizedBox(width: 10),
        Text(text, style: const TextStyle(fontSize: 13, color: Colors.white)),
      ],
    );
  }
}

class _Opt<T> {
  final T value;
  final String label;
  final IconData icon;
  const _Opt(this.value, this.label, this.icon);
}

/// Chip con menú desplegable: "Conservar: Mayor resolución ▾".
class _MenuChip<T> extends StatelessWidget {
  final IconData icon;
  final String prefix;
  final T current;
  final List<_Opt<T>> options;
  final ValueChanged<T> onSelected;

  const _MenuChip({
    required this.icon,
    required this.prefix,
    required this.current,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final cur = options.firstWhere((o) => o.value == current, orElse: () => options.first);
    return PopupMenuButton<T>(
      tooltip: prefix,
      color: const Color(0xFF2C2C2E),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Colors.white12, width: 0.5)),
      onSelected: onSelected,
      itemBuilder: (_) => options
          .map((o) => PopupMenuItem<T>(
                value: o.value,
                child: Row(
                  children: [
                    Icon(o.icon,
                        size: 16, color: o.value == current ? _accent : Colors.white70),
                    const SizedBox(width: 10),
                    Text(o.label,
                        style: TextStyle(
                            fontSize: 13,
                            color: o.value == current ? _accent : Colors.white)),
                  ],
                ),
              ))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white54),
            const SizedBox(width: 6),
            Text('$prefix: ',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
            Text(cur.label, style: const TextStyle(color: Colors.white, fontSize: 12)),
            const Icon(Icons.arrow_drop_down, size: 16, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LÓGICA DE ESCANEO (BACKGROUND)
// ---------------------------------------------------------------------------

String _decipherExtension(String ciphered) {
  String result = '';
  for (int i = 0; i < ciphered.length; i++) {
    String char = ciphered[i].toLowerCase();
    if (char == '0') {
      result += '.';
    } else if (RegExp(r'[a-z]').hasMatch(char)) {
      int charCode = char.codeUnitAt(0);
      int prevCode = charCode == 97 ? 122 : charCode - 1;
      result += String.fromCharCode(prevCode);
    } else {
      result += char;
    }
  }
  return result;
}

String _getRealExtensionForScanner(String path) {
  if (path.toLowerCase().endsWith('.vtx')) {
    final base = p.basenameWithoutExtension(path);
    final lastZero = base.lastIndexOf('0');
    if (lastZero != -1) {
      return _decipherExtension(base.substring(lastZero));
    }
  }
  return p.extension(path).toLowerCase();
}

bool _isAnimatedWebp(String filePath) {
  RandomAccessFile? raf;
  try {
    final file = File(filePath);
    raf = file.openSync(mode: FileMode.read);
    final header = raf.readSync(21);
    if (header.length >= 21) {
      final isWebP = String.fromCharCodes(header.sublist(8, 12)) == 'WEBP';
      final isVP8X = String.fromCharCodes(header.sublist(12, 16)) == 'VP8X';
      if (isWebP && isVP8X) return (header[20] & 0x02) != 0;
    }
  } catch (_) {
    // Ignoramos el error, pero pasamos al finally
  } finally {
    // Asegura que Windows libere el archivo siempre
    try {
      raf?.closeSync();
    } catch (_) {}
  }
  return false;
}

int _popCount(int x) {
  var c = 0;
  while (x != 0) {
    x &= x - 1;
    c++;
  }
  return c;
}

/// Agrupa por distancia de Hamming entre hashes de 64 bits (dHash).
/// Función pura y de nivel superior: se puede ejecutar en un Isolate.
List<List<String>> groupHashes(Map<String, int> hashes, int threshold) {
  final paths = hashes.keys.toList();
  final values = paths.map((k) => hashes[k]!).toList();
  final used = List<bool>.filled(paths.length, false);
  final groups = <List<String>>[];

  for (var i = 0; i < paths.length; i++) {
    if (used[i]) continue;
    final group = <String>[paths[i]];
    for (var j = i + 1; j < paths.length; j++) {
      if (used[j]) continue;
      if (_popCount(values[i] ^ values[j]) <= threshold) {
        group.add(paths[j]);
        used[j] = true;
      }
    }
    used[i] = true;
    if (group.length > 1) groups.add(group);
  }
  return groups;
}

void vortexScannerWorker(List<dynamic> args) {
  final SendPort sendPort = args[0];
  final List<String> paths = args[1];
  final String thumbnailsDir = args[2];
  final int threshold = args[3];

  final Map<String, int> hashMap = {};
  final int totalFiles = paths.length;
  final startTime = DateTime.now();

  for (int i = 0; i < totalFiles; i++) {
    final path = paths[i];
    try {
      final baseName = p.basenameWithoutExtension(path);
      final thumbPath = p.join(thumbnailsDir, '$baseName.thumb.vtx');
      final fileToRead = File(thumbPath).existsSync() ? File(thumbPath) : File(path);

      final image = img.decodeImage(fileToRead.readAsBytesSync());
      if (image != null) {
        final resized = img.copyResize(image, width: 9, height: 8);
        final grayscale = img.grayscale(resized);

        var hash = 0;
        for (int y = 0; y < 8; y++) {
          for (int x = 0; x < 8; x++) {
            final p1 = grayscale.getPixel(x, y).r;
            final p2 = grayscale.getPixel(x + 1, y).r;
            hash = (hash << 1) | (p1 < p2 ? 1 : 0);
          }
        }
        hashMap[path] = hash;
      }
    } catch (_) {}

    final processed = i + 1;
    if (processed % 50 == 0 || processed == totalFiles) {
      final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;
      final etaMs = (elapsedMs / processed) * (totalFiles - processed);
      sendPort.send({
        'type': 'progress',
        'progress': processed / totalFiles,
        'etaMs': etaMs,
        'processed': processed,
        'total': totalFiles,
      });
    }
  }

  sendPort.send({
    'type': 'status',
    'message': 'Cruzando datos y buscando coincidencias...'
  });

  sendPort.send({
    'type': 'done',
    'groups': groupHashes(hashMap, threshold),
    'hashes': hashMap,
  });
}