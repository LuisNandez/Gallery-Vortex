import 'dart:io';
import 'dart:ui';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'metadata_service.dart';
import 'thumbnail_service.dart';
import 'main.dart';
import 'ui_utils.dart';
import 'tag_editor_dialog.dart';
import 'rating_stars_display.dart';
import 'profile_editor_dialog.dart';
import 'character_tag_matcher.dart';
import 'reorderable_fields_list.dart';
import 'dart:typed_data';

// Cuántas sugerencias se dibujan de golpe (el resto con "Mostrar más").
const int _kSuggestionsPageSize = 24;

// Claves de preferencias de esta pantalla.
const String _kPrefProfileSort = 'pm_profile_sort';
const String _kPrefImageSort = 'pm_image_sort';
const String _kPrefGroup = 'pm_group_franchise';
const String _kPrefThumb = 'pm_thumb_extent';
const String _kPrefDismissed = 'pm_dismissed_';

enum _ProfileSort { nameAsc, nameDesc, mostImages, fewestImages }

enum _ImageSort { recent, oldest, ratingDesc, nameAsc }

const Map<_ProfileSort, String> _profileSortLabels = {
  _ProfileSort.nameAsc: 'Nombre (A → Z)',
  _ProfileSort.nameDesc: 'Nombre (Z → A)',
  _ProfileSort.mostImages: 'Más imágenes',
  _ProfileSort.fewestImages: 'Menos imágenes',
};

const Map<_ImageSort, String> _imageSortLabels = {
  _ImageSort.recent: 'Más recientes',
  _ImageSort.oldest: 'Más antiguas',
  _ImageSort.ratingDesc: 'Mejor calificadas',
  _ImageSort.nameAsc: 'Nombre (A → Z)',
};

const Set<String> _unknownValues = {
  '',
  'desconocido',
  'desconocida',
  'sin franquicia',
  'unknown',
  'n/a',
};

bool _isUnknownValue(String v) =>
    _unknownValues.contains(normalizeForSearch(v.trim()));

LocalCharacter _cloneCharacter(LocalCharacter c, {String? avatarPath}) {
  return LocalCharacter(
    id: c.id,
    name: c.name,
    franchise: c.franchise,
    gender: c.gender,
    age: c.age,
    birthday: c.birthday,
    avatarPath: avatarPath ?? c.avatarPath,
    customFields: Map<String, String>.from(c.customFields),
  );
}

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
  State<ProfileManagementScreen> createState() =>
      _ProfileManagementScreenState();
}

class _ProfileManagementScreenState extends State<ProfileManagementScreen> {
  List<LocalCharacter> _allCharacters = [];
  List<LocalCharacter> _filteredCharacters = [];
  LocalCharacter? _selectedCharacter;
  List<String> _associatedImages = [];
  bool _showExtraFields = false;

  // --- SUGERENCIAS: imágenes con etiqueta de personaje parecida al perfil ---
  List<CharacterSuggestion> _suggestions = [];
  bool _showSuggestions = true;
  int _suggestionsVisible = _kSuggestionsPageSize;

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

  // --- ORDEN, FILTROS Y PREFERENCIAS ---
  Map<int, int> _imageCounts = {}; // id de perfil -> nº de imágenes
  _ProfileSort _profileSort = _ProfileSort.nameAsc;
  _ImageSort _imageSort = _ImageSort.recent;
  bool _onlyEmpty = false;
  double _thumbExtent = 180;
  SharedPreferences? _prefs;

  // Sugerencias descartadas por el usuario (id de perfil -> ids de imagen).
  Map<int, Set<String>> _dismissed = {};

  // Perfiles que podrían ser el mismo que el seleccionado.
  List<LocalCharacter> _duplicateCandidates = [];

  // --- TECLADO ---
  final FocusNode _screenFocus = FocusNode();
  late final FocusNode _searchFocus = FocusNode(onKeyEvent: _handleSearchKey);
  final Map<String, GlobalKey> _tileKeys = {};

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadCharacters();
    _searchCtrl.addListener(_filterCharacters);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _screenFocus.dispose();
    _doubleTapTimer?.cancel();
    _hideContextMenu();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    final dismissed = <int, Set<String>>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_kPrefDismissed)) continue;
      final id = int.tryParse(key.substring(_kPrefDismissed.length));
      final list = prefs.getStringList(key);
      if (id != null && list != null) dismissed[id] = list.toSet();
    }

    if (!mounted) return;
    setState(() {
      _groupByFranchise = prefs.getBool(_kPrefGroup) ?? false;
      final s = (prefs.getInt(_kPrefProfileSort) ?? 0)
          .clamp(0, _ProfileSort.values.length - 1)
          .toInt();
      _profileSort = _ProfileSort.values[s];
      final i = (prefs.getInt(_kPrefImageSort) ?? 0)
          .clamp(0, _ImageSort.values.length - 1)
          .toInt();
      _imageSort = _ImageSort.values[i];
      _thumbExtent =
          (prefs.getDouble(_kPrefThumb) ?? 180).clamp(110.0, 280.0).toDouble();
      _dismissed = dismissed;
      _applyFilter();
      final id = _selectedCharacter?.id;
      if (id != null) _associatedImages = _loadAssociatedImages(id);
      _refreshSuggestions();
    });
  }

  Future<void> _loadCharacters() async {
    final chars = await widget.metadataService.getAllCharacters();
    if (!mounted) return;
    setState(() {
      _allCharacters = chars;
      _imageCounts = widget.metadataService.getCharacterImageCounts();
      _applyFilter();
      _refreshDuplicates();
    });
  }

  void _filterCharacters() => setState(_applyFilter);

  // Aplica búsqueda + filtro + orden. Debe llamarse dentro de un setState.
  void _applyFilter() {
    // normalizeForSearch quita acentos y pasa a minúsculas, así "pokemon"
    // (sin acento) encuentra personajes guardados como "Pokémon".
    final query = normalizeForSearch(_searchCtrl.text.trim());
    Iterable<LocalCharacter> list = _allCharacters;
    if (query.isNotEmpty) {
      list = list.where((c) =>
          normalizeForSearch(c.name).contains(query) ||
          normalizeForSearch(c.franchise).contains(query));
    }
    if (_onlyEmpty) {
      list = list.where((c) => (_imageCounts[c.id] ?? 0) == 0);
    }
    final result = list.toList();

    int byName(LocalCharacter a, LocalCharacter b) =>
        normalizeForSearch(a.name).compareTo(normalizeForSearch(b.name));
    int count(LocalCharacter c) => _imageCounts[c.id] ?? 0;

    switch (_profileSort) {
      case _ProfileSort.nameAsc:
        result.sort(byName);
        break;
      case _ProfileSort.nameDesc:
        result.sort((a, b) => byName(b, a));
        break;
      case _ProfileSort.mostImages:
        result.sort((a, b) {
          final c = count(b).compareTo(count(a));
          return c != 0 ? c : byName(a, b);
        });
        break;
      case _ProfileSort.fewestImages:
        result.sort((a, b) {
          final c = count(a).compareTo(count(b));
          return c != 0 ? c : byName(a, b);
        });
        break;
    }
    _filteredCharacters = result;

    final selectedId = _selectedCharacter?.id;
    if (_selectedCharacter != null) {
      final idx = _filteredCharacters.indexWhere((c) => c.id == selectedId);
      if (idx == -1) {
        _applySelection(null);
      } else {
        _selectedCharacter = _filteredCharacters[idx];
      }
    }
  }

  // --- NUEVO: LÓGICA DE AGRUPACIÓN POR FRANQUICIA ---
  Map<String, List<LocalCharacter>> get _groupedCharacters {
    final map = <String, List<LocalCharacter>>{};
    for (var c in _filteredCharacters) {
      final f =
          c.franchise.trim().isEmpty ? 'Sin Franquicia' : c.franchise.trim();
      map.putIfAbsent(f, () => []).add(c);
    }
    // Ordenar alfabéticamente las franquicias
    var sortedKeys = map.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return {for (var k in sortedKeys) k: map[k]!};
  }

  // ---------------------------------------------------------------------
  // SELECCIÓN DE PERFIL
  // ---------------------------------------------------------------------

  void _selectCharacter(LocalCharacter? char) {
    _hideContextMenu();
    setState(() => _applySelection(char));
  }

  // Cambia la selección sin setState (para usarla dentro de uno).
  void _applySelection(LocalCharacter? char) {
    _selectedCharacter = char;
    _showExtraFields = false;
    _selectedImages.clear();
    _shiftSelectionAnchorIndex = null;
    _focusedIndex = -1;
    final id = char?.id;
    _associatedImages = id != null ? _loadAssociatedImages(id) : <String>[];
    _suggestionsVisible = _kSuggestionsPageSize;
    _refreshSuggestions();
    _refreshDuplicates();
  }

  /// Imágenes vinculadas al perfil, ya ordenadas según [_imageSort].
  /// También refresca los contadores de la lista de perfiles.
  List<String> _loadAssociatedImages(int characterId) {
    final svc = widget.metadataService;
    final ids = svc.getImagesForCharacter(characterId);
    _imageCounts = svc.getCharacterImageCounts();

    int tie(int c, String a, String b) => c != 0 ? c : a.compareTo(b);
    int stamp(String id) => svc.getMetadataForImage(id).addedTimestamp;
    int rating(String id) => svc.getMetadataForImage(id).rating;
    String name(String id) =>
        _getDeobfuscatedName(p.basename(id)).toLowerCase();

    switch (_imageSort) {
      case _ImageSort.recent:
        ids.sort((a, b) => tie(stamp(b).compareTo(stamp(a)), a, b));
        break;
      case _ImageSort.oldest:
        ids.sort((a, b) => tie(stamp(a).compareTo(stamp(b)), a, b));
        break;
      case _ImageSort.ratingDesc:
        ids.sort((a, b) => tie(rating(b).compareTo(rating(a)), a, b));
        break;
      case _ImageSort.nameAsc:
        ids.sort((a, b) => tie(name(a).compareTo(name(b)), a, b));
        break;
    }
    return ids;
  }

  // Busca perfiles que probablemente sean el mismo que el seleccionado
  // (mismo nombre con palabras en otro orden, mismo nombre y franquicia
  // parecida...). Reutiliza el comparador de etiquetas de WD14.
  void _refreshDuplicates() {
    final char = _selectedCharacter;
    if (char == null) {
      _duplicateCandidates = [];
      return;
    }
    final matcher =
        CharacterTagMatcher(name: char.name, franchise: char.franchise);
    if (!matcher.isUsable) {
      _duplicateCandidates = [];
      return;
    }
    final found = <MapEntry<LocalCharacter, double>>[];
    for (final other in _allCharacters) {
      if (other.id == char.id) continue;
      final tag = _isUnknownValue(other.franchise)
          ? other.name
          : '${other.name} (${other.franchise})';
      final m = matcher.matchTag(tag);
      if (m != null && m.score >= 0.94) found.add(MapEntry(other, m.score));
    }
    found.sort((a, b) => b.value.compareTo(a.value));
    _duplicateCandidates = [for (final e in found.take(3)) e.key];
  }

  // Selecciona un perfil por id aunque la búsqueda/filtro lo esté ocultando.
  void _focusCharacter(int? id) {
    if (id == null) return;
    _onlyEmpty = false;
    _searchCtrl.text = '';
    _filterCharacters();
    final idx = _filteredCharacters.indexWhere((c) => c.id == id);
    if (idx == -1) return;
    _selectCharacter(_filteredCharacters[idx]);
    _ensureTileVisible(id);
  }

  // ---------------------------------------------------------------------
  // PREFERENCIAS / ORDEN
  // ---------------------------------------------------------------------

  void _setGrouping(bool value) {
    setState(() => _groupByFranchise = value);
    _prefs?.setBool(_kPrefGroup, value);
  }

  void _setProfileSort(_ProfileSort sort) {
    _profileSort = sort;
    _prefs?.setInt(_kPrefProfileSort, sort.index);
    _filterCharacters();
  }

  void _toggleOnlyEmpty() {
    _onlyEmpty = !_onlyEmpty;
    _filterCharacters();
  }

  void _setImageSort(_ImageSort sort) {
    _prefs?.setInt(_kPrefImageSort, sort.index);
    setState(() {
      _imageSort = sort;
      _shiftSelectionAnchorIndex = null;
      final id = _selectedCharacter?.id;
      if (id != null) _associatedImages = _loadAssociatedImages(id);
    });
  }

  void _selectAllImages() {
    setState(() {
      _selectedImages = _associatedImages.toSet();
      _shiftSelectionAnchorIndex = null;
    });
  }

  void _clearImageSelection() {
    _hideContextMenu();
    setState(() {
      _selectedImages.clear();
      _shiftSelectionAnchorIndex = null;
    });
  }

  List<String> _knownFranchises() {
    final counts = <String, int>{};
    for (final c in _allCharacters) {
      final f = c.franchise.trim();
      if (_isUnknownValue(f)) continue;
      counts[f] = (counts[f] ?? 0) + 1;
    }
    final list = counts.keys.toList()
      ..sort((a, b) {
        final c = counts[b]!.compareTo(counts[a]!);
        return c != 0 ? c : a.toLowerCase().compareTo(b.toLowerCase());
      });
    return list;
  }

  // ---------------------------------------------------------------------
  // SUGERENCIAS
  // ---------------------------------------------------------------------

  int get _dismissedCount {
    final id = _selectedCharacter?.id;
    if (id == null) return 0;
    return _dismissed[id]?.length ?? 0;
  }

  // Debe llamarse dentro de un setState (o justo antes de uno).
  void _refreshSuggestions() {
    final char = _selectedCharacter;
    final id = char?.id;
    if (char == null || id == null) {
      _suggestions = [];
      return;
    }
    final hidden = _dismissed[id] ?? const <String>{};
    _suggestions = CharacterTagMatcher.suggest(widget.metadataService, char)
        .where((s) => !hidden.contains(s.imageId))
        .where((s) => File(p.join(widget.vaultRootPath, s.imageId)).existsSync())
        .toList();
  }

  void _dismissSuggestion(CharacterSuggestion suggestion) {
    final id = _selectedCharacter?.id;
    if (id == null) return;
    final set = _dismissed.putIfAbsent(id, () => <String>{});
    set.add(suggestion.imageId);
    _prefs?.setStringList('$_kPrefDismissed$id', set.toList());
    setState(_refreshSuggestions);
  }

  void _restoreDismissed() {
    final id = _selectedCharacter?.id;
    if (id == null) return;
    _clearDismissed(id);
    setState(_refreshSuggestions);
  }

  void _clearDismissed(int id) {
    _dismissed.remove(id);
    _prefs?.remove('$_kPrefDismissed$id');
  }

  Future<void> _linkSuggestion(CharacterSuggestion suggestion) async {
    final char = _selectedCharacter;
    if (char == null || char.id == null) return;

    await widget.metadataService.addCharacterToImage(suggestion.imageId, char.id!);
    if (!mounted) return;

    setState(() {
      _associatedImages = _loadAssociatedImages(char.id!);
      _shiftSelectionAnchorIndex = null;
      _refreshSuggestions();
    });
    showGlassSnackBar(context, 'Imagen vinculada a ${char.name}.',
        icon: Icons.link);
  }

  Future<void> _linkAllSuggestions({bool onlyFranchise = false}) async {
    final char = _selectedCharacter;
    if (char == null || char.id == null || _suggestions.isEmpty) return;

    final toLink = onlyFranchise
        ? _suggestions.where((s) => s.franchiseMatch).toList()
        : List<CharacterSuggestion>.from(_suggestions);
    if (toLink.isEmpty) return;

    final count = toLink.length;
    final confirm = await _showConfirmationDialog(
          title: 'Vincular sugerencias',
          content:
              '¿Vincular las $count imágenes sugeridas al perfil "${char.name}"?',
        ) ??
        false;
    if (!confirm || !mounted) return;

    for (final s in toLink) {
      await widget.metadataService.addCharacterToImage(s.imageId, char.id!);
    }
    if (!mounted) return;

    setState(() {
      _associatedImages = _loadAssociatedImages(char.id!);
      _shiftSelectionAnchorIndex = null;
      _refreshSuggestions();
    });
    showGlassSnackBar(context, '$count imagen(es) vinculada(s) a ${char.name}.',
        icon: Icons.link);
  }

  // ---------------------------------------------------------------------
  // ACCIONES SOBRE LAS IMÁGENES SELECCIONADAS
  // ---------------------------------------------------------------------

  /// Quita el vínculo con el perfil SIN borrar los archivos.
  Future<void> _unlinkSelected() async {
    _hideContextMenu();
    final char = _selectedCharacter;
    if (char == null || char.id == null || _selectedImages.isEmpty) return;

    final ids = List<String>.from(_selectedImages);
    for (final imageId in ids) {
      await widget.metadataService.removeCharacterFromImage(imageId, char.id!);
    }
    if (!mounted) return;

    setState(() {
      _selectedImages.clear();
      _shiftSelectionAnchorIndex = null;
      _focusedIndex = -1;
      _associatedImages = _loadAssociatedImages(char.id!);
      _refreshSuggestions();
    });
    showGlassSnackBar(
        context, '${ids.length} imagen(es) desvinculada(s) de ${char.name}.',
        icon: Icons.link_off);
  }

  /// Recorta una imagen de la bóveda y la usa como avatar del perfil.
  Future<void> _useAsAvatar(String imageId) async {
    _hideContextMenu();
    final char = _selectedCharacter;
    if (char == null || char.id == null) return;
    final file = File(p.join(widget.vaultRootPath, imageId));
    if (!file.existsSync() || _isVideo(file.path)) return;

    final bytes = await showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AvatarCropperDialog(imageFile: file),
    );
    if (bytes == null || !mounted) return;

    final path = await widget.metadataService.saveAvatarImage(bytes);
    await widget.metadataService
        .updateCharacter(_cloneCharacter(char, avatarPath: path));
    await _loadCharacters();
    if (!mounted) return;
    showGlassSnackBar(context, 'Avatar de ${char.name} actualizado.',
        icon: Icons.account_circle_outlined);
  }

  // ---------------------------------------------------------------------
  // CREAR / FUSIONAR / LIMPIAR PERFILES
  // ---------------------------------------------------------------------

  Future<void> _createCharacter({String initialName = ''}) async {
    final draft = LocalCharacter(
        name: initialName, franchise: '', gender: '', age: '', birthday: '');
    final created = await showDialog<LocalCharacter>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _GlobalCharacterEditDialog(
        character: draft,
        metadataService: widget.metadataService,
        isNew: true,
        knownFranchises: _knownFranchises(),
      ),
    );
    if (created == null || !mounted) return;

    final existing = await widget.metadataService
        .findExistingCharacter(created.name, created.franchise);
    if (existing != null) {
      if (!mounted) return;
      showGlassSnackBar(context,
          'Ya existe un perfil "${existing.name}" con esa franquicia.',
          icon: Icons.info_outline, iconColor: const Color(0xFFFFD60A));
      _focusCharacter(existing.id);
      return;
    }

    final newId = await widget.metadataService.insertCharacter(LocalCharacter(
      name: created.name,
      franchise: created.franchise,
      gender: created.gender.isEmpty ? 'Desconocido' : created.gender,
      age: created.age.isEmpty ? 'Desconocida' : created.age,
      birthday: created.birthday.isEmpty ? 'Desconocido' : created.birthday,
      avatarPath: created.avatarPath,
      customFields: created.customFields,
    ));
    await _loadCharacters();
    if (!mounted) return;
    _focusCharacter(newId);
    showGlassSnackBar(context, 'Perfil "${created.name}" creado.',
        icon: Icons.person_add_alt_1);
  }

  Future<void> _startMerge(LocalCharacter source,
      {LocalCharacter? preselected}) async {
    final choice = await showDialog<_MergeChoice>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _MergeProfilesDialog(
        source: source,
        candidates: _allCharacters.where((c) => c.id != source.id).toList(),
        imageCounts: _imageCounts,
        initial: preselected,
      ),
    );
    if (choice == null || !mounted) return;
    await _mergeProfiles(choice.keep, choice.remove);
  }

  /// Mueve todas las imágenes de [remove] a [keep], completa los datos
  /// vacíos de [keep] con los de [remove] y elimina [remove].
  Future<void> _mergeProfiles(LocalCharacter keep, LocalCharacter remove) async {
    final svc = widget.metadataService;
    if (keep.id == null || remove.id == null) return;

    final images = svc.getImagesForCharacter(remove.id!);
    for (final imageId in images) {
      await svc.addCharacterToImage(imageId, keep.id!);
    }

    String pick(String a, String b) => _isUnknownValue(a) ? b : a;
    await svc.updateCharacter(LocalCharacter(
      id: keep.id,
      name: keep.name,
      franchise: pick(keep.franchise, remove.franchise),
      gender: pick(keep.gender, remove.gender),
      age: pick(keep.age, remove.age),
      birthday: pick(keep.birthday, remove.birthday),
      avatarPath: keep.avatarPath ?? remove.avatarPath,
      customFields: {...remove.customFields, ...keep.customFields},
    ));
    await svc.deleteCharacter(remove.id!);
    _clearDismissed(remove.id!);

    await _loadCharacters();
    if (!mounted) return;
    _focusCharacter(keep.id);
    showGlassSnackBar(context,
        '"${remove.name}" se fusionó en "${keep.name}" (${images.length} imagen(es)).',
        icon: Icons.merge_type_rounded);
  }

  Future<void> _deleteEmptyProfiles() async {
    final empties =
        _allCharacters.where((c) => (_imageCounts[c.id] ?? 0) == 0).toList();
    if (empties.isEmpty) {
      showGlassSnackBar(context, 'No hay perfiles sin imágenes.',
          icon: Icons.info_outline);
      return;
    }
    final confirm = await _showConfirmationDialog(
          title: 'Limpiar perfiles vacíos',
          content:
              'Se eliminarán ${empties.length} perfil(es) que no están vinculados a ninguna imagen. Esta acción no se puede deshacer.',
        ) ??
        false;
    if (!confirm || !mounted) return;

    for (final c in empties) {
      await widget.metadataService.deleteCharacter(c.id!);
      _clearDismissed(c.id!);
    }
    _selectCharacter(null);
    await _loadCharacters();
    if (mounted) {
      showGlassSnackBar(context, '${empties.length} perfil(es) eliminado(s).',
          icon: Icons.delete_outline);
    }
  }

  // ---------------------------------------------------------------------
  // TECLADO
  // ---------------------------------------------------------------------

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchCtrl.selection =
        TextSelection(baseOffset: 0, extentOffset: _searchCtrl.text.length);
  }

  void _searchSubmitted() {
    if (_selectedCharacter == null && _filteredCharacters.isNotEmpty) {
      _selectCharacter(_filteredCharacters.first);
    }
    _screenFocus.requestFocus();
  }

  // Teclas dentro del buscador: Esc limpia/sale, ↑↓ cambian de perfil.
  KeyEventResult _handleSearchKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && event is KeyDownEvent) {
      if (_searchCtrl.text.isNotEmpty) {
        _searchCtrl.clear();
      } else {
        _screenFocus.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveProfileSelection(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveProfileSelection(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isDown = event is KeyDownEvent;
    final key = event.logicalKey;
    final hw = HardwareKeyboard.instance;
    final mod = hw.isControlPressed || hw.isMetaPressed;

    if (mod && isDown && key == LogicalKeyboardKey.keyF) {
      _focusSearch();
      return KeyEventResult.handled;
    }
    if (mod && isDown && key == LogicalKeyboardKey.keyN) {
      _createCharacter();
      return KeyEventResult.handled;
    }

    // Con el buscador activo, el resto de teclas son para escribir.
    if (_searchFocus.hasFocus) return KeyEventResult.ignored;

    if (mod && isDown && _selectedImages.isNotEmpty) {
      if (key == LogicalKeyboardKey.keyP) {
        _openProfileEditorForSelection();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyT) {
        _openTagEditorForSelection();
        return KeyEventResult.handled;
      }
    }
    // Ctrl+0..5: calificación rápida de las imágenes seleccionadas.
    if (mod && isDown && _selectedImages.isNotEmpty) {
      final rating = ratingFromDigitKey(key);
      if (rating != null) {
        _rateSelectedImages(rating);
        return KeyEventResult.handled;
      }
    }
    if (mod && isDown && key == LogicalKeyboardKey.keyA) {
      if (_selectedCharacter != null && _associatedImages.isNotEmpty) {
        _selectAllImages();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveProfileSelection(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveProfileSelection(-1);
      return KeyEventResult.handled;
    }
    if (isDown &&
        key == LogicalKeyboardKey.delete &&
        _selectedImages.isNotEmpty) {
      _handleDelete();
      return KeyEventResult.handled;
    }
    if (isDown &&
        key == LogicalKeyboardKey.escape &&
        _selectedImages.isNotEmpty) {
      _clearImageSelection();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Ctrl+T / menú contextual: editor de etiquetas de las imágenes seleccionadas.
  void _openTagEditorForSelection() {
    _hideContextMenu();
    if (_selectedImages.isEmpty) return;
    showDialog(
      context: context,
      builder: (context) => TagEditorDialog(
        imageIds: _selectedImages.toList(),
        metadataService: widget.metadataService,
        vaultRootPath: widget.vaultRootPath,
      ),
    ).then((_) {
      if (!mounted) return;
      setState(_refreshSuggestions);
      _screenFocus.requestFocus();
    });
  }

  /// Ctrl+P / menú contextual: asignación de perfil a las imágenes seleccionadas.
  void _openProfileEditorForSelection() {
    _hideContextMenu();
    if (_selectedImages.isEmpty) return;
    showDialog(
      context: context,
      builder: (context) => ProfileEditorDialog(
        imageIds: _selectedImages.toList(),
        metadataService: widget.metadataService,
        vaultRootPath: widget.vaultRootPath,
      ),
    ).then((_) {
      if (!mounted) return;
      setState(() {
        // Refrescamos por si el usuario desvincula la imagen desde el editor
        if (_selectedCharacter != null) {
          _associatedImages = _loadAssociatedImages(_selectedCharacter!.id!);
          _selectedImages.removeWhere((id) => !_associatedImages.contains(id));
        }
        _refreshSuggestions();
      });
      _screenFocus.requestFocus();
    });
  }

  void _rateSelectedImages(int rating) {
    _hideContextMenu();
    if (_selectedImages.isEmpty) return;
    for (final imageId in _selectedImages) {
      widget.metadataService.setRatingForImage(imageId, rating);
    }
    setState(() {});
    showGlassSnackBar(
      context,
      ratingFeedbackText(rating, _selectedImages.length),
      icon: rating == 0 ? Icons.star_outline : Icons.star,
      iconColor: rating == 0 ? Colors.white70 : const Color(0xFFFFD60A),
    );
  }

  List<LocalCharacter> _visibleCharacterOrder() => _groupByFranchise
      ? [for (final e in _groupedCharacters.values) ...e]
      : _filteredCharacters;

  void _moveProfileSelection(int delta) {
    final order = _visibleCharacterOrder();
    if (order.isEmpty) return;
    final current = order.indexWhere((c) => c.id == _selectedCharacter?.id);
    final next = current == -1
        ? (delta > 0 ? 0 : order.length - 1)
        : (current + delta).clamp(0, order.length - 1).toInt();
    if (next == current) return;
    _selectCharacter(order[next]);
    _ensureTileVisible(order[next].id);
  }

  void _ensureTileVisible(int? id) {
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _tileKeys['${_groupByFranchise}_$id']?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.5, duration: const Duration(milliseconds: 120));
      }
    });
  }

  // --- LÓGICA DE SELECCIÓN DE IMÁGENES ---
  void _handleItemTap(String imageId, int index) {
    _hideContextMenu();

    final isShiftPressed = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftLeft) ||
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftRight);

    final isCtrlPressed = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlLeft) ||
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlRight) ||
        (Platform.isMacOS &&
            (RawKeyboard.instance.keysPressed
                    .contains(LogicalKeyboardKey.metaLeft) ||
                RawKeyboard.instance.keysPressed
                    .contains(LogicalKeyboardKey.metaRight)));

    setState(() {
      _focusedIndex = index;
      if (isShiftPressed) {
        if (_shiftSelectionAnchorIndex == null) {
          _shiftSelectionAnchorIndex = index;
          _selectedImages = {imageId};
        } else {
          final start = index < _shiftSelectionAnchorIndex!
              ? index
              : _shiftSelectionAnchorIndex!;
          final end = index > _shiftSelectionAnchorIndex!
              ? index
              : _shiftSelectionAnchorIndex!;
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
        if (_doubleTapTimer != null &&
            _doubleTapTimer!.isActive &&
            _lastTappedImage == imageId) {
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

  void _openImage(String targetImageId, {List<String>? source}) {
    final ids = source ?? _associatedImages;
    if (ids.isEmpty) return;

    final imageFiles = ids
        .map((id) => File(p.join(widget.vaultRootPath, id)))
        .where((file) => file.existsSync())
        .toList();

    if (imageFiles.isEmpty) return;

    int initialIndex = imageFiles
        .indexWhere((f) => p.basename(f.path) == p.basename(targetImageId));
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
            final fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
            final scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
            return FadeTransition(
                opacity: fadeAnimation,
                child: ScaleTransition(scale: scaleAnimation, child: child));
          }),
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
        shortcut: '${Platform.isMacOS ? '⌘' : 'Ctrl'}+T',
        onTap: _openTagEditorForSelection,
        icon: Icons.label_outline,
      ),
      _ProfileContextMenuItem(
        title: 'Perfil',
        shortcut: '${Platform.isMacOS ? '⌘' : 'Ctrl'}+P',
        onTap: _openProfileEditorForSelection,
        icon: Icons.person_outline,
      ),
      _ProfileContextMenuItem(
        title: 'Quitar de este perfil',
        onTap: _unlinkSelected,
        icon: Icons.link_off,
      ),
      if (_selectedImages.length == 1 && !_isVideo(_selectedImages.first))
        _ProfileContextMenuItem(
          title: 'Usar como avatar',
          onTap: () => _useAsAvatar(_selectedImages.first),
          icon: Icons.account_circle_outlined,
        ),
      _ProfileContextMenuItem(
        title: 'Calificación',
        shortcut: '${Platform.isMacOS ? '⌘' : 'Ctrl'}+1-5',
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
                        side:
                            const BorderSide(color: Colors.white12, width: 0.5),
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
    final maxAvailableHeight = isBottomHalf
        ? position.dy - 16.0
        : screenSize.height - position.dy - 16.0;

    int? currentRating;
    if (_selectedImages.isNotEmpty) {
      currentRating = widget.metadataService
          .getMetadataForImage(_selectedImages.first)
          .rating;
      for (var id in _selectedImages.skip(1)) {
        if (widget.metadataService.getMetadataForImage(id).rating !=
            currentRating) {
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
              Icon(isSelected ? Icons.check : null,
                  size: 18, color: Colors.white),
              const SizedBox(width: 12),
              if (index == 0)
                const Text("Sin calificar",
                    style: TextStyle(color: Colors.white))
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
                        side:
                            const BorderSide(color: Colors.white12, width: 0.5),
                      ),
                      child: IntrinsicWidth(
                        child: SingleChildScrollView(
                          child: Column(
                              mainAxisSize: MainAxisSize.min, children: items),
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
    final itemText = count == 1
        ? 'el elemento seleccionado'
        : 'los $count elementos seleccionados';

    bool confirm = await _showConfirmationDialog(
          title: 'Confirmar Eliminación',
          content:
              '¿Estás seguro de que quieres eliminar $itemText permanentemente? Esta acción no se puede deshacer.',
        ) ??
        false;

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
        _associatedImages = _loadAssociatedImages(_selectedCharacter!.id!);
      }
    });
    if (mounted)
      showGlassSnackBar(context, '$count elemento(s) eliminado(s).',
          icon: Icons.delete_outline);
  }

  Future<void> _handleExport() async {
    _hideContextMenu();
    if (_selectedImages.isEmpty) return;

    String? selectedDirectory = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Seleccionar carpeta de exportación');
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
      showGlassSnackBar(context,
          '${_selectedImages.length} elemento(s) exportado(s) con éxito a ${exportRootDir.path}.',
          icon: Icons.download_done);
    }
    setState(() => _selectedImages.clear());
  }

  Future<void> _handleSingleExport(File file) async {
    String? selectedDirectory = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Seleccionar carpeta de exportación');
    if (selectedDirectory == null) return;

    final exportRootDir = Directory(selectedDirectory);
    final cleanName = _getDeobfuscatedName(p.basename(file.path));
    final newPath = await _getUniquePath(exportRootDir, cleanName);

    try {
      await file.copy(newPath);
      if (mounted)
        showGlassSnackBar(
            context, 'Archivo exportado con éxito a ${exportRootDir.path}.',
            icon: Icons.download_done);
    } catch (e) {
      if (mounted)
        showGlassSnackBar(context, 'Error al exportar: $e',
            icon: Icons.error_outline, iconColor: Colors.redAccent);
    }
  }

  Future<void> _handleRestoreSelected() async {
    _hideContextMenu();
    if (_selectedImages.isEmpty) return;

    String? selectedDirectory = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Seleccionar carpeta para restaurar');
    if (selectedDirectory == null) return;

    final destinationDir = Directory(selectedDirectory);
    final count = _selectedImages.length;
    final itemText = count == 1
        ? 'el elemento seleccionado'
        : 'los $count elementos seleccionados';

    bool confirm = await _showConfirmationDialog(
          title: 'Confirmar Restauración',
          content:
              '¿Deseas mover $itemText a la carpeta seleccionada y quitarlos de la bóveda?',
        ) ??
        false;

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

    if (mounted)
      showGlassSnackBar(context,
          '$count elemento(s) restaurado(s) con éxito a ${destinationDir.path}.');
    setState(() {
      _selectedImages.clear();
      if (_selectedCharacter != null) {
        _associatedImages = _loadAssociatedImages(_selectedCharacter!.id!);
      }
    });
  }

  Future<void> _showPropertiesDialog(String imageId) async {
    final file = File(p.join(widget.vaultRootPath, imageId));
    if (!file.existsSync()) return;

    String name = _getDeobfuscatedName(p.basename(file.path));
    final realExt =
        _getRealExtension(file.path).replaceAll('.', '').toUpperCase();
    String type =
        _isVideo(file.path) ? '$realExt (Video)' : '$realExt (Imagen)';

    String sizeStr = '--';
    String dateStr = 'Desconocido';
    String addedDateStr = '--';

    int rating = 0;
    List<String> tags = [];
    List<LocalCharacter> characterProfiles = [];

    try {
      final stat = await file.stat();
      dateStr =
          "${stat.modified.day.toString().padLeft(2, '0')}/${stat.modified.month.toString().padLeft(2, '0')}/${stat.modified.year} ${stat.modified.hour.toString().padLeft(2, '0')}:${stat.modified.minute.toString().padLeft(2, '0')}";

      int bytes = stat.size;
      if (bytes < 1024)
        sizeStr = '$bytes B';
      else if (bytes < 1024 * 1024)
        sizeStr = '${(bytes / 1024).toStringAsFixed(2)} KB';
      else if (bytes < 1024 * 1024 * 1024)
        sizeStr = '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
      else
        sizeStr = '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';

      final metadata = widget.metadataService.getMetadataForImage(imageId);
      rating = metadata.rating;
      tags = metadata.tags;

      for (int id in metadata.characterIds) {
        final char = await widget.metadataService.getCharacterById(id);
        if (char != null) characterProfiles.add(char);
      }

      if (metadata.addedTimestamp > 0) {
        final addedDate =
            DateTime.fromMillisecondsSinceEpoch(metadata.addedTimestamp);
        addedDateStr =
            "${addedDate.day.toString().padLeft(2, '0')}/${addedDate.month.toString().padLeft(2, '0')}/${addedDate.year} ${addedDate.hour.toString().padLeft(2, '0')}:${addedDate.minute.toString().padLeft(2, '0')}";
      } else {
        addedDateStr = dateStr;
      }
    } catch (e) {
      debugPrint("Error leyendo propiedades: $e");
    }

    if (mounted) {
      showDialog(
        context: context,
        barrierColor: Colors.black.withOpacity(0.4),
        builder: (context) {
          bool isTagsExpanded = false;
          return StatefulBuilder(builder: (context, setState) {
            return Dialog(
              backgroundColor: Colors.transparent,
              elevation: 0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14.0),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    width: 380,
                    constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.8),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xFF252525).withOpacity(0.65),
                      border: Border.all(color: Colors.white12, width: 0.5),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Center(
                            child: Text('Propiedades',
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white))),
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
                                const Divider(
                                    color: Colors.white12,
                                    height: 24,
                                    thickness: 1),
                                const Text('Metadatos del Vórtice',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF0A84FF),
                                        fontSize: 13)),
                                const SizedBox(height: 12),
                                _buildPropertyRow('Añadido:', addedDateStr),
                                _buildPropertyRow('Estrellas:',
                                    rating > 0 ? '$rating' : 'Sin calificar'),
                                _buildTagsPropertyRow(
                                    'Etiquetas:', tags, isTagsExpanded, () {
                                  setState(() {
                                    isTagsExpanded = !isTagsExpanded;
                                  });
                                }),
                                if (characterProfiles.isNotEmpty) ...[
                                  ...characterProfiles.map((charProfile) {
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 16.0),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Divider(
                                              color: Colors.white12,
                                              height: 10,
                                              thickness: 0.5),
                                          Row(
                                            children: [
                                              const Icon(
                                                  Icons.account_circle_outlined,
                                                  size: 14,
                                                  color: Color(0xFF32D74B)),
                                              const SizedBox(width: 6),
                                              Text(
                                                  'Perfil: ${charProfile.name}',
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: Color(0xFF32D74B),
                                                      fontSize: 13)),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          _buildPropertyRow('Franquicia:',
                                              charProfile.franchise),
                                          _buildPropertyRow(
                                              'Género:', charProfile.gender),
                                          _buildPropertyRow(
                                              'Edad:', charProfile.age),
                                          _buildPropertyRow('Cumpleaños:',
                                              charProfile.birthday),
                                          ...charProfile.customFields.entries
                                              .map((field) {
                                            return _buildPropertyRow(
                                                '${field.key}:', field.value);
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
                            style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF0A84FF)),
                            child: const Text('Aceptar',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        )
                      ],
                    ),
                  ),
                ),
              ),
            );
          });
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

    final TextEditingController renameController =
        TextEditingController(text: currentName);
    renameController.selection =
        TextSelection(baseOffset: 0, extentOffset: currentName.length);

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
                    const Text('Renombrar',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                    const SizedBox(height: 16),
                    TextField(
                      controller: renameController,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      onSubmitted: (_) => Navigator.of(context).pop(true),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFF1C1C1E).withOpacity(0.8),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          style: TextButton.styleFrom(
                              foregroundColor: Colors.white70),
                          child: const Text('Cancelar',
                              style: TextStyle(fontWeight: FontWeight.w500)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF0A84FF)),
                          child: const Text('Guardar',
                              style: TextStyle(fontWeight: FontWeight.w600)),
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

    if (confirm == true &&
        renameController.text.isNotEmpty &&
        renameController.text.trim() != currentName) {
      final newNameInput = renameController.text.trim();
      final realExt = _getRealExtension(file.path);
      final nameWithExt = '$newNameInput$realExt';
      final finalNewName = _obfuscateName(nameWithExt);

      final destinationDir = Directory(p.dirname(file.path));
      final finalUniquePath =
          await _getUniquePath(destinationDir, finalNewName);

      try {
        final newId = p.relative(finalUniquePath, from: widget.vaultRootPath);

        await widget.thumbnailService
            .renameThumbnail(file.path, finalUniquePath);
        await _moveFileRobustly(file, finalUniquePath);
        await widget.metadataService.updateImagePath(imageId, newId);

        setState(() {
          _selectedImages.clear();
          if (_selectedCharacter != null) {
            _associatedImages = _loadAssociatedImages(_selectedCharacter!.id!);
          }
        });
      } catch (e) {
        if (mounted)
          showGlassSnackBar(context, 'Error al renombrar: $e',
              icon: Icons.error_outline, iconColor: Colors.redAccent);
      }
    }
  }

  Future<bool?> _showConfirmationDialog(
      {required String title, required String content}) {
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
                  Text(title,
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(content,
                      style:
                          const TextStyle(fontSize: 14, color: Colors.white70),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.white70),
                        child: const Text('Cancelar',
                            style: TextStyle(fontWeight: FontWeight.w500)),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF0A84FF)),
                        child: const Text('Aceptar',
                            style: TextStyle(fontWeight: FontWeight.w600)),
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
          SizedBox(
              width: 85,
              child: Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.white54,
                      fontSize: 13))),
          Expanded(
              child: Text(value,
                  style: const TextStyle(color: Colors.white, fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildTagsPropertyRow(
      String label, List<String> tags, bool isExpanded, VoidCallback onToggle) {
    if (tags.isEmpty) return _buildPropertyRow(label, 'Ninguna');

    final displayTags = isExpanded ? tags : tags.take(3).toList();
    final hiddenCount = tags.length - 3;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 85,
              child: Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.white54,
                      fontSize: 13))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayTags.join(', '),
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
                if (!isExpanded && hiddenCount > 0)
                  InkWell(
                    onTap: onToggle,
                    child: Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text('Ver $hiddenCount más...',
                            style: const TextStyle(
                                color: Color(0xFF0A84FF),
                                fontSize: 12,
                                fontWeight: FontWeight.w500))),
                  ),
                if (isExpanded && tags.length > 3)
                  InkWell(
                    onTap: onToggle,
                    child: const Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text('Ocultar',
                            style: TextStyle(
                                color: Color(0xFF0A84FF),
                                fontSize: 12,
                                fontWeight: FontWeight.w500))),
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
                      const Text('Eliminar Perfil',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
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
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancelar',
                                  style: TextStyle(color: Colors.white70))),
                          TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Eliminar',
                                  style: TextStyle(color: Colors.redAccent))),
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
      await widget.metadataService.deleteCharacter(char.id!);
      _clearDismissed(char.id!);
      _selectCharacter(null);
      await _loadCharacters();
      if (mounted)
        showGlassSnackBar(context, 'Perfil eliminado.',
            icon: Icons.delete_outline);
    }
  }

  void _editCharacter(LocalCharacter char) async {
    final updated = await showDialog<LocalCharacter>(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _GlobalCharacterEditDialog(
        character: char,
        metadataService: widget.metadataService,
        knownFranchises: _knownFranchises(),
      ),
    );

    if (updated != null) {
      // Aviso si el nuevo nombre + franquicia ya lo tiene OTRO perfil.
      final existing = await widget.metadataService
          .findExistingCharacter(updated.name, updated.franchise);
      if (existing != null && existing.id != updated.id) {
        final go = await _showConfirmationDialog(
              title: 'Perfil duplicado',
              content:
                  'Ya existe "${existing.name}" con esa franquicia. ¿Guardar de todos modos? Después puedes unirlos con "Fusionar".',
            ) ??
            false;
        if (!go) return;
      }

      await widget.metadataService.updateCharacter(updated);
      await _loadCharacters();
      if (mounted) setState(_refreshSuggestions);
      if (mounted)
        showGlassSnackBar(context, 'Perfil actualizado.', icon: Icons.save);
    }
  }

  Widget _buildCharacterTile(LocalCharacter char, bool isSelected,
      {bool isGrouped = false}) {
    final count = _imageCounts[char.id] ?? 0;
    return ListTile(
      key: _tileKeys.putIfAbsent(
          '${_groupByFranchise}_${char.id}', () => GlobalKey()),
      contentPadding: EdgeInsets.only(left: isGrouped ? 32 : 16, right: 16),
      selected: isSelected,
      selectedTileColor: const Color(0xFF0A84FF).withOpacity(0.15),
      leading: _AvatarCircle(path: char.avatarPath, highlighted: isSelected),
      title: Text(char.name,
          style: const TextStyle(fontSize: 13, color: Colors.white),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      subtitle: isGrouped
          ? null
          : Text(char.franchise,
              style: const TextStyle(fontSize: 11, color: Colors.white54),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
      trailing: Tooltip(
        message: count == 0
            ? 'Sin imágenes vinculadas'
            : '$count imagen(es) vinculada(s)',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(count == 0 ? 0.03 : 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('$count',
              style: TextStyle(
                  fontSize: 11,
                  color: count == 0 ? Colors.white24 : Colors.white60)),
        ),
      ),
      onTap: () => _selectCharacter(char),
    );
  }

  // --- BARRA DE HERRAMIENTAS DE LA LISTA (contador, filtro, orden) ---
  Widget _buildListToolbar() {
    final total = _allCharacters.length;
    final shown = _filteredCharacters.length;
    final emptyCount =
        _allCharacters.where((c) => (_imageCounts[c.id] ?? 0) == 0).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 6, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
                shown == total ? '$total perfiles' : '$shown de $total perfiles',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ),
          IconButton(
            tooltip: _onlyEmpty
                ? 'Mostrar todos los perfiles'
                : 'Solo perfiles sin imágenes ($emptyCount)',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: Icon(Icons.filter_alt_outlined,
                color: _onlyEmpty ? const Color(0xFF0A84FF) : Colors.white54),
            onPressed: _toggleOnlyEmpty,
          ),
          PopupMenuButton<_ProfileSort>(
            tooltip: 'Ordenar',
            color: const Color(0xFF2C2C2E),
            iconSize: 18,
            icon: const Icon(Icons.sort, color: Colors.white54),
            onSelected: _setProfileSort,
            itemBuilder: (context) => [
              for (final s in _ProfileSort.values)
                CheckedPopupMenuItem<_ProfileSort>(
                  value: s,
                  checked: _profileSort == s,
                  child: Text(_profileSortLabels[s]!,
                      style: const TextStyle(fontSize: 13)),
                ),
            ],
          ),
          PopupMenuButton<String>(
            tooltip: 'Más opciones',
            color: const Color(0xFF2C2C2E),
            iconSize: 18,
            icon: const Icon(Icons.more_vert, color: Colors.white54),
            onSelected: (v) {
              if (v == 'new') _createCharacter();
              if (v == 'clean') _deleteEmptyProfiles();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                  value: 'new',
                  child: Text('Nuevo perfil', style: TextStyle(fontSize: 13))),
              PopupMenuItem(
                  value: 'clean',
                  enabled: emptyCount > 0,
                  child: Text('Eliminar perfiles sin imágenes ($emptyCount)',
                      style: const TextStyle(fontSize: 13))),
            ],
          ),
        ],
      ),
    );
  }

  // --- LISTA DE PERFILES (plana o agrupada por franquicia) ---
  Widget _buildCharacterList() {
    if (_filteredCharacters.isEmpty) {
      final query = _searchCtrl.text.trim();
      final String message = _allCharacters.isEmpty
          ? 'Aún no hay perfiles.'
          : (_onlyEmpty && query.isEmpty
              ? 'Todos los perfiles tienen imágenes.'
              : 'Sin resultados.');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_search_outlined,
                  size: 40, color: Colors.white12),
              const SizedBox(height: 12),
              Text(message, style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => _createCharacter(initialName: query),
                icon: const Icon(Icons.person_add_alt_1, size: 16),
                label: Text(query.isEmpty ? 'Crear perfil' : 'Crear "$query"',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      );
    }

    if (!_groupByFranchise) {
      return ListView.separated(
        physics: const BouncingScrollPhysics(),
        itemCount: _filteredCharacters.length,
        separatorBuilder: (_, __) => const Divider(
            height: 1, indent: 16, endIndent: 16, color: Colors.white12),
        itemBuilder: (context, index) {
          final char = _filteredCharacters[index];
          final isSelected = _selectedCharacter?.id == char.id;
          return _buildCharacterTile(char, isSelected, isGrouped: false);
        },
      );
    }

    // Agrupada: el mapa se calcula UNA vez (antes se recalculaba por fila).
    final grouped = _groupedCharacters;
    final keys = grouped.keys.toList();
    final bool isSearchActive = _searchCtrl.text.isNotEmpty;

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: keys.length,
      itemBuilder: (context, index) {
        final franchise = keys[index];
        final chars = grouped[franchise]!;
        final totalImages =
            chars.fold<int>(0, (sum, c) => sum + (_imageCounts[c.id] ?? 0));
        final hasSelected = chars.any((c) => c.id == _selectedCharacter?.id);

        return Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: PageStorageKey('franchise_$franchise'),
            initiallyExpanded: isSearchActive || hasSelected,
            iconColor: const Color(0xFF0A84FF),
            collapsedIconColor: Colors.white54,
            leading: const Icon(Icons.folder_special_outlined, size: 22),
            title: Text(franchise,
                style: const TextStyle(
                    fontSize: 13,
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
            subtitle: Text('${chars.length} perfil(es) · $totalImages imagen(es)',
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
            children: chars.map((char) {
              final isSelected = _selectedCharacter?.id == char.id;
              return _buildCharacterTile(char, isSelected, isGrouped: true);
            }).toList(),
          ),
        );
      },
    );
  }

  // --- AVISO DE POSIBLES DUPLICADOS ---
  Widget _buildDuplicateBanner() {
    final current = _selectedCharacter;
    if (_duplicateCandidates.isEmpty || current == null) {
      return const SizedBox.shrink();
    }
    const amber = Color(0xFFFFD60A);
    final compact = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(0, 28),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const TextStyle(fontSize: 12),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: amber.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: amber.withOpacity(0.35), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.content_copy_rounded, size: 14, color: amber),
                SizedBox(width: 8),
                Text('Posibles duplicados',
                    style: TextStyle(
                        color: amber,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 6),
            for (final c in _duplicateCandidates)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${c.name}${_isUnknownValue(c.franchise) ? '' : ' · ${c.franchise}'}  (${_imageCounts[c.id] ?? 0} img)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                  TextButton(
                      style: compact,
                      onPressed: () => _focusCharacter(c.id),
                      child: const Text('Ver')),
                  TextButton(
                      style: compact,
                      onPressed: () => _startMerge(current, preselected: c),
                      child: const Text('Fusionar')),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // --- CABECERA DE "APARICIONES": título, nota media, orden y tamaño ---
  Widget _buildAppearancesHeader() {
    final svc = widget.metadataService;
    final ratings = <int>[
      for (final id in _associatedImages) svc.getMetadataForImage(id).rating
    ].where((r) => r > 0).toList();
    final double? avg = ratings.isEmpty
        ? null
        : ratings.reduce((a, b) => a + b) / ratings.length;
    final bool hasImages = _associatedImages.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 4,
        children: [
          Text('Apariciones en la Bóveda (${_associatedImages.length})',
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.bold)),
          if (avg != null)
            Tooltip(
              message: '${ratings.length} imagen(es) calificada(s)',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.star, size: 14, color: Color(0xFFFFD60A)),
                  const SizedBox(width: 4),
                  Text(avg.toStringAsFixed(1),
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
          if (hasImages)
            PopupMenuButton<_ImageSort>(
              tooltip: 'Ordenar imágenes',
              color: const Color(0xFF2C2C2E),
              onSelected: _setImageSort,
              itemBuilder: (context) => [
                for (final s in _ImageSort.values)
                  CheckedPopupMenuItem<_ImageSort>(
                    value: s,
                    checked: _imageSort == s,
                    child: Text(_imageSortLabels[s]!,
                        style: const TextStyle(fontSize: 13)),
                  ),
              ],
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sort, size: 16, color: Colors.white54),
                  const SizedBox(width: 4),
                  Text(_imageSortLabels[_imageSort]!,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
          if (hasImages)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.photo_size_select_small,
                    size: 14, color: Colors.white38),
                SizedBox(
                  width: 120,
                  child: Slider(
                    value: _thumbExtent,
                    min: 110,
                    max: 280,
                    onChanged: (v) => setState(() => _thumbExtent = v),
                    onChangeEnd: (v) => _prefs?.setDouble(_kPrefThumb, v),
                  ),
                ),
                const Icon(Icons.photo_size_select_large,
                    size: 14, color: Colors.white38),
              ],
            ),
          if (hasImages)
            TextButton(
              onPressed: _selectAllImages,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('Seleccionar todo (Ctrl+A)',
                  style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  // --- BARRA FLOTANTE CUANDO HAY IMÁGENES SELECCIONADAS ---
  Widget _buildSelectionBar() {
    final n = _selectedImages.length;
    final bool canAvatar = n == 1 && !_isVideo(_selectedImages.first);

    Widget action(IconData icon, String tooltip, VoidCallback onTap,
        {Color color = Colors.white70}) {
      return IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 20, color: color),
        onPressed: onTap,
      );
    }

    return Positioned(
      left: 0,
      right: 0,
      bottom: 16,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF252525).withOpacity(0.88),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12, width: 0.5),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 4)),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 10, right: 8),
                    child: Text('$n seleccionada(s)',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                  ),
                  action(Icons.link_off, 'Quitar de este perfil',
                      _unlinkSelected),
                  if (canAvatar)
                    action(Icons.account_circle_outlined, 'Usar como avatar',
                        () => _useAsAvatar(_selectedImages.first)),
                  action(Icons.download_for_offline_outlined, 'Exportar',
                      _handleExport),
                  action(Icons.delete_forever_outlined, 'Eliminar (Supr)',
                      _handleDelete,
                      color: Colors.redAccent),
                  action(Icons.close, 'Deseleccionar (Esc)',
                      _clearImageSelection,
                      color: Colors.white54),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _screenFocus,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        title: const Text('Administración de Perfiles',
            style: TextStyle(fontSize: 15)),
        backgroundColor: const Color(0xE61C1C1E),
        elevation: 0,
        actions: [
          Tooltip(
            message: 'Nuevo perfil (Ctrl+N)',
            child: IconButton(
              icon: const Icon(Icons.person_add_alt_1, size: 20),
              onPressed: () => _createCharacter(),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          // --- PANEL IZQUIERDO: LISTA DE PERSONAJES / FRANQUICIAS ---
          Container(
            width: 320,
            decoration: const BoxDecoration(
              color: Color(0xFF151515),
              border:
                  Border(right: BorderSide(color: Colors.white12, width: 1)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                      left: 16.0, right: 16.0, top: 16.0, bottom: 8.0),
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    onSubmitted: (_) => _searchSubmitted(),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1C1C1E),
                      prefixIcon: const Icon(Icons.search,
                          color: Colors.white54, size: 18),
                      suffixIcon: _searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.cancel,
                                  color: Colors.white54, size: 16),
                              onPressed: () => _searchCtrl.clear(),
                            )
                          : null,
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none),
                      hintText: 'Buscar nombre o franquicia  (Ctrl+F)',
                      hintStyle: const TextStyle(color: Colors.white54),
                    ),
                  ),
                ),

                // --- NUEVO: INTERRUPTOR (TOGGLE) PERSONAJES / FRANQUICIAS ---
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16.0, vertical: 8.0),
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
                            onTap: () =>
                                _setGrouping(false),
                            child: Container(
                              decoration: BoxDecoration(
                                  color: !_groupByFranchise
                                      ? const Color(0xFF0A84FF).withOpacity(0.2)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: !_groupByFranchise
                                        ? const Color(0xFF0A84FF)
                                        : Colors.transparent,
                                    width: 1,
                                  )),
                              alignment: Alignment.center,
                              child: Text('Personajes',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: !_groupByFranchise
                                          ? const Color(0xFF0A84FF)
                                          : Colors.white54,
                                      fontWeight: !_groupByFranchise
                                          ? FontWeight.bold
                                          : FontWeight.normal)),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () =>
                                _setGrouping(true),
                            child: Container(
                              decoration: BoxDecoration(
                                  color: _groupByFranchise
                                      ? const Color(0xFF0A84FF).withOpacity(0.2)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: _groupByFranchise
                                        ? const Color(0xFF0A84FF)
                                        : Colors.transparent,
                                    width: 1,
                                  )),
                              alignment: Alignment.center,
                              child: Text('Franquicias',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: _groupByFranchise
                                          ? const Color(0xFF0A84FF)
                                          : Colors.white54,
                                      fontWeight: _groupByFranchise
                                          ? FontWeight.bold
                                          : FontWeight.normal)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                _buildListToolbar(),
                Expanded(child: _buildCharacterList()),
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
                        Icon(Icons.badge_outlined,
                            size: 80, color: Colors.white12),
                        SizedBox(height: 16),
                        Text('Selecciona un perfil para ver sus detalles',
                            style:
                                TextStyle(color: Colors.white38, fontSize: 16)),
                      ],
                    ),
                  )
                : Stack(
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
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
                              border: Border(
                                  bottom: BorderSide(
                                      color: Colors.white12, width: 1)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 100,
                                  height: 100,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.black45,
                                    border: Border.all(
                                        color: const Color(0xFF0A84FF),
                                        width: 2),
                                    image: _selectedCharacter!.avatarPath !=
                                                null &&
                                            File(_selectedCharacter!
                                                    .avatarPath!)
                                                .existsSync()
                                        ? DecorationImage(
                                            image: FileImage(File(
                                                _selectedCharacter!
                                                    .avatarPath!)),
                                            fit: BoxFit.cover)
                                        : null,
                                  ),
                                  child: _selectedCharacter!.avatarPath == null
                                      ? const Icon(Icons.person,
                                          color: Colors.white38, size: 50)
                                      : null,
                                ),
                                const SizedBox(width: 24),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              _selectedCharacter!.name,
                                              style: const TextStyle(
                                                  fontSize: 28,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.white),
                                            ),
                                          ),
                                          Tooltip(
  message: 'Fusionar con otro perfil',
  child: InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: () => _startMerge(_selectedCharacter!),
    hoverColor: Colors.white12,
    child: const Padding(
      padding: EdgeInsets.all(8.0),
      child: Icon(Icons.merge_type_rounded, color: Colors.white54, size: 22),
    ),
  ),
),
const SizedBox(width: 8),
                                          Tooltip(
                                            message: 'Editar Perfil',
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              onTap: () => _editCharacter(
                                                  _selectedCharacter!),
                                              hoverColor: Colors.white12,
                                              child: const Padding(
                                                padding: EdgeInsets.all(8.0),
                                                child: Icon(
                                                    Icons.edit_note_rounded,
                                                    color: Colors.white54,
                                                    size: 22),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Tooltip(
                                            message: 'Eliminar Perfil',
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              onTap: () => _deleteCharacter(
                                                  _selectedCharacter!),
                                              hoverColor: Colors.redAccent
                                                  .withOpacity(0.2),
                                              child: const Padding(
                                                padding: EdgeInsets.all(8.0),
                                                child: Icon(
                                                    Icons.delete_outline,
                                                    color: Colors.white54,
                                                    size: 22),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(_selectedCharacter!.franchise,
                                          style: const TextStyle(
                                              fontSize: 16,
                                              color: Color(0xFF0A84FF),
                                              fontWeight: FontWeight.w500)),
                                      const SizedBox(height: 16),
                                      Wrap(
                                        spacing: 24,
                                        runSpacing: 12,
                                        children: [
                                          _buildAttribute(Icons.wc, 'Género',
                                              _selectedCharacter!.gender),
                                          _buildAttribute(Icons.cake_outlined,
                                              'Edad', _selectedCharacter!.age),
                                          _buildAttribute(
                                              Icons.calendar_month_outlined,
                                              'Cumpleaños',
                                              _selectedCharacter!.birthday),
                                        ],
                                      ),
                                      if (_selectedCharacter!
                                          .customFields.isNotEmpty) ...[
                                        const SizedBox(height: 12),
                                        InkWell(
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          onTap: () {
                                            setState(() => _showExtraFields =
                                                !_showExtraFields);
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 4.0, horizontal: 2.0),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  _showExtraFields
                                                      ? 'Mostrar menos'
                                                      : 'Mostrar más (${_selectedCharacter!.customFields.length})',
                                                  style: const TextStyle(
                                                      color: Color(0xFF0A84FF),
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.bold),
                                                ),
                                                Icon(
                                                    _showExtraFields
                                                        ? Icons
                                                            .keyboard_arrow_up
                                                        : Icons
                                                            .keyboard_arrow_down,
                                                    color:
                                                        const Color(0xFF0A84FF),
                                                    size: 16),
                                              ],
                                            ),
                                          ),
                                        ),
                                        if (_showExtraFields)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                top: 12.0),
                                            child: Wrap(
                                              spacing: 24,
                                              runSpacing: 12,
                                              children: _selectedCharacter!
                                                  .customFields.entries
                                                  .map((e) => _buildAttribute(
                                                      Icons.info_outline,
                                                      e.key,
                                                      e.value))
                                                  .toList(),
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
                        SliverToBoxAdapter(child: _buildDuplicateBanner()),
                        SliverToBoxAdapter(child: _buildAppearancesHeader()),
                        _associatedImages.isEmpty
                            ? const SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.all(24.0),
                                  child: Center(
                                      child: Text(
                                          'Este perfil no está etiquetado en ninguna imagen.',
                                          style: TextStyle(
                                              color: Colors.white38))),
                                ),
                              )
                            : SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 24, vertical: 0),
                                sliver: SliverGrid(
                                  gridDelegate:
                                      SliverGridDelegateWithMaxCrossAxisExtent(
 maxCrossAxisExtent: _thumbExtent,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                    childAspectRatio: 1,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) {
                                      final imageId = _associatedImages[index];
                                      final file = File(p.join(
                                          widget.vaultRootPath, imageId));
                                      final isSelected =
                                          _selectedImages.contains(imageId);

                                      return ImageItemWidget(
                                        imageFile: file,
                                        imageId: imageId,
                                        isSelected: isSelected,
                                        extent: _thumbExtent,
                                        metadataService: widget.metadataService,
                                        thumbnailService:
                                            widget.thumbnailService,
                                        showRatings: true,
                                        showTagsCount: true,
                                        onTap: () =>
                                            _handleItemTap(imageId, index),
                                        onSecondaryTapUp: (details) {
                                          _hideContextMenu();
                                          if (!_selectedImages
                                              .contains(imageId)) {
                                            setState(() =>
                                                _selectedImages = {imageId});
                                            _shiftSelectionAnchorIndex = index;
                                          }
                                          _showContextMenu(
                                              context, details.globalPosition);
                                        },
                                      );
                                    },
                                    childCount: _associatedImages.length,
                                  ),
                                ),
                              ),
                        ..._buildSuggestionsSlivers(),
                        const SliverToBoxAdapter(child: SizedBox(height: 96)),
                      ],
                    ),
                  ),
                      ),
                      if (_selectedImages.isNotEmpty) _buildSelectionBar(),
                    ],
                  ),
          ),
        ],
      ),
      ),
    );
  }

  // --- SECCIÓN "SUGERENCIAS" ---
  List<Widget> _buildSuggestionsSlivers() {
    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 4),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () =>
                      setState(() => _showSuggestions = !_showSuggestions),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.auto_awesome,
                            size: 16, color: Color(0xFFFFD60A)),
                        const SizedBox(width: 8),
                        Text('Sugerencias (${_suggestions.length})',
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(width: 4),
                        Icon(
                            _showSuggestions
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            color: Colors.white54,
                            size: 18),
                      ],
                    ),
                  ),
                ),
              ),
              if (_showSuggestions)
                Flexible(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (_dismissedCount > 0)
                        TextButton(
                          onPressed: _restoreDismissed,
                          child: Text('Restaurar $_dismissedCount descartada(s)',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.white54)),
                        ),
                      if (_suggestions.any((s) => s.franchiseMatch) &&
                          !_suggestions.every((s) => s.franchiseMatch))
                        TextButton.icon(
                          onPressed: () =>
                              _linkAllSuggestions(onlyFranchise: true),
                          icon: const Icon(Icons.check_circle,
                              size: 14, color: Color(0xFF32D74B)),
                          label: Text(
                              'Vincular las verdes (${_suggestions.where((s) => s.franchiseMatch).length})',
                              style: const TextStyle(fontSize: 12)),
                        ),
                      if (_suggestions.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => _linkAllSuggestions(),
                          icon: const Icon(Icons.add_link, size: 16),
                          label: const Text('Vincular todas',
                              style: TextStyle(fontSize: 12)),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ];

    if (!_showSuggestions) return slivers;

    if (_suggestions.isEmpty) {
      slivers.add(const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Text(
              'No hay imágenes con una etiqueta de personaje parecida a este perfil '
              '(las etiquetas automáticas tienen la forma "nombre (franquicia)").',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ),
      ));
      return slivers;
    }

    final visible = _suggestions.take(_suggestionsVisible).toList();
    final allIds = _suggestions.map((s) => s.imageId).toList();

    slivers.add(SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: Text(
            'Imágenes aún sin vincular cuya etiqueta se parece a '
            '"${_selectedCharacter!.name}". La marca verde indica que la '
            'franquicia también coincide.',
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
      ),
    ));

    slivers.add(SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
 maxCrossAxisExtent: _thumbExtent,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) =>
              _buildSuggestionTile(visible[index], allIds),
          childCount: visible.length,
        ),
      ),
    ));

    if (_suggestions.length > visible.length) {
      slivers.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Center(
            child: TextButton(
              onPressed: () =>
                  setState(() => _suggestionsVisible += _kSuggestionsPageSize),
              child: Text(
                  'Mostrar más (${_suggestions.length - visible.length})',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ),
      ));
    }

    return slivers;
  }

  Widget _buildSuggestionTile(
      CharacterSuggestion suggestion, List<String> allSuggestedIds) {
    final file = File(p.join(widget.vaultRootPath, suggestion.imageId));

    return Stack(
      key: ValueKey('suggestion_${suggestion.imageId}'),
      fit: StackFit.expand,
      children: [
        ImageItemWidget(
          imageFile: file,
          imageId: suggestion.imageId,
          isSelected: false,
          extent: _thumbExtent,
          metadataService: widget.metadataService,
          thumbnailService: widget.thumbnailService,
          showRatings: false,
          showTagsCount: false,
          showProfile: false,
          onTap: () => _openImage(suggestion.imageId, source: allSuggestedIds),
          onSecondaryTapUp: (_) {},
        ),
        // Etiqueta que provocó la coincidencia
        Positioned(
          left: 6,
          right: 6,
          bottom: 6,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.65),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  if (suggestion.franchiseMatch) ...[
                    const Icon(Icons.check_circle,
                        size: 11, color: Color(0xFF32D74B)),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(suggestion.tag,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10)),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Botón para vincular esta imagen al perfil
        Positioned(
          top: 6,
          right: 6,
          child: Tooltip(
            message: 'Vincular a este perfil',
            child: Material(
              color: const Color(0xFF0A84FF),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _linkSuggestion(suggestion),
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.add_link, size: 16, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
        // Botón para descartar una sugerencia equivocada
        Positioned(
          top: 6,
          left: 6,
          child: Tooltip(
            message: 'Descartar sugerencia',
            child: Material(
              color: Colors.black.withOpacity(0.6),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _dismissSuggestion(suggestion),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(Icons.close, size: 14, color: Colors.white70),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAttribute(IconData icon, String label, String value) {
    if (value.isEmpty || value == 'Desconocido' || value == 'Desconocida')
      return const SizedBox.shrink();

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
            style: const TextStyle(
                color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
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
  final String? shortcut;

  const _ProfileContextMenuItem({
    required this.title,
    required this.icon,
    required this.onTap,
    this.isDestructive = false,
    this.shortcut,
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
            if (shortcut != null) ...[
              const SizedBox(width: 24),
              const Spacer(),
              Text(shortcut!,
                  style: const TextStyle(fontSize: 11, color: Colors.white38)),
            ],
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
  final bool isNew;
  final List<String> knownFranchises;

  const _GlobalCharacterEditDialog({
    required this.character,
    required this.metadataService,
    this.isNew = false,
    this.knownFranchises = const [],
  });

  @override
  State<_GlobalCharacterEditDialog> createState() =>
      _GlobalCharacterEditDialogState();
}

class _GlobalCharacterEditDialogState
    extends State<_GlobalCharacterEditDialog> {
  late TextEditingController _nameCtrl;
  late TextEditingController _franchiseCtrl;
  late TextEditingController _genderCtrl;
  late TextEditingController _ageCtrl;
  late TextEditingController _birthdayCtrl;
  final List<TextEditingController> _customKeysCtrls = [];
  final List<TextEditingController> _customValuesCtrls = [];

  String? _avatarPath;
  bool _nameError = false;

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
    _avatarPath = widget.character.avatarPath;
    _nameCtrl = TextEditingController(text: widget.character.name);
    _franchiseCtrl = TextEditingController(text: widget.character.franchise);
    _genderCtrl = TextEditingController(text: widget.character.gender);
    _ageCtrl = TextEditingController(text: widget.character.age);
    _birthdayCtrl = TextEditingController(text: widget.character.birthday);

    _nameCtrl.addListener(() {
      if (_nameError && _nameCtrl.text.trim().isNotEmpty && mounted) {
        setState(() => _nameError = false);
      }
    });
    // Para refrescar las franquicias existentes que se sugieren al escribir.
    _franchiseCtrl.addListener(() {
      if (mounted) setState(() {});
    });

    widget.character.customFields.forEach((k, v) {
      _customKeysCtrls.add(TextEditingController(text: k));
      _customValuesCtrls.add(TextEditingController(text: v));
    });
  }

  @override
  void dispose() {
    _editScrollController.dispose();
    _nameCtrl.dispose();
    _franchiseCtrl.dispose();
    _genderCtrl.dispose();
    _ageCtrl.dispose();
    _birthdayCtrl.dispose();
    for (var c in _customKeysCtrls) {
      c.dispose();
    }
    for (var c in _customValuesCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _nameError = true);
      return;
    }
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
      avatarPath: _avatarPath,
      customFields: customs,
    );

    Navigator.pop(context, updated);
  }

  void _openCropper(File imageFile) {
    showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AvatarCropperDialog(imageFile: imageFile),
    ).then((bytes) async {
      if (bytes != null) {
        final path = await widget.metadataService.saveAvatarImage(bytes);
        setState(() => _avatarPath = path);
      }
    });
  }

  void _pickAvatar() async {
    FilePickerResult? result =
        await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      _openCropper(File(result.files.single.path!));
    }
  }

  Widget _buildField(String label, TextEditingController ctrl) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6.0, left: 2.0),
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ),
          TextField(
            controller: ctrl,
            autofocus: widget.isNew && identical(ctrl, _nameCtrl),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.black26,
              errorText: (identical(ctrl, _nameCtrl) && _nameError)
                  ? 'El nombre es obligatorio'
                  : null,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none),
              errorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: Colors.redAccent, width: 1)),
              focusedErrorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      const BorderSide(color: Colors.redAccent, width: 1)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFranchiseSuggestions() {
    if (widget.knownFranchises.isEmpty) return const SizedBox.shrink();
    final q = normalizeForSearch(_franchiseCtrl.text.trim());
    final matches = widget.knownFranchises.where((f) {
      final n = normalizeForSearch(f);
      if (n == q) return false;
      return q.isEmpty || n.contains(q);
    }).take(5).toList();
    if (matches.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(q.isEmpty ? 'Frecuentes:' : 'Existentes:',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
          for (final f in matches)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                _franchiseCtrl.text = f;
                _franchiseCtrl.selection =
                    TextSelection.collapsed(offset: f.length);
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A84FF).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: const Color(0xFF0A84FF).withOpacity(0.4),
                      width: 0.5),
                ),
                child: Text(f,
                    style: const TextStyle(
                        color: Color(0xFF0A84FF), fontSize: 11.5)),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
      },
      child: Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16.0),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: 440,
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E).withOpacity(0.9),
              border: Border.all(color: Colors.white12, width: 0.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.isNew ? 'Nuevo Perfil' : 'Modificar Perfil',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 20),
                Flexible(
                  child: SingleChildScrollView(
                    controller: _editScrollController,
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: Stack(
                              children: [
                                Container(
                                  width: 80,
                                  height: 80,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.black26,
                                    border: Border.all(
                                        color: Colors.white24, width: 2),
                                    image: _avatarPath != null &&
                                            File(_avatarPath!).existsSync()
                                        ? DecorationImage(
                                            image:
                                                FileImage(File(_avatarPath!)),
                                            fit: BoxFit.cover)
                                        : null,
                                  ),
                                  child: _avatarPath == null
                                      ? const Icon(Icons.add_a_photo_outlined,
                                          color: Colors.white38, size: 30)
                                      : null,
                                ),
                                Positioned.fill(
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(40),
                                      onTap: _pickAvatar,
                                    ),
                                  ),
                                ),
                                if (_avatarPath != null)
                                  Positioned(
                                    bottom: 0,
                                    right: 0,
                                    child: GestureDetector(
                                      onTap: () =>
                                          setState(() => _avatarPath = null),
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: const BoxDecoration(
                                            color: Colors.redAccent,
                                            shape: BoxShape.circle),
                                        child: const Icon(Icons.close,
                                            size: 12, color: Colors.white),
                                      ),
                                    ),
                                  )
                              ],
                            ),
                          ),
                        ),
                        _buildField('Nombre *', _nameCtrl),
                        _buildField('Franquicia', _franchiseCtrl),
                        _buildFranchiseSuggestions(),
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
                            const Text('Campos Extra',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.white54,
                                    fontWeight: FontWeight.bold)),
                            TextButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _customKeysCtrls
                                        .add(TextEditingController());
                                    _customValuesCtrls
                                        .add(TextEditingController());
                                  });
                                  _scrollToBottomEdit();
                                },
                                icon: const Icon(Icons.add, size: 14),
                                label: const Text('Añadir',
                                    style: TextStyle(fontSize: 12)))
                          ],
                        ),
                        const SizedBox(height: 4),
                        ReorderableFieldsList(
                          keyControllers: _customKeysCtrls,
                          valueControllers: _customValuesCtrls,
                          parentScrollController: _editScrollController,
                          fieldBuilder: _buildField,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          controlsTopPadding: 26,
                          handleIconSize: 20,
                          deleteIconSize: 20,
                          onReorder: (oldIndex, newIndex) {
                            setState(() {
                              final keyCtrl = _customKeysCtrls.removeAt(oldIndex);
                              final valCtrl = _customValuesCtrls.removeAt(oldIndex);
                              _customKeysCtrls.insert(newIndex, keyCtrl);
                              _customValuesCtrls.insert(newIndex, valCtrl);
                            });
                          },
                          onRemove: (index) {
                            setState(() {
                              final keyCtrl = _customKeysCtrls.removeAt(index);
                              final valCtrl = _customValuesCtrls.removeAt(index);
                              keyCtrl.dispose();
                              valCtrl.dispose();
                            });
                          },
                        ),
                        if (_customKeysCtrls.isNotEmpty)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _customKeysCtrls
                                        .add(TextEditingController());
                                    _customValuesCtrls
                                        .add(TextEditingController());
                                  });
                                  _scrollToBottomEdit();
                                },
                                icon: const Icon(Icons.add, size: 12),
                                label: const Text('Añadir otro campo',
                                    style: TextStyle(fontSize: 11))),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancelar',
                            style: TextStyle(color: Colors.white70))),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0A84FF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Text(widget.isNew ? 'Crear' : 'Guardar'),
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
  }
}

// --- AVATAR CIRCULAR (miniatura ligera: no decodifica la foto completa) ---
class _AvatarCircle extends StatelessWidget {
  final String? path;
  final double size;
  final bool highlighted;

  const _AvatarCircle({
    required this.path,
    this.size = 36,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = path;
    final fallback =
        Icon(Icons.person, color: Colors.white38, size: size * 0.55);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black26,
        border: Border.all(
            color: highlighted ? const Color(0xFF0A84FF) : Colors.white24),
      ),
      child: ClipOval(
        child: (avatar == null || avatar.isEmpty)
            ? fallback
            : Image.file(
                File(avatar),
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: (size * 3).round(),
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}

// --- DIÁLOGO PARA FUSIONAR DOS PERFILES ---
class _MergeChoice {
  final LocalCharacter keep;
  final LocalCharacter remove;
  const _MergeChoice(this.keep, this.remove);
}

class _MergeProfilesDialog extends StatefulWidget {
  final LocalCharacter source;
  final List<LocalCharacter> candidates;
  final Map<int, int> imageCounts;
  final LocalCharacter? initial;

  const _MergeProfilesDialog({
    required this.source,
    required this.candidates,
    required this.imageCounts,
    this.initial,
  });

  @override
  State<_MergeProfilesDialog> createState() => _MergeProfilesDialogState();
}

class _MergeProfilesDialogState extends State<_MergeProfilesDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  LocalCharacter? _other;
  bool _keepOther = true; // true: se conserva el perfil elegido de la lista

  @override
  void initState() {
    super.initState();
    _other = widget.initial;
    _searchCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<LocalCharacter> _results() {
    final q = normalizeForSearch(_searchCtrl.text.trim());
    final list = q.isEmpty
        ? widget.candidates
        : widget.candidates
            .where((c) =>
                normalizeForSearch(c.name).contains(q) ||
                normalizeForSearch(c.franchise).contains(q))
            .toList();
    return list.take(60).toList();
  }

  Widget _mergeLine(
      IconData icon, Color color, String label, LocalCharacter c) {
    final franchise = c.franchise.trim();
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: '$label: ',
                  style: TextStyle(
                      color: color, fontSize: 12, fontWeight: FontWeight.w600)),
              TextSpan(
                  text: franchise.isEmpty ? c.name : '${c.name} · $franchise',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final other = _other;
    final LocalCharacter? keep =
        other == null ? null : (_keepOther ? other : widget.source);
    final LocalCharacter? remove =
        other == null ? null : (_keepOther ? widget.source : other);
    final results = _results();

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16.0),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: 460,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E).withOpacity(0.9),
              border: Border.all(color: Colors.white12, width: 0.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Fusionar perfiles',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 8),
                Text(
                    'Elige el perfil con el que quieres fusionar "${widget.source.name}".',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 16),
                TextField(
                  controller: _searchCtrl,
                  autofocus: widget.initial == null,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.black26,
                    hintText: 'Buscar perfil...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(Icons.search,
                        color: Colors.white54, size: 18),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 210,
                  child: Material(
                    type: MaterialType.transparency,
                    child: results.isEmpty
                        ? const Center(
                            child: Text('Sin resultados.',
                                style: TextStyle(color: Colors.white38)))
                        : ListView.builder(
                            itemCount: results.length,
                            itemBuilder: (context, i) {
                              final c = results[i];
                              final selected = _other?.id == c.id;
                              return InkWell(
                                onTap: () => setState(() => _other = c),
                                child: Container(
                                  color: selected
                                      ? const Color(0xFF0A84FF)
                                          .withOpacity(0.18)
                                      : Colors.transparent,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6),
                                  child: Row(
                                    children: [
                                      _AvatarCircle(
                                          path: c.avatarPath,
                                          size: 30,
                                          highlighted: selected),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(c.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 13)),
                                            if (c.franchise.trim().isNotEmpty)
                                              Text(c.franchise,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      color: Colors.white54,
                                                      fontSize: 11)),
                                          ],
                                        ),
                                      ),
                                      Text('${widget.imageCounts[c.id] ?? 0}',
                                          style: const TextStyle(
                                              color: Colors.white38,
                                              fontSize: 11)),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                if (keep != null && remove != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _mergeLine(Icons.check_circle_outline,
                                  const Color(0xFF32D74B), 'Se conserva', keep),
                              const SizedBox(height: 6),
                              _mergeLine(Icons.delete_outline,
                                  Colors.redAccent, 'Se elimina', remove),
                              const SizedBox(height: 8),
                              Text(
                                  'Sus ${widget.imageCounts[remove.id] ?? 0} imagen(es) pasarán a "${keep.name}". Los campos vacíos de "${keep.name}" se completarán con los de "${remove.name}".',
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 11)),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Intercambiar cuál se conserva',
                          icon: const Icon(Icons.swap_vert,
                              color: Colors.white70),
                          onPressed: () =>
                              setState(() => _keepOther = !_keepOther),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancelar',
                            style: TextStyle(color: Colors.white70))),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: (keep == null || remove == null)
                          ? null
                          : () => Navigator.pop(
                              context, _MergeChoice(keep, remove)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0A84FF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Fusionar'),
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
          throw Exception(
              "El archivo está bloqueado o dañado: $copyDeleteError");
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
  }
}