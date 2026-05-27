import 'dart:io';
import 'dart:ui';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'metadata_service.dart';
import 'thumbnail_service.dart';
import 'main.dart'; 
import 'ui_utils.dart';
import 'tag_editor_dialog.dart';
import 'rating_stars_display.dart';
import 'profile_editor_dialog.dart';

class ProfileManagementScreen extends StatefulWidget {
  final MetadataService metadataService;
  final ThumbnailService thumbnailService;
  final String vaultRootPath;

  const ProfileManagementScreen({
    super.key,
    required this.metadataService,
    required this.thumbnailService,
    required this.vaultRootPath,
  });

  @override
  State<ProfileManagementScreen> createState() => _ProfileManagementScreenState();
}

class _ProfileManagementScreenState extends State<ProfileManagementScreen> {
  List<LocalCharacter> _allCharacters = [];
  List<LocalCharacter> _filteredCharacters = [];
  LocalCharacter? _selectedCharacter;
  List<String> _associatedImages = [];
  bool _showExtraFields = false;
  
  // --- NUEVO: ESTADO DE VISTA (PLANOS VS GRUPOS) ---
  bool _groupByFranchise = false;

  final TextEditingController _searchCtrl = TextEditingController();

  // --- VARIABLES PARA EL MOTOR DE SELECCIÓN Y GESTOS ---
  Set<String> _selectedImages = {};
  int? _shiftSelectionAnchorIndex;
  int _focusedIndex = -1;
  Timer? _doubleTapTimer;
  String? _lastTappedImage;
  OverlayEntry? _contextMenuOverlay;

  @override
  void initState() {
    super.initState();
    _loadCharacters();
    _searchCtrl.addListener(_filterCharacters);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _doubleTapTimer?.cancel();
    _hideContextMenu();
    super.dispose();
  }

  Future<void> _loadCharacters() async {
    final chars = await widget.metadataService.getAllCharacters();
    setState(() {
      _allCharacters = chars;
      _filterCharacters();
    });
  }

  void _filterCharacters() {
    final query = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredCharacters = List.from(_allCharacters);
      } else {
        _filteredCharacters = _allCharacters.where((c) {
          return c.name.toLowerCase().contains(query) ||
                 c.franchise.toLowerCase().contains(query);
        }).toList();
      }
      
      if (_selectedCharacter != null && !_filteredCharacters.any((c) => c.id == _selectedCharacter!.id)) {
        _selectCharacter(null);
      } else if (_selectedCharacter != null) {
        _selectedCharacter = _filteredCharacters.firstWhere((c) => c.id == _selectedCharacter!.id);
      }
    });
  }

  // --- NUEVO: LÓGICA DE AGRUPACIÓN POR FRANQUICIA ---
  Map<String, List<LocalCharacter>> get _groupedCharacters {
    final map = <String, List<LocalCharacter>>{};
    for (var c in _filteredCharacters) {
      final f = c.franchise.trim().isEmpty ? 'Sin Franquicia' : c.franchise.trim();
      map.putIfAbsent(f, () => []).add(c);
    }
    // Ordenar alfabéticamente las franquicias
    var sortedKeys = map.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return { for (var k in sortedKeys) k : map[k]! };
  }

  void _selectCharacter(LocalCharacter? char) {
    _hideContextMenu();
    setState(() {
      _selectedCharacter = char;
      _showExtraFields = false;
      _selectedImages.clear();
      _shiftSelectionAnchorIndex = null;
      _focusedIndex = -1;

      if (char != null) {
        _associatedImages = widget.metadataService.getImagesForCharacter(char.id!);
      } else {
        _associatedImages = [];
      }
    });
  }

  // --- LÓGICA DE SELECCIÓN DE IMÁGENES ---
  void _handleItemTap(String imageId, int index) {
    _hideContextMenu();

    final isShiftPressed = RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
                           RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftRight);

    final isCtrlPressed = RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.controlLeft) ||
                          RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.controlRight) ||
                          (Platform.isMacOS && (RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.metaLeft) ||
                                                RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.metaRight)));

    setState(() {
      _focusedIndex = index;
      if (isShiftPressed) {
        if (_shiftSelectionAnchorIndex == null) {
          _shiftSelectionAnchorIndex = index;
          _selectedImages = {imageId};
        } else {
          final start = index < _shiftSelectionAnchorIndex! ? index : _shiftSelectionAnchorIndex!;
          final end = index > _shiftSelectionAnchorIndex! ? index : _shiftSelectionAnchorIndex!;
          _selectedImages = _associatedImages.sublist(start, end + 1).toSet();
        }
      } else if (isCtrlPressed) {
        if (_selectedImages.contains(imageId)) {
          _selectedImages.remove(imageId);
        } else {
          _selectedImages.add(imageId);
        }
        _shiftSelectionAnchorIndex = index;
      } else {
        // Doble clic
        if (_doubleTapTimer != null && _doubleTapTimer!.isActive && _lastTappedImage == imageId) {
          _doubleTapTimer!.cancel();
          _lastTappedImage = null;
          _openImage(imageId);
        } else {
          _selectedImages = {imageId};
          _shiftSelectionAnchorIndex = index;

          _lastTappedImage = imageId;
          _doubleTapTimer?.cancel();
          _doubleTapTimer = Timer(const Duration(milliseconds: 300), () {
            _lastTappedImage = null;
          });
        }
      }
    });
  }

  void _openImage(String targetImageId) {
    if (_associatedImages.isEmpty) return;

    final imageFiles = _associatedImages
        .map((id) => File(p.join(widget.vaultRootPath, id)))
        .where((file) => file.existsSync()) 
        .toList();

    if (imageFiles.isEmpty) return;

    int initialIndex = imageFiles.indexWhere((f) => p.basename(f.path) == p.basename(targetImageId));
    if (initialIndex == -1) initialIndex = 0;

    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        opaque: false,
        pageBuilder: (context, _, __) => FullScreenImageViewer(
          imageFiles: imageFiles,
          initialIndex: initialIndex,
          exportCallback: (file) async => await _handleSingleExport(file),
          onClose: () => Navigator.pop(context),
          metadataService: widget.metadataService,
          vaultRootPath: widget.vaultRootPath,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
          final scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
          return FadeTransition(opacity: fadeAnimation, child: ScaleTransition(scale: scaleAnimation, child: child));
        }
      ),
    );
  }

  // --- MENÚ CONTEXTUAL Y ACCIONES ---
  void _hideContextMenu() {
    if (_contextMenuOverlay != null) {
      _contextMenuOverlay!.remove();
      _contextMenuOverlay = null;
    }
  }

  void _showContextMenu(BuildContext context, Offset position) {
    _hideContextMenu();
    final screenSize = MediaQuery.of(context).size;

    final isBottomHalf = position.dy > screenSize.height / 2;
    final isRightHalf = position.dx > screenSize.width / 2;

    final top = isBottomHalf ? null : position.dy;
    final bottom = isBottomHalf ? screenSize.height - position.dy : null;
    final left = isRightHalf ? null : position.dx;
    final right = isRightHalf ? screenSize.width - position.dx : null;

    final maxAvailableHeight = isBottomHalf
        ? position.dy - 16.0
        : screenSize.height - position.dy - 16.0;

    final items = <Widget>[
      if (_selectedImages.length == 1)
        _ProfileContextMenuItem(
          title: 'Renombrar',
          onTap: () {
            _hideContextMenu();
            _showRenameDialog(_selectedImages.first);
          },
          icon: Icons.drive_file_rename_outline,
        ),
      _ProfileContextMenuItem(
        title: 'Etiquetas',
        onTap: () {
          _hideContextMenu();
          showDialog(
            context: context,
            builder: (context) => TagEditorDialog(
              imageIds: _selectedImages.toList(),
              metadataService: widget.metadataService,
            ),
          ).then((_) => setState(() {}));
        },
        icon: Icons.label_outline,
      ),
      _ProfileContextMenuItem(
        title: 'Perfil',
        onTap: () {
          _hideContextMenu();
          showDialog(
            context: context,
            builder: (context) => ProfileEditorDialog(
              imageIds: _selectedImages.toList(),
              metadataService: widget.metadataService,
              vaultRootPath: widget.vaultRootPath,
            ),
          ).then((_) => setState(() {
             // Refrescamos por si el usuario desvincula la imagen desde el editor
             if (_selectedCharacter != null) {
               _associatedImages = widget.metadataService.getImagesForCharacter(_selectedCharacter!.id!);
               _selectedImages.removeWhere((id) => !_associatedImages.contains(id));
             }
          }));
        },
        icon: Icons.person_outline,
      ),
      _ProfileContextMenuItem(
        title: 'Calificación',
        onTap: () {
          _hideContextMenu();
          _showRatingMenu(context, position);
        },
        icon: Icons.star_outline,
      ),
      if (_selectedImages.length == 1)
        _ProfileContextMenuItem(
          title: 'Propiedades',
          onTap: () {
            _hideContextMenu();
            _showPropertiesDialog(_selectedImages.first);
          },
          icon: Icons.info_outline,
        ),
      const Divider(height: 1, thickness: 1),
      _ProfileContextMenuItem(
          title: 'Restaurar',
          onTap: _handleRestoreSelected,
          icon: Icons.restore),
      _ProfileContextMenuItem(
          title: 'Exportar',
          onTap: _handleExport,
          icon: Icons.download_for_offline_outlined),
      _ProfileContextMenuItem(
          title: 'Eliminar',
          onTap: _handleDelete,
          icon: Icons.delete_forever_outlined,
          isDestructive: true),
    ];

    if (items.isEmpty) return;

    _contextMenuOverlay = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  _hideContextMenu();
                  setState(() => _selectedImages.clear());
                },
                onSecondaryTap: () {
                  _hideContextMenu();
                  setState(() => _selectedImages.clear());
                },
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              top: top,
              bottom: bottom,
              left: left,
              right: right,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxAvailableHeight),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8.0),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Material(
                      elevation: 0,
                      color: const Color(0xFF252525).withOpacity(0.65),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8.0),
                        side: const BorderSide(color: Colors.white12, width: 0.5),
                      ),
                      child: IntrinsicWidth(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: items,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    Overlay.of(context).insert(_contextMenuOverlay!);
  }

  void _showRatingMenu(BuildContext context, Offset position) {
    final screenSize = MediaQuery.of(context).size;
    final isBottomHalf = position.dy > screenSize.height / 2;
    final isRightHalf = position.dx > screenSize.width / 2;
    final top = isBottomHalf ? null : position.dy;
    final bottom = isBottomHalf ? screenSize.height - position.dy : null;
    final left = isRightHalf ? null : position.dx;
    final right = isRightHalf ? screenSize.width - position.dx : null;
    final maxAvailableHeight = isBottomHalf ? position.dy - 16.0 : screenSize.height - position.dy - 16.0;

    int? currentRating;
    if (_selectedImages.isNotEmpty) {
      currentRating = widget.metadataService.getMetadataForImage(_selectedImages.first).rating;
      for (var id in _selectedImages.skip(1)) {
        if (widget.metadataService.getMetadataForImage(id).rating != currentRating) {
          currentRating = null;
          break;
        }
      }
    }

    final items = List.generate(6, (index) {
      final isSelected = index == currentRating;
      return InkWell(
        onTap: () {
          _hideContextMenu();
          for (final imageId in _selectedImages) {
            widget.metadataService.setRatingForImage(imageId, index);
          }
          setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            children: [
              Icon(isSelected ? Icons.check : null, size: 18, color: Colors.white),
              const SizedBox(width: 12),
              if (index == 0)
                const Text("Sin calificar", style: TextStyle(color: Colors.white))
              else
                RatingStarsDisplay(rating: index, iconSize: 20),
            ],
          ),
        ),
      );
    });

    _contextMenuOverlay = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _hideContextMenu,
                onSecondaryTap: _hideContextMenu,
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              top: top, bottom: bottom, left: left, right: right,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxAvailableHeight),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8.0),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Material(
                      elevation: 0,
                      color: const Color(0xFF252525).withOpacity(0.65),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8.0),
                        side: const BorderSide(color: Colors.white12, width: 0.5),
                      ),
                      child: IntrinsicWidth(
                        child: SingleChildScrollView(
                          child: Column(mainAxisSize: MainAxisSize.min, children: items),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    Overlay.of(context).insert(_contextMenuOverlay!);
  }

  // --- IMPLEMENTACIÓN DE ACCIONES ---
  Future<void> _handleDelete() async {
    _hideContextMenu();
    if (_selectedImages.isEmpty) return;
    final count = _selectedImages.length;
    final itemText = count == 1 ? 'el elemento seleccionado' : 'los $count elementos seleccionados';
    
    bool confirm = await _showConfirmationDialog(
          title: 'Confirmar Eliminación',
          content: '¿Estás seguro de que quieres eliminar $itemText permanentemente? Esta acción no se puede deshacer.',
        ) ?? false;
        
    if (!confirm) {
      setState(() => _selectedImages.clear());
      return;
    }

    for (final imageId in _selectedImages) {
      final file = File(p.join(widget.vaultRootPath, imageId));
      if (file.existsSync()) {
        await widget.metadataService.deleteMetadata(imageId);
        await widget.thumbnailService.clearThumbnail(p.basename(file.path));
        await file.delete();
      }
    }

    setState(() {
      _selectedImages.clear();
      if (_selectedCharacter != null) {
        _associatedImages = widget.metadataService.getImagesForCharacter(_selectedCharacter!.id!);
      }
    });
    if (mounted) showGlassSnackBar(context, '$count elemento(s) eliminado(s).', icon: Icons.delete_outline);
  }

  Future<void> _handleExport() async {
    _hideContextMenu();
    if (_selectedImages.isEmpty) return;

    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Seleccionar carpeta de exportación');
    if (selectedDirectory == null) return;
    
    final exportRootDir = Directory(selectedDirectory);

    for (final imageId in _selectedImages) {
      final file = File(p.join(widget.vaultRootPath, imageId));
      if (file.existsSync()) {
        final cleanName = _getDeobfuscatedName(p.basename(file.path));
        final newPath = await _getUniquePath(exportRootDir, cleanName);
        await file.copy(newPath);
      }
    }

    if (mounted) {
      showGlassSnackBar(context, '${_selectedImages.length} elemento(s) exportado(s) con éxito a ${exportRootDir.path}.', icon: Icons.download_done);
    }
    setState(() => _selectedImages.clear());
  }

  Future<void> _handleSingleExport(File file) async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Seleccionar carpeta de exportación');
    if (selectedDirectory == null) return;
    
    final exportRootDir = Directory(selectedDirectory);
    final cleanName = _getDeobfuscatedName(p.basename(file.path));
    final newPath = await _getUniquePath(exportRootDir, cleanName);

    try {
      await file.copy(newPath);
      if (mounted) showGlassSnackBar(context, 'Archivo exportado con éxito a ${exportRootDir.path}.', icon: Icons.download_done);
    } catch (e) {
      if (mounted) showGlassSnackBar(context, 'Error al exportar: $e', icon: Icons.error_outline, iconColor: Colors.redAccent);
    }
  }

  Future<void> _handleRestoreSelected() async {
    _hideContextMenu();
    if (_selectedImages.isEmpty) return;

    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Seleccionar carpeta para restaurar');
    if (selectedDirectory == null) return;
    
    final destinationDir = Directory(selectedDirectory);
    final count = _selectedImages.length;
    final itemText = count == 1 ? 'el elemento seleccionado' : 'los $count elementos seleccionados';
    
    bool confirm = await _showConfirmationDialog(
          title: 'Confirmar Restauración',
          content: '¿Deseas mover $itemText a la carpeta seleccionada y quitarlos de la bóveda?',
        ) ?? false;

    if (!confirm) {
      setState(() => _selectedImages.clear());
      return;
    }

    for (final imageId in _selectedImages) {
      final file = File(p.join(widget.vaultRootPath, imageId));
      if (file.existsSync()) {
        final cleanName = _getDeobfuscatedName(p.basename(file.path));
        final newPath = await _getUniquePath(destinationDir, cleanName);

        await widget.metadataService.deleteMetadata(imageId);
        await widget.thumbnailService.clearThumbnail(p.basename(file.path));
        await _moveFileRobustly(file, newPath);
      }
    }

    if (mounted) showGlassSnackBar(context, '$count elemento(s) restaurado(s) con éxito a ${destinationDir.path}.');
    setState(() {
      _selectedImages.clear();
      if (_selectedCharacter != null) {
        _associatedImages = widget.metadataService.getImagesForCharacter(_selectedCharacter!.id!);
      }
    });
  }

  Future<void> _showPropertiesDialog(String imageId) async {
    final file = File(p.join(widget.vaultRootPath, imageId));
    if (!file.existsSync()) return;

    String name = _getDeobfuscatedName(p.basename(file.path));
    final realExt = _getRealExtension(file.path).replaceAll('.', '').toUpperCase();
    String type = _isVideo(file.path) ? '$realExt (Video)' : '$realExt (Imagen)';
    
    String sizeStr = '--';
    String dateStr = 'Desconocido';
    String addedDateStr = '--';
    
    int rating = 0;
    List<String> tags = [];
    List<LocalCharacter> characterProfiles = []; 

    try {
      final stat = await file.stat();
      dateStr = "${stat.modified.day.toString().padLeft(2, '0')}/${stat.modified.month.toString().padLeft(2, '0')}/${stat.modified.year} ${stat.modified.hour.toString().padLeft(2, '0')}:${stat.modified.minute.toString().padLeft(2, '0')}";
      
      int bytes = stat.size;
      if (bytes < 1024) sizeStr = '$bytes B';
      else if (bytes < 1024 * 1024) sizeStr = '${(bytes / 1024).toStringAsFixed(2)} KB';
      else if (bytes < 1024 * 1024 * 1024) sizeStr = '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
      else sizeStr = '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';

      final metadata = widget.metadataService.getMetadataForImage(imageId);
      rating = metadata.rating;
      tags = metadata.tags;
      
      for (int id in metadata.characterIds) {
        final char = await widget.metadataService.getCharacterById(id);
        if (char != null) characterProfiles.add(char);
      }
      
      if (metadata.addedTimestamp > 0) {
        final addedDate = DateTime.fromMillisecondsSinceEpoch(metadata.addedTimestamp);
        addedDateStr = "${addedDate.day.toString().padLeft(2, '0')}/${addedDate.month.toString().padLeft(2, '0')}/${addedDate.year} ${addedDate.hour.toString().padLeft(2, '0')}:${addedDate.minute.toString().padLeft(2, '0')}";
      } else {
         addedDateStr = dateStr;
      }
    } catch(e) {
      debugPrint("Error leyendo propiedades: $e");
    }

    if (mounted) {
      showDialog(
        context: context,
        barrierColor: Colors.black.withOpacity(0.4),
        builder: (context) {
          bool isTagsExpanded = false;
          return StatefulBuilder(
            builder: (context, setState) {
              return Dialog(
                backgroundColor: Colors.transparent,
                elevation: 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14.0),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(
                      width: 380,
                      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF252525).withOpacity(0.65),
                        border: Border.all(color: Colors.white12, width: 0.5),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Center(child: Text('Propiedades', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white))),
                          const SizedBox(height: 20),
                          Flexible(
                            child: SingleChildScrollView(
                              physics: const BouncingScrollPhysics(),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildPropertyRow('Nombre:', name),
                                  _buildPropertyRow('Tipo:', type),
                                  _buildPropertyRow('Tamaño:', sizeStr),
                                  _buildPropertyRow('Modificado:', dateStr),
                                  
                                  const Divider(color: Colors.white12, height: 24, thickness: 1),
                                  const Text('Metadatos del Vórtice', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF0A84FF), fontSize: 13)),
                                  const SizedBox(height: 12),
                                  _buildPropertyRow('Añadido:', addedDateStr),
                                  _buildPropertyRow('Estrellas:', rating > 0 ? '$rating' : 'Sin calificar'),
                                  
                                  _buildTagsPropertyRow('Etiquetas:', tags, isTagsExpanded, () {
                                    setState(() { isTagsExpanded = !isTagsExpanded; });
                                  }),
                                  
                                  if (characterProfiles.isNotEmpty) ...[
                                    ...characterProfiles.map((charProfile) {
                                      return Padding(
                                        padding: const EdgeInsets.only(top: 16.0),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            const Divider(color: Colors.white12, height: 10, thickness: 0.5),
                                            Row(
                                              children: [
                                                const Icon(Icons.account_circle_outlined, size: 14, color: Color(0xFF32D74B)),
                                                const SizedBox(width: 6),
                                                Text('Perfil: ${charProfile.name}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF32D74B), fontSize: 13)),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            _buildPropertyRow('Franquicia:', charProfile.franchise),
                                            _buildPropertyRow('Género:', charProfile.gender),
                                            _buildPropertyRow('Edad:', charProfile.age),
                                            _buildPropertyRow('Cumpleaños:', charProfile.birthday),
                                            ...charProfile.customFields.entries.map((field) {
                                              return _buildPropertyRow('${field.key}:', field.value);
                                            }),
                                          ],
                                        ),
                                      );
                                    }),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Center(
                            child: TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              style: TextButton.styleFrom(foregroundColor: const Color(0xFF0A84FF)),
                              child: const Text('Aceptar', style: TextStyle(fontWeight: FontWeight.w600)),
                            ),
                          )
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }
          );
        },
      );
    }
  }

  Future<void> _showRenameDialog(String imageId) async {
    final file = File(p.join(widget.vaultRootPath, imageId));
    if (!file.existsSync()) return;

    String currentName = p.basename(file.path);
    currentName = _getDeobfuscatedName(currentName);
    currentName = p.basenameWithoutExtension(currentName);

    final TextEditingController renameController = TextEditingController(text: currentName);
    renameController.selection = TextSelection(baseOffset: 0, extentOffset: currentName.length);

    final bool? confirm = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14.0),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                width: 350,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF252525).withOpacity(0.65),
                  border: Border.all(color: Colors.white12, width: 0.5),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Renombrar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
                    const SizedBox(height: 16),
                    TextField(
                      controller: renameController,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      onSubmitted: (_) => Navigator.of(context).pop(true),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFF1C1C1E).withOpacity(0.8),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          style: TextButton.styleFrom(foregroundColor: Colors.white70),
                          child: const Text('Cancelar', style: TextStyle(fontWeight: FontWeight.w500)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          style: TextButton.styleFrom(foregroundColor: const Color(0xFF0A84FF)),
                          child: const Text('Guardar', style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ],
                    )
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (confirm == true && renameController.text.isNotEmpty && renameController.text.trim() != currentName) {
      final newNameInput = renameController.text.trim();
      final realExt = _getRealExtension(file.path);
      final nameWithExt = '$newNameInput$realExt';
      final finalNewName = _obfuscateName(nameWithExt);

      final destinationDir = Directory(p.dirname(file.path));
      final finalUniquePath = await _getUniquePath(destinationDir, finalNewName);

      try {
        final newId = p.relative(finalUniquePath, from: widget.vaultRootPath);

        await widget.thumbnailService.renameThumbnail(file.path, finalUniquePath);
        await _moveFileRobustly(file, finalUniquePath);
        await widget.metadataService.updateImagePath(imageId, newId);

        setState(() {
          _selectedImages.clear();
          if (_selectedCharacter != null) {
            _associatedImages = widget.metadataService.getImagesForCharacter(_selectedCharacter!.id!);
          }
        });
      } catch (e) {
        if (mounted) showGlassSnackBar(context, 'Error al renombrar: $e', icon: Icons.error_outline, iconColor: Colors.redAccent);
      }
    }
  }

  Future<bool?> _showConfirmationDialog({required String title, required String content}) {
    return showDialog<bool>(
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
              width: 350,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF252525).withOpacity(0.65), 
                border: Border.all(color: Colors.white12, width: 0.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white), textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(content, style: const TextStyle(fontSize: 14, color: Colors.white70), textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: TextButton.styleFrom(foregroundColor: Colors.white70),
                        child: const Text('Cancelar', style: TextStyle(fontWeight: FontWeight.w500)),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFF0A84FF)), 
                        child: const Text('Aceptar', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPropertyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 85, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white54, fontSize: 13))),
          Expanded(child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildTagsPropertyRow(String label, List<String> tags, bool isExpanded, VoidCallback onToggle) {
    if (tags.isEmpty) return _buildPropertyRow(label, 'Ninguna');

    final displayTags = isExpanded ? tags : tags.take(3).toList();
    final hiddenCount = tags.length - 3;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 85, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white54, fontSize: 13))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayTags.join(', '), style: const TextStyle(color: Colors.white, fontSize: 13)),
                if (!isExpanded && hiddenCount > 0)
                  InkWell(
                    onTap: onToggle,
                    child: Padding(padding: const EdgeInsets.only(top: 4.0), child: Text('Ver $hiddenCount más...', style: const TextStyle(color: Color(0xFF0A84FF), fontSize: 12, fontWeight: FontWeight.w500))),
                  ),
                if (isExpanded && tags.length > 3)
                  InkWell(
                    onTap: onToggle,
                    child: const Padding(padding: const EdgeInsets.only(top: 4.0), child: Text('Ocultar', style: TextStyle(color: Color(0xFF0A84FF), fontSize: 12, fontWeight: FontWeight.w500))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- MÉTODOS DE EDICIÓN DE PERSONAJES EXISTENTES (Panel principal) ---
  Future<void> _deleteCharacter(LocalCharacter char) async {
    final bool confirm = await showDialog<bool>(
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
                  const Text('Eliminar Perfil', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
                  const SizedBox(height: 16),
                  Text(
                    '¿Borrar a "${char.name}"?\nSe desvinculará de todas las imágenes.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar', style: TextStyle(color: Colors.white70))),
                      TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Eliminar', style: TextStyle(color: Colors.redAccent))),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ) ?? false;

    if (confirm) {
      await widget.metadataService.deleteCharacter(char.id!);
      _selectCharacter(null);
      await _loadCharacters();
      if (mounted) showGlassSnackBar(context, 'Perfil eliminado.', icon: Icons.delete_outline);
    }
  }

  void _editCharacter(LocalCharacter char) async {
    final updated = await showDialog<LocalCharacter>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _GlobalCharacterEditDialog(
        character: char,
        metadataService: widget.metadataService,
      ),
    );

    if (updated != null) {
      await widget.metadataService.updateCharacter(updated);
      await _loadCharacters();
      if (mounted) showGlassSnackBar(context, 'Perfil actualizado.', icon: Icons.save);
    }
  }

  // --- WIDGET AUXILIAR PARA LA LISTA ---
  Widget _buildCharacterTile(LocalCharacter char, bool isSelected, {bool isGrouped = false}) {
    return ListTile(
      contentPadding: EdgeInsets.only(left: isGrouped ? 32 : 16, right: 16),
      selected: isSelected,
      selectedTileColor: const Color(0xFF0A84FF).withOpacity(0.15),
      leading: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black26,
          border: Border.all(color: isSelected ? const Color(0xFF0A84FF) : Colors.white24),
          image: char.avatarPath != null && File(char.avatarPath!).existsSync()
              ? DecorationImage(image: FileImage(File(char.avatarPath!)), fit: BoxFit.cover)
              : null,
        ),
        child: char.avatarPath == null ? const Icon(Icons.person, color: Colors.white38, size: 20) : null,
      ),
      title: Text(char.name, style: const TextStyle(fontSize: 13, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: isGrouped ? null : Text(char.franchise, style: const TextStyle(fontSize: 11, color: Colors.white54), maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _selectCharacter(char),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        title: const Text('Administración de Perfiles', style: TextStyle(fontSize: 15)),
        backgroundColor: const Color(0xE61C1C1E),
        elevation: 0,
      ),
      body: Row(
        children: [
          // --- PANEL IZQUIERDO: LISTA DE PERSONAJES / FRANQUICIAS ---
          Container(
            width: 320,
            decoration: const BoxDecoration(
              color: Color(0xFF151515),
              border: Border(right: BorderSide(color: Colors.white12, width: 1)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 16.0, bottom: 8.0),
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1C1C1E),
                      prefixIcon: const Icon(Icons.search, color: Colors.white54, size: 18),
                      suffixIcon: _searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.cancel, color: Colors.white54, size: 16),
                              onPressed: () => _searchCtrl.clear(),
                            )
                          : null,
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      hintText: 'Buscar...',
                      hintStyle: const TextStyle(color: Colors.white54),
                    ),
                  ),
                ),
                
                // --- NUEVO: INTERRUPTOR (TOGGLE) PERSONAJES / FRANQUICIAS ---
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _groupByFranchise = false),
                            child: Container(
                              decoration: BoxDecoration(
                                color: !_groupByFranchise ? const Color(0xFF0A84FF).withOpacity(0.2) : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: !_groupByFranchise ? const Color(0xFF0A84FF) : Colors.transparent,
                                  width: 1,
                                )
                              ),
                              alignment: Alignment.center,
                              child: Text('Personajes', style: TextStyle(fontSize: 12, color: !_groupByFranchise ? const Color(0xFF0A84FF) : Colors.white54, fontWeight: !_groupByFranchise ? FontWeight.bold : FontWeight.normal)),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _groupByFranchise = true),
                            child: Container(
                              decoration: BoxDecoration(
                                color: _groupByFranchise ? const Color(0xFF0A84FF).withOpacity(0.2) : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: _groupByFranchise ? const Color(0xFF0A84FF) : Colors.transparent,
                                  width: 1,
                                )
                              ),
                              alignment: Alignment.center,
                              child: Text('Franquicias', style: TextStyle(fontSize: 12, color: _groupByFranchise ? const Color(0xFF0A84FF) : Colors.white54, fontWeight: _groupByFranchise ? FontWeight.bold : FontWeight.normal)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // --- LISTADO EXPANDIDO O PLANO ---
                Expanded(
                  child: _filteredCharacters.isEmpty
                      ? const Center(child: Text('No hay perfiles.', style: TextStyle(color: Colors.white54)))
                      : (!_groupByFranchise) 
                          // VISTA PLANA ORIGINAL
                          ? ListView.separated(
                              physics: const BouncingScrollPhysics(),
                              itemCount: _filteredCharacters.length,
                              separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16, color: Colors.white12),
                              itemBuilder: (context, index) {
                                final char = _filteredCharacters[index];
                                final isSelected = _selectedCharacter?.id == char.id;
                                return _buildCharacterTile(char, isSelected, isGrouped: false);
                              },
                            )
                          // VISTA AGRUPADA POR FRANQUICIAS
                          : ListView.builder(
                              physics: const BouncingScrollPhysics(),
                              itemCount: _groupedCharacters.keys.length,
                              itemBuilder: (context, index) {
                                final franchise = _groupedCharacters.keys.elementAt(index);
                                final chars = _groupedCharacters[franchise]!;
                                final bool isSearchActive = _searchCtrl.text.isNotEmpty;
                                
                                return Theme(
                                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                                  child: ExpansionTile(
                                    key: PageStorageKey('franchise_$franchise'), 
                                    initiallyExpanded: isSearchActive, 
                                    iconColor: const Color(0xFF0A84FF),
                                    collapsedIconColor: Colors.white54,
                                    leading: const Icon(Icons.folder_special_outlined, size: 22),
                                    title: Text(franchise, style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.bold)),
                                    subtitle: Text('${chars.length} perfil(es)', style: const TextStyle(fontSize: 11, color: Colors.white54)),
                                    children: chars.map((char) {
                                      final isSelected = _selectedCharacter?.id == char.id;
                                      return _buildCharacterTile(char, isSelected, isGrouped: true);
                                    }).toList(),
                                  ),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),

          // --- PANEL DERECHO: DETALLES E IMÁGENES ---
          Expanded(
            child: _selectedCharacter == null
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.badge_outlined, size: 80, color: Colors.white12),
                        SizedBox(height: 16),
                        Text('Selecciona un perfil para ver sus detalles', style: TextStyle(color: Colors.white38, fontSize: 16)),
                      ],
                    ),
                  )
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _hideContextMenu();
                      setState(() {
                        _selectedImages.clear();
                        _shiftSelectionAnchorIndex = null;
                      });
                    },
                    child: CustomScrollView(
                        physics: const BouncingScrollPhysics(),
                        slivers: [
                          SliverToBoxAdapter(
                            child: Container(
                              padding: const EdgeInsets.all(32),
                              decoration: const BoxDecoration(
                                color: Color(0xFF1A1A1C),
                                border: Border(bottom: BorderSide(color: Colors.white12, width: 1)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 100, height: 100,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.black45,
                                      border: Border.all(color: const Color(0xFF0A84FF), width: 2),
                                      image: _selectedCharacter!.avatarPath != null && File(_selectedCharacter!.avatarPath!).existsSync()
                                          ? DecorationImage(image: FileImage(File(_selectedCharacter!.avatarPath!)), fit: BoxFit.cover)
                                          : null,
                                    ),
                                    child: _selectedCharacter!.avatarPath == null ? const Icon(Icons.person, color: Colors.white38, size: 50) : null,
                                  ),
                                  const SizedBox(width: 24),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                _selectedCharacter!.name,
                                                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                                              ),
                                            ),
                                            Tooltip(
                                              message: 'Editar Perfil',
                                              child: InkWell(
                                                borderRadius: BorderRadius.circular(8),
                                                onTap: () => _editCharacter(_selectedCharacter!),
                                                hoverColor: Colors.white12,
                                                child: const Padding(
                                                  padding: EdgeInsets.all(8.0),
                                                  child: Icon(Icons.edit_note_rounded, color: Colors.white54, size: 22),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Tooltip(
                                              message: 'Eliminar Perfil',
                                              child: InkWell(
                                                borderRadius: BorderRadius.circular(8),
                                                onTap: () => _deleteCharacter(_selectedCharacter!),
                                                hoverColor: Colors.redAccent.withOpacity(0.2),
                                                child: const Padding(
                                                  padding: EdgeInsets.all(8.0),
                                                  child: Icon(Icons.delete_outline, color: Colors.white54, size: 22),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(_selectedCharacter!.franchise, style: const TextStyle(fontSize: 16, color: Color(0xFF0A84FF), fontWeight: FontWeight.w500)),
                                        const SizedBox(height: 16),
                                        
                                        Wrap(
                                          spacing: 24, runSpacing: 12,
                                          children: [
                                            _buildAttribute(Icons.wc, 'Género', _selectedCharacter!.gender),
                                            _buildAttribute(Icons.cake_outlined, 'Edad', _selectedCharacter!.age),
                                            _buildAttribute(Icons.calendar_month_outlined, 'Cumpleaños', _selectedCharacter!.birthday),
                                          ],
                                        ),
                                        if (_selectedCharacter!.customFields.isNotEmpty) ...[
                                          const SizedBox(height: 12),
                                          InkWell(
                                            borderRadius: BorderRadius.circular(6),
                                            onTap: () {
                                              setState(() => _showExtraFields = !_showExtraFields);
                                            },
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 2.0),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    _showExtraFields ? 'Mostrar menos' : 'Mostrar más (${_selectedCharacter!.customFields.length})',
                                                    style: const TextStyle(color: Color(0xFF0A84FF), fontSize: 13, fontWeight: FontWeight.bold),
                                                  ),
                                                  Icon(
                                                    _showExtraFields ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, 
                                                    color: const Color(0xFF0A84FF), 
                                                    size: 16
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          if (_showExtraFields)
                                            Padding(
                                              padding: const EdgeInsets.only(top: 12.0),
                                              child: Wrap(
                                                spacing: 24, runSpacing: 12,
                                                children: _selectedCharacter!.customFields.entries.map((e) => _buildAttribute(Icons.info_outline, e.key, e.value)).toList(),
                                              ),
                                            ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(24.0),
                              child: Text(
                                'Apariciones en la Bóveda (${_associatedImages.length})', 
                                style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)
                              ),
                            ),
                          ),

                          _associatedImages.isEmpty
                              ? const SliverToBoxAdapter(
                                  child: Padding(
                                    padding: EdgeInsets.all(24.0),
                                    child: Center(child: Text('Este perfil no está etiquetado en ninguna imagen.', style: TextStyle(color: Colors.white38))),
                                  ),
                                )
                              : SliverPadding(
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 0),
                                  sliver: SliverGrid(
                                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 180, // Tamaño de las miniaturas
                                      mainAxisSpacing: 12,
                                      crossAxisSpacing: 12,
                                      childAspectRatio: 1,
                                    ),
                                    delegate: SliverChildBuilderDelegate(
                                      (context, index) {
                                        final imageId = _associatedImages[index];
                                        final file = File(p.join(widget.vaultRootPath, imageId));
                                        final isSelected = _selectedImages.contains(imageId);

                                        return ImageItemWidget(
                                          imageFile: file,
                                          imageId: imageId,
                                          isSelected: isSelected,
                                          extent: 180.0,
                                          metadataService: widget.metadataService,
                                          thumbnailService: widget.thumbnailService,
                                          showRatings: true,
                                          showTagsCount: true,
                                          onTap: () => _handleItemTap(imageId, index),
                                          onSecondaryTapUp: (details) {
                                            _hideContextMenu();
                                            if (!_selectedImages.contains(imageId)) {
                                              setState(() => _selectedImages = {imageId});
                                              _shiftSelectionAnchorIndex = index;
                                            }
                                            _showContextMenu(context, details.globalPosition);
                                          },
                                        );
                                      },
                                      childCount: _associatedImages.length,
                                    ),
                                  ),
                                ),
                          const SliverToBoxAdapter(child: SizedBox(height: 32)),
                        ],
                      ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttribute(IconData icon, String label, String value) {
    if (value.isEmpty || value == 'Desconocido' || value == 'Desconocida') return const SizedBox.shrink();
    
    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: 6.0, bottom: 1.0),
              child: Icon(icon, color: Colors.white38, size: 16),
            ),
          ),
          TextSpan(
            text: '$label: ', 
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
          TextSpan(
            text: value, 
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

// --- WIDGET PARA LOS ITEMS DEL MENÚ CONTEXTUAL ---
class _ProfileContextMenuItem extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final bool isDestructive;

  const _ProfileContextMenuItem({
    required this.title,
    required this.icon,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? Colors.redAccent : null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Text(title, style: TextStyle(color: color)),
          ],
        ),
      ),
    );
  }
}

// --- MINIDIÁLOGO DE EDICIÓN EXCLUSIVO PARA ESTA PANTALLA ---
class _GlobalCharacterEditDialog extends StatefulWidget {
  final LocalCharacter character;
  final MetadataService metadataService;

  const _GlobalCharacterEditDialog({required this.character, required this.metadataService});

  @override
  State<_GlobalCharacterEditDialog> createState() => _GlobalCharacterEditDialogState();
}

class _GlobalCharacterEditDialogState extends State<_GlobalCharacterEditDialog> {
  late TextEditingController _nameCtrl;
  late TextEditingController _franchiseCtrl;
  late TextEditingController _genderCtrl;
  late TextEditingController _ageCtrl;
  late TextEditingController _birthdayCtrl;
  final List<TextEditingController> _customKeysCtrls = [];
  final List<TextEditingController> _customValuesCtrls = [];

  final ScrollController _editScrollController = ScrollController();

  void _scrollToBottomEdit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_editScrollController.hasClients) {
        _editScrollController.animateTo(
          _editScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.character.name);
    _franchiseCtrl = TextEditingController(text: widget.character.franchise);
    _genderCtrl = TextEditingController(text: widget.character.gender);
    _ageCtrl = TextEditingController(text: widget.character.age);
    _birthdayCtrl = TextEditingController(text: widget.character.birthday);
    
    widget.character.customFields.forEach((k, v) {
      _customKeysCtrls.add(TextEditingController(text: k));
      _customValuesCtrls.add(TextEditingController(text: v));
    });
  }

  @override
  void dispose() {
    _editScrollController.dispose();
    _nameCtrl.dispose(); _franchiseCtrl.dispose(); _genderCtrl.dispose();
    _ageCtrl.dispose(); _birthdayCtrl.dispose();
    for (var c in _customKeysCtrls) { c.dispose(); }
    for (var c in _customValuesCtrls) { c.dispose(); }
    super.dispose();
  }

  void _save() {
    Map<String, String> customs = {};
    for (int i = 0; i < _customKeysCtrls.length; i++) {
      final k = _customKeysCtrls[i].text.trim();
      final v = _customValuesCtrls[i].text.trim();
      if (k.isNotEmpty && v.isNotEmpty) customs[k] = v;
    }

    final updated = LocalCharacter(
      id: widget.character.id,
      name: _nameCtrl.text.trim(),
      franchise: _franchiseCtrl.text.trim(),
      gender: _genderCtrl.text.trim(),
      age: _ageCtrl.text.trim(),
      birthday: _birthdayCtrl.text.trim(),
      avatarPath: widget.character.avatarPath, 
      customFields: customs,
    );

    Navigator.pop(context, updated);
  }

  Widget _buildField(String label, TextEditingController ctrl) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6.0, left: 2.0),
            child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500)),
          ),
          TextField(
            controller: ctrl,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.black26,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16.0),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: 440,
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E).withOpacity(0.9),
              border: Border.all(color: Colors.white12, width: 0.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min, 
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Modificar Perfil', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 20),
                Flexible(
                  child: SingleChildScrollView(
                    controller: _editScrollController,
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildField('Nombre *', _nameCtrl),
                        _buildField('Franquicia *', _franchiseCtrl),
                        Row(
                          children: [
                            Expanded(child: _buildField('Género', _genderCtrl)),
                            const SizedBox(width: 12),
                            Expanded(child: _buildField('Edad', _ageCtrl)),
                          ],
                        ),
                        _buildField('Cumpleaños', _birthdayCtrl),
                        
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8.0),
                          child: Divider(color: Colors.white12, height: 1),
                        ),
                        
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Campos Extra', style: TextStyle(fontSize: 13, color: Colors.white54, fontWeight: FontWeight.bold)),
                            TextButton.icon(
                              onPressed: () {
                                setState(() { 
                                  _customKeysCtrls.add(TextEditingController()); 
                                  _customValuesCtrls.add(TextEditingController()); 
                                });
                                _scrollToBottomEdit();
                              }, 
                              icon: const Icon(Icons.add, size: 14), 
                              label: const Text('Añadir', style: TextStyle(fontSize: 12))
                            )
                          ],
                        ),
                        const SizedBox(height: 4),
                        
                        ...List.generate(_customKeysCtrls.length, (idx) => Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _buildField('Propiedad', _customKeysCtrls[idx])),
                              const SizedBox(width: 8),
                              Expanded(child: _buildField('Valor', _customValuesCtrls[idx])),
                              Padding(
                                padding: const EdgeInsets.only(top: 24.0, left: 4.0), 
                                child: IconButton(
                                  icon: const Icon(Icons.remove_circle, color: Colors.redAccent, size: 20), 
                                  tooltip: 'Eliminar campo',
                                  onPressed: () => setState(() { 
                                    _customKeysCtrls.removeAt(idx).dispose(); 
                                    _customValuesCtrls.removeAt(idx).dispose(); 
                                  })
                                ),
                              )
                            ],
                          ),
                        )),
                        if (_customKeysCtrls.isNotEmpty)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () {
                                setState(() { 
                                  _customKeysCtrls.add(TextEditingController()); 
                                  _customValuesCtrls.add(TextEditingController()); 
                                });
                                _scrollToBottomEdit();
                              }, 
                              icon: const Icon(Icons.add, size: 12), 
                              label: const Text('Añadir otro campo', style: TextStyle(fontSize: 11))
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar', style: TextStyle(color: Colors.white70))),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0A84FF), 
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Guardar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// FUNCIONES AUXILIARES NECESARIAS PARA QUE EL MENÚ CONTEXTUAL Y LAS ACCIONES FUNCIONEN
// ============================================================================

String _cipherExtension(String ext) {
  String result = '';
  for (int i = 0; i < ext.length; i++) {
    String char = ext[i].toLowerCase();
    if (char == '.') {
      result += '0';
    } else if (RegExp(r'[a-z]').hasMatch(char)) {
      int charCode = char.codeUnitAt(0);
      int nextCode = charCode == 122 ? 97 : charCode + 1; 
      result += String.fromCharCode(nextCode);
    } else {
      result += char; 
    }
  }
  return result;
}

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

String _obfuscateName(String originalName) {
  if (originalName.toLowerCase().endsWith('.vtx')) return originalName;
  final ext = p.extension(originalName); 
  final base = p.basenameWithoutExtension(originalName); 
  final cipheredExt = _cipherExtension(ext); 
  return '$base$cipheredExt.vtx';
}

String _getDeobfuscatedName(String filename) {
  if (filename.toLowerCase().endsWith('.vtx')) {
    final base = p.basenameWithoutExtension(filename); 
    final lastZero = base.lastIndexOf('0'); 

    if (lastZero != -1) {
      final realBase = base.substring(0, lastZero); 
      final realExt = _decipherExtension(base.substring(lastZero)); 
      return '$realBase$realExt';
    }
    return base;
  }
  return filename;
}

String _getRealExtension(String filename) {
  if (filename.toLowerCase().endsWith('.vtx')) {
    final base = p.basenameWithoutExtension(filename);
    final lastZero = base.lastIndexOf('0');
    if (lastZero != -1) {
      return _decipherExtension(base.substring(lastZero));
    }
  }
  return p.extension(filename).toLowerCase();
}

bool _isVideo(String filePath) {
  final ext = _getRealExtension(filePath);
  return ['.mp4', '.mov', '.avi', '.mkv', '.webm'].contains(ext);
}

Future<String> _getUniquePath(Directory destinationDir, String fileName) async {
  bool isVtx = fileName.toLowerCase().endsWith('.vtx');
  String baseName = p.basenameWithoutExtension(fileName);
  String extension = p.extension(fileName);
  String newPath = p.join(destinationDir.path, fileName);
  int counter = 1;

  while (await File(newPath).exists() || await Directory(newPath).exists()) {
    if (isVtx) {
      final lastZero = baseName.lastIndexOf('0');
      if (lastZero != -1) {
        final realBase = baseName.substring(0, lastZero);
        final cipheredExt = baseName.substring(lastZero);
        fileName = '$realBase ($counter)$cipheredExt$extension';
      } else {
        fileName = '$baseName ($counter)$extension';
      }
    } else {
      fileName = '$baseName ($counter)$extension';
    }
    newPath = p.join(destinationDir.path, fileName);
    counter++;
  }
  return newPath;
}

Future<void> _moveFileRobustly(File sourceFile, String newPath) async {
  int retries = 4;
  while (retries > 0) {
    try {
      await sourceFile.rename(newPath);
      return; 
    } catch (e) {
      try {
        final newFile = await sourceFile.copy(newPath);
        if (await newFile.exists()) {
          final sourceSize = await sourceFile.length();
          final newSize = await newFile.length();
          
          if (sourceSize == newSize) {
            await sourceFile.delete();
            return; 
          } else {
            await newFile.delete(); 
            throw Exception("La copia falló la prueba de integridad.");
          }
        }
      } catch (copyDeleteError) {
        retries--;
        if (retries == 0) {
          if (await File(newPath).exists()) await File(newPath).delete();
          throw Exception("El archivo está bloqueado o dañado: $copyDeleteError");
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
  }
}