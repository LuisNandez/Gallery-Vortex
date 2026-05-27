// profile_editor_dialog.dart
import 'dart:convert';
import 'dart:ui';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'metadata_service.dart';
import 'ui_utils.dart';
import 'dart:math' as math;

const String IGDB_CLIENT_ID = 'wuzyxd094gsqnt9wlgjanuzk0vojwx';
const String IGDB_CLIENT_SECRET = '608hk69peja8xpf4nlmj2uze911nbz';
String? _igdbAccessToken; 

Future<void> _ensureIGDBToken() async {
  if (_igdbAccessToken != null) return;
  final url = Uri.parse('https://id.twitch.tv/oauth2/token?client_id=$IGDB_CLIENT_ID&client_secret=$IGDB_CLIENT_SECRET&grant_type=client_credentials');
  try {
    final response = await http.post(url);
    if (response.statusCode == 200) {
      _igdbAccessToken = jsonDecode(response.body)['access_token'];
    }
  } catch (e) {
    debugPrint('Excepción al conectar con Twitch: $e');
  }
}

String? _extractIgdbImage(dynamic imageField, String size) {
  if (imageField == null) return null;
  String? imageId;
  if (imageField is Map) imageId = imageField['image_id'];
  else if (imageField is List && imageField.isNotEmpty) imageId = imageField[0]['image_id'];
  return (imageId != null && imageId.isNotEmpty) ? 'https://images.igdb.com/igdb/image/upload/$size/$imageId.jpg' : null;
}

// --- APIS ONLINE ---
Future<List<Map<String, dynamic>>> searchAniListCharactersDirect(String queryText) async {
  const String url = 'https://graphql.anilist.co';
  const String query = r'query ($search: String) { Page(page: 1, perPage: 15) { characters(search: $search, sort: [SEARCH_MATCH, FAVOURITES_DESC]) { id name { full } gender age image { medium } media(sort: [POPULARITY_DESC], page: 1, perPage: 15) { edges { characterRole node { type title { romaji english } } } } } } }';
  try {
    final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'query': query, 'variables': {'search': queryText}}));
    if (res.statusCode == 200) return List<Map<String, dynamic>>.from(jsonDecode(res.body)['data']?['Page']?['characters'] ?? []);
  } catch (_) {}
  return [];
}

Future<List<Map<String, dynamic>>> searchAniListMedia(String queryText) async {
  const String url = 'https://graphql.anilist.co';
  const String query = r'query ($search: String) { Page(page: 1, perPage: 15) { media(search: $search, sort: [SEARCH_MATCH, POPULARITY_DESC]) { id title { romaji english } format startDate { year } coverImage { medium } } } }';
  try {
    final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'query': query, 'variables': {'search': queryText}}));
    if (res.statusCode == 200) return List<Map<String, dynamic>>.from(jsonDecode(res.body)['data']?['Page']?['media'] ?? []);
  } catch (_) {}
  return [];
}

Future<List<Map<String, dynamic>>> getCharactersFromMediaId(int mediaId) async {
  const String url = 'https://graphql.anilist.co';
  const String query = r'query ($id: Int) { Media(id: $id) { title { romaji english } characters(sort: [ROLE, RELEVANCE, FAVOURITES_DESC], page: 1, perPage: 50) { nodes { id name { full } gender age image { medium } } } } }';
  try {
    final res = await http.post(Uri.parse(url), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'query': query, 'variables': {'id': mediaId}}));
    if (res.statusCode == 200) {
      final mediaData = jsonDecode(res.body)['data']?['Media'];
      if (mediaData != null) {
        final title = mediaData['title'];
        final nodes = mediaData['characters']?['nodes'] as List?;
        if (nodes != null) return nodes.map((c) => Map<String, dynamic>.from(c)..['media'] = {'nodes': [{'title': title}]}).toList();
      }
    }
  } catch (_) {}
  return [];
}

Future<List<Map<String, dynamic>>> searchIGDBCharactersDirect(String queryText) async {
  await _ensureIGDBToken();
  if (_igdbAccessToken == null) return [];
  try {
    final res = await http.post(Uri.parse('https://api.igdb.com/v4/characters'), headers: {'Client-ID': IGDB_CLIENT_ID, 'Authorization': 'Bearer $_igdbAccessToken'}, body: 'search "$queryText"; fields name, gender, mug_shot.image_id, games.name; limit 15;');
    if (res.statusCode == 200) {
      return (jsonDecode(res.body) as List).map((char) {
        final games = char['games'];
        String franchise = (games is List && games.isNotEmpty) ? (games[0]['name'] ?? 'Juego') : 'Juego';
        return {'name': {'full': char['name']}, 'gender': char['gender'] == 1 ? 'Masculino' : char['gender'] == 2 ? 'Femenino' : 'Desconocido', 'age': 'Desconocida', 'image': {'medium': _extractIgdbImage(char['mug_shot'], 't_720p')}, 'media': {'nodes': [{'title': {'romaji': franchise}}]}};
      }).toList();
    }
  } catch (_) {}
  return [];
}

Future<List<Map<String, dynamic>>> searchIGDBMedia(String queryText) async {
  await _ensureIGDBToken();
  if (_igdbAccessToken == null) return [];
  try {
    final res = await http.post(Uri.parse('https://api.igdb.com/v4/games'), headers: {'Client-ID': IGDB_CLIENT_ID, 'Authorization': 'Bearer $_igdbAccessToken'}, body: 'search "$queryText"; fields name, cover.image_id, first_release_date; limit 15;');
    if (res.statusCode == 200) {
      return (jsonDecode(res.body) as List).map((game) {
        String year = game['first_release_date'] != null ? DateTime.fromMillisecondsSinceEpoch(game['first_release_date'] * 1000).year.toString() : 'N/A';
        return {'id': game['id'], 'title': {'romaji': game['name']}, 'format': 'Videojuego', 'startDate': {'year': year}, 'coverImage': {'medium': _extractIgdbImage(game['cover'], 't_cover_big')}};
      }).toList();
    }
  } catch (_) {}
  return [];
}

Future<List<Map<String, dynamic>>> getCharactersFromIGDBGameId(int gameId) async {
  await _ensureIGDBToken();
  if (_igdbAccessToken == null) return [];
  try {
    String gameName = 'Videojuego';
    final gRes = await http.post(Uri.parse('https://api.igdb.com/v4/games'), headers: {'Client-ID': IGDB_CLIENT_ID, 'Authorization': 'Bearer $_igdbAccessToken'}, body: 'fields name; where id = $gameId;');
    if (gRes.statusCode == 200) {
      final List gData = jsonDecode(gRes.body);
      if (gData.isNotEmpty) gameName = gData[0]['name'] ?? gameName;
    }
    final res = await http.post(Uri.parse('https://api.igdb.com/v4/characters'), headers: {'Client-ID': IGDB_CLIENT_ID, 'Authorization': 'Bearer $_igdbAccessToken'}, body: 'fields name, gender, mug_shot.image_id; where games = ($gameId); limit 50;');
    if (res.statusCode == 200) {
      return (jsonDecode(res.body) as List).map((char) => {'id': char['id'], 'name': {'full': char['name']}, 'gender': char['gender'] == 1 ? 'Masculino' : char['gender'] == 2 ? 'Femenino' : 'Desconocido', 'age': 'Desconocida', 'image': {'medium': _extractIgdbImage(char['mug_shot'], 't_720p')}, 'media': {'nodes': [{'title': {'romaji': gameName}}]}}).toList();
    }
  } catch (_) {}
  return [];
}

// --- INTERFAZ PRINCIPAL TRES PESTAÑAS ---
class ProfileEditorDialog extends StatefulWidget {
  final List<String> imageIds;
  final MetadataService metadataService;
  final String vaultRootPath;
  const ProfileEditorDialog({super.key, required this.imageIds, required this.metadataService, required this.vaultRootPath});

  @override
  State<ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

class _ProfileEditorDialogState extends State<ProfileEditorDialog> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<LocalCharacter> _localCharacters = [];
  List<LocalCharacter> _selectedCharacters = [];
  LocalCharacter? _editingCharacterTarget;
  bool _isEditingMode = false;
  bool _showBiographyMode = false;
  bool _initialModeSet = false;

  final ScrollController _manualScrollController = ScrollController();

  // Función para hacer el scroll animado
  void _scrollToBottomManual() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_manualScrollController.hasClients) {
        _manualScrollController.animateTo(
          _manualScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Formulario Manual
  String? _avatarPathCtrl;
  final _nameCtrl = TextEditingController();
  final _franchiseCtrl = TextEditingController();
  final _genderCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _birthdayCtrl = TextEditingController();
  final List<TextEditingController> _customKeysCtrls = [];
  final List<TextEditingController> _customValuesCtrls = [];
  final FocusNode _franchiseFocusNode = FocusNode();
  final FocusNode _genderFocusNode = FocusNode();
  final TextEditingController _localSearchCtrl = TextEditingController();
  List<LocalCharacter> _filteredLocalCharacters = [];

  List<String> get _availableFranchises {
    return _localCharacters
        .map((c) => c.franchise)
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  List<String> get _availableGenders {
    return _localCharacters
        .map((c) => c.gender)
        .where((s) => s.trim().isNotEmpty && s != 'Desconocido')
        .toSet()
        .toList()
      ..sort();
  }
  

  // Formulario de Búsqueda Online
  final _apiController = TextEditingController();
  bool _isSearchingAPI = false;
  bool _searchByFranchise = false;
  bool _isAnime = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {}); 
      }
    });
  
    _localSearchCtrl.addListener(_filterLocalCharacters);
    _loadLocalCharacters();
    _loadCurrentProfiles();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _manualScrollController.dispose();
    _nameCtrl.dispose();
    _franchiseCtrl.dispose();
    _genderCtrl.dispose();
    _ageCtrl.dispose();
    _birthdayCtrl.dispose();
    _apiController.dispose();
    _localSearchCtrl.dispose();
    for (var c in _customKeysCtrls) { c.dispose(); }
    for (var c in _customValuesCtrls) { c.dispose(); }
    super.dispose();
  }

  // ---> NUEVO: Función que filtra en tiempo real
  void _filterLocalCharacters() {
    final query = _localSearchCtrl.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredLocalCharacters = List.from(_localCharacters);
      } else {
        _filteredLocalCharacters = _localCharacters.where((c) {
          return c.name.toLowerCase().contains(query) ||
                 c.franchise.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  // ---> MODIFICADO: Actualizar la lista filtrada cada vez que se carga de la BD
  void _loadLocalCharacters() async {
    final chars = await widget.metadataService.getAllCharacters();
    setState(() {
      _localCharacters = chars;
      _filterLocalCharacters(); // Mantiene la lista sincronizada
    });
  }

  void _loadCurrentProfiles() async {
    if (widget.imageIds.isNotEmpty) {
      final meta = widget.metadataService.getMetadataForImage(widget.imageIds.first);
      List<LocalCharacter> temp = [];
      for (int id in meta.characterIds) {
        final char = await widget.metadataService.getCharacterById(id);
        if (char != null) temp.add(char);
      }
      
      setState(() {
        _selectedCharacters = temp;
        
        // ---> CORRECCIÓN AQUÍ: Usar _showBiographyMode, NO _isEditingMode.
        // La biografía solo se muestra si HAY personajes vinculados.
        if (!_initialModeSet) {
          _showBiographyMode = _selectedCharacters.isNotEmpty; 
          _initialModeSet = true;
        }
      });
    }
  }

  void _setupForm(LocalCharacter? target) {
    if (target != null) {
      _isEditingMode = true;
      _editingCharacterTarget = target;
      _avatarPathCtrl = target.avatarPath;
      _nameCtrl.text = target.name;
      _franchiseCtrl.text = target.franchise;
      _genderCtrl.text = target.gender;
      _ageCtrl.text = target.age;
      _birthdayCtrl.text = target.birthday;
      _customKeysCtrls.clear();
      _customValuesCtrls.clear();
      target.customFields.forEach((k, v) {
        _customKeysCtrls.add(TextEditingController(text: k));
        _customValuesCtrls.add(TextEditingController(text: v));
      });
    } else {
      _isEditingMode = false;
      _editingCharacterTarget = null;
      _avatarPathCtrl = null;
      _nameCtrl.clear();
      _franchiseCtrl.clear();
      _genderCtrl.text = 'Desconocido';
      _ageCtrl.text = 'Desconocida';
      _birthdayCtrl.text = 'Desconocido';
      _customKeysCtrls.clear();
      _customValuesCtrls.clear();
    }
    _tabController.animateTo(1);
  }

  void _saveForm() async {
    if (_nameCtrl.text.trim().isEmpty || _franchiseCtrl.text.trim().isEmpty) {
      showGlassSnackBar(context, 'Nombre y Franquicia son obligatorios.', icon: Icons.warning_amber_rounded, iconColor: Colors.amber);
      return;
    }
    Map<String, String> customs = {};
    for (int i = 0; i < _customKeysCtrls.length; i++) {
      final k = _customKeysCtrls[i].text.trim();
      final v = _customValuesCtrls[i].text.trim();
      if (k.isNotEmpty && v.isNotEmpty) customs[k] = v;
    }

    final charData = LocalCharacter(
      id: _isEditingMode ? _editingCharacterTarget?.id : null,
      name: _nameCtrl.text.trim(),
      franchise: _franchiseCtrl.text.trim(),
      gender: _genderCtrl.text.trim(),
      age: _ageCtrl.text.trim(),
      birthday: _birthdayCtrl.text.trim(),
      avatarPath: _avatarPathCtrl,
      customFields: customs,
    );

    int charId;
    if (_isEditingMode) {
      await widget.metadataService.updateCharacter(charData);
      charId = _editingCharacterTarget!.id!;
    } else {
      charId = await widget.metadataService.insertCharacter(charData);
    }

    for (final id in widget.imageIds) {
      await widget.metadataService.addCharacterToImage(id, charId);
    }
    
    _loadLocalCharacters();
    _loadCurrentProfiles();
    
    // ---> NUEVO: Limpiamos las variables de estado de edición
    setState(() {
      _isEditingMode = false;
      _editingCharacterTarget = null;
      _nameCtrl.clear();
      _franchiseCtrl.clear();
    });
    
    _tabController.animateTo(0);
    showGlassSnackBar(context, 'Personaje sincronizado con éxito.', icon: Icons.save);
  }

  void _toggleLinkCharacter(LocalCharacter char) async {
    final isLinked = _selectedCharacters.any((c) => c.id == char.id);
    for (final id in widget.imageIds) {
      if (isLinked) await widget.metadataService.removeCharacterFromImage(id, char.id!);
      else await widget.metadataService.addCharacterToImage(id, char.id!);
    }
    _loadCurrentProfiles();
  }

  // --- LÓGICA DE BÚSQUEDA INTERNET ---
  Future<void> _searchProfile(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _isSearchingAPI = true);
    if (_isAnime) {
      if (_searchByFranchise) {
        final list = await searchAniListMedia(query.trim());
        setState(() => _isSearchingAPI = false);
        if (list.isEmpty && mounted) showGlassSnackBar(context, 'No se encontró la franquicia.', icon: Icons.error_outline, iconColor: Colors.amber);
        else if (mounted) _showMediaSelectionDialog(list);
      } else {
        final list = await searchAniListCharactersDirect(query.trim());
        setState(() => _isSearchingAPI = false);
        if (list.isEmpty && mounted) showGlassSnackBar(context, 'No se encontró el personaje.', icon: Icons.error_outline, iconColor: Colors.amber);
        else if (mounted) _showCharacterSelectionDialog(list);
      }
    } else {
      if (_searchByFranchise) {
        final list = await searchIGDBMedia(query.trim());
        setState(() => _isSearchingAPI = false);
        if (list.isEmpty && mounted) showGlassSnackBar(context, 'No se encontró el videojuego.', icon: Icons.error_outline, iconColor: Colors.amber);
        else if (mounted) _showMediaSelectionDialog(list);
      } else {
        final list = await searchIGDBCharactersDirect(query.trim());
        setState(() => _isSearchingAPI = false);
        if (list.isEmpty && mounted) showGlassSnackBar(context, 'No se encontró el personaje.', icon: Icons.error_outline, iconColor: Colors.amber);
        else if (mounted) _showCharacterSelectionDialog(list);
      }
    }
  }

  void _showCharacterSelectionDialog(List<Map<String, dynamic>> characters) {
    showDialog(
      context: context,
      barrierColor: Colors.black45,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              width: 380,
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
              color: const Color(0xFF2C2C2E).withOpacity(0.85),
              child: ListView.separated(
                physics: const BouncingScrollPhysics(),
                itemCount: characters.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                itemBuilder: (context, idx) {
                  final char = characters[idx];
                  final name = char['name']?['full'] ?? 'Desconocido';
                  final imgUrl = char['image']?['medium'];
                  String franchise = 'Desconocido';
                  final nodes = char['media']?['nodes'] as List?;
                  if (nodes != null && nodes.isNotEmpty) {
                    franchise = nodes[0]['title']?['english'] ?? nodes[0]['title']?['romaji'] ?? franchise;
                  }
                  return ListTile(
                    leading: imgUrl != null ? ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.network(imgUrl, width: 40, height: 40, fit: BoxFit.cover)) : const Icon(Icons.person),
                    title: Text(name, style: const TextStyle(fontSize: 13, color: Colors.white)),
                    subtitle: Text(franchise, style: const TextStyle(fontSize: 11, color: Colors.white54)),
                    trailing: const Icon(Icons.file_download, color: Color(0xFF0A84FF), size: 18),
                    onTap: () async {
                      Navigator.pop(dialogContext);
                      // Inyectar inteligentemente a la base de datos local evitanto duplicados
                      var localChar = await widget.metadataService.findExistingCharacter(name, franchise);
                      if (localChar == null) {
                        final dynamicChar = LocalCharacter(
                          name: name,
                          franchise: franchise,
                          gender: char['gender'] ?? 'Desconocido',
                          age: char['age']?.toString().replaceAll(RegExp(r'-$'), '').trim() ?? 'Desconocida',
                          birthday: 'Desconocido'
                        );
                        int newId = await widget.metadataService.insertCharacter(dynamicChar);
                        localChar = LocalCharacter(id: newId, name: name, franchise: franchise);
                      }
                      for (final id in widget.imageIds) {
                        await widget.metadataService.addCharacterToImage(id, localChar.id!);
                      }
                      _loadLocalCharacters();
                      _loadCurrentProfiles();
                      _tabController.animateTo(0);
                      showGlassSnackBar(context, 'Perfil descargado e indexado.', icon: Icons.cloud_done_outlined);
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showMediaSelectionDialog(List<Map<String, dynamic>> mediaList) {
    showDialog(
      context: context,
      barrierColor: Colors.black45,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              width: 380,
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
              color: const Color(0xFF2C2C2E).withOpacity(0.85),
              child: ListView.separated(
                itemCount: mediaList.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                itemBuilder: (context, idx) {
                  final m = mediaList[idx];
                  final title = m['title']?['english'] ?? m['title']?['romaji'] ?? 'Desconocido';
                  return ListTile(
                    title: Text(title, style: const TextStyle(fontSize: 13, color: Colors.white)),
                    trailing: const Icon(Icons.chevron_right, color: Colors.white54),
                    onTap: () async {
                      Navigator.pop(dialogContext);
                      setState(() => _isSearchingAPI = true);
                      List<Map<String, dynamic>> chars = _isAnime ? await getCharactersFromMediaId(m['id']) : await getCharactersFromIGDBGameId(m['id']);
                      setState(() => _isSearchingAPI = false);
                      if (chars.isNotEmpty && mounted) _showCharacterSelectionDialog(chars);
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(String hint, TextEditingController ctrl) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white12)),
      child: TextField(
        controller: ctrl,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(hintText: hint, hintStyle: const TextStyle(color: Colors.white24), border: InputBorder.none),
      ),
    );
  }

  Widget _buildAutocompleteField(String hint, TextEditingController ctrl, FocusNode focusNode, List<String> suggestions) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.black26, 
        borderRadius: BorderRadius.circular(8), 
        border: Border.all(color: Colors.white12)
      ),
      child: RawAutocomplete<String>(
        textEditingController: ctrl,
        focusNode: focusNode,
        optionsBuilder: (TextEditingValue textEditingValue) {
          final pattern = textEditingValue.text.trim().toLowerCase();
          if (pattern.isEmpty) {
            // Si quieres que muestre todo al hacer clic sin escribir, cambia esto por: return suggestions;
            return const Iterable<String>.empty();
          }
          return suggestions.where((option) => option.toLowerCase().contains(pattern));
        },
        fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
          return TextField(
            controller: controller,
            focusNode: focusNode,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: hint, 
              hintStyle: const TextStyle(color: Colors.white24), 
              border: InputBorder.none
            ),
            onSubmitted: (String value) {
              onFieldSubmitted();
            },
          );
        },
        optionsViewBuilder: (context, onSelected, options) {
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 320, // Ajustado para encajar bien en el diálogo
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF252525),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12, width: 0.5),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 10, offset: const Offset(0, 4))
                  ]
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: options.length,
                    itemBuilder: (context, index) {
                      final option = options.elementAt(index);
                      return InkWell(
                        onTap: () => onSelected(option),
                        hoverColor: Colors.white.withOpacity(0.08),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: Text(option, style: const TextStyle(color: Colors.white, fontSize: 13)),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBiographyView() {
    if (_selectedCharacters.isEmpty) {
      return const Center(
        child: Text(
          'No hay perfiles asignados a esta imagen.',
          style: TextStyle(color: Colors.white38, fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: _selectedCharacters.length,
      itemBuilder: (context, index) {
        final char = _selectedCharacters[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Encabezado principal del personaje
              Row(
                children: [
                  Container(
                    width: 46, height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF0A84FF), width: 1.5),
                      image: char.avatarPath != null && File(char.avatarPath!).existsSync()
                          ? DecorationImage(image: FileImage(File(char.avatarPath!)), fit: BoxFit.cover)
                          : null,
                    ),
                    child: char.avatarPath == null || !File(char.avatarPath!).existsSync()
                        ? const Icon(Icons.person_outline, color: Color(0xFF0A84FF), size: 24)
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          char.name,
                          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          char.franchise,
                          style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10.0),
                child: Divider(color: Colors.white10, height: 1),
              ),
              // Detalles técnicos / Atributos
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  if (char.gender.isNotEmpty && char.gender != 'Desconocido')
                    _buildBioItem(Icons.wc, 'Género', char.gender),
                  if (char.age.isNotEmpty && char.age != 'Desconocida')
                    _buildBioItem(Icons.cake_outlined, 'Edad', char.age),
                  if (char.birthday.isNotEmpty && char.birthday != 'Desconocido')
                    _buildBioItem(Icons.calendar_month_outlined, 'Cumpleaños', char.birthday),
                ],
              ),
              // Campos personalizados dinámicos
              if (char.customFields.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Datos Adicionales:', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                ...char.customFields.entries.map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: Row(
                    children: [
                      Text('${e.key}: ', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      Expanded(child: Text(e.value, style: const TextStyle(color: Colors.white70, fontSize: 12))),
                    ],
                  ),
                )),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildBioItem(IconData icon, String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white38, size: 14),
        const SizedBox(width: 6),
        Text('$label: ', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
      ],
    );
  }

  void _showAvatarSourceMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF252525),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          border: Border.all(color: Colors.white12, width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.imageIds.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.image_outlined, color: Colors.white),
                title: const Text('Usar imagen actual seleccionada', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  final file = File(p.join(widget.vaultRootPath, widget.imageIds.first));
                  if (file.existsSync()) _openCropper(file);
                },
              ),
            ListTile(
              leading: const Icon(Icons.folder_open, color: Colors.white),
              title: const Text('Buscar en la galería (PC)', style: TextStyle(color: Colors.white)),
              onTap: () async {
                Navigator.pop(context);
                FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);
                if (result != null && result.files.single.path != null) {
                  _openCropper(File(result.files.single.path!));
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openCropper(File imageFile) {
    showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AvatarCropperDialog(imageFile: imageFile),
    ).then((bytes) async {
      if (bytes != null) {
        final path = await widget.metadataService.saveAvatarImage(bytes);
        setState(() => _avatarPathCtrl = path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Si aún no se ha decidido el modo inicial y ya hay personajes, mostramos la biografía.
    // (Puedes manejar esto también en _loadCurrentProfiles como vimos antes)
    final bool hasProfiles = _selectedCharacters.isNotEmpty;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            width: 460,
            height: MediaQuery.of(context).size.height * 0.8,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF252525).withOpacity(0.75), 
              border: Border.all(color: Colors.white12, width: 0.5)
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // --- CABECERA DINÁMICA CON BOTÓN DE VISTA ---
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          !_showBiographyMode ? Icons.people_outline_rounded : Icons.auto_stories_outlined, 
                          color: Colors.white70
                        ),
                        const SizedBox(width: 8),
                        Text(
                          !_showBiographyMode 
                              ? (widget.imageIds.length == 1 ? 'Gestionar Perfiles' : 'Perfiles (${widget.imageIds.length} archivos)')
                              : 'Biografía',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ],
                    ),
                    if (hasProfiles)
                      IconButton(
                        // ELIMINA LAS DOS LÍNEAS DE ABAJO:
                        // alignment: Alignment.centerRight,
                        // padding: EdgeInsets.zero,
                        
                        icon: Icon(
                          !_showBiographyMode ? Icons.auto_stories_outlined : Icons.edit_note_rounded, 
                          color: const Color(0xFF0A84FF),
                          size: 24, // Te sugiero 24 para que tenga el tamaño estándar de Material
                        ),
                        tooltip: !_showBiographyMode ? 'Ver Biografías' : 'Modificar Perfiles',
                        onPressed: () {
                          setState(() {
                            _showBiographyMode = !_showBiographyMode;
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),

                // --- CONTENIDO INTERMUTABLE ---
                Expanded(
                  child: !_showBiographyMode
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Chips de seleccionados (Solo visible en modo gestión)
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white12)),
                              child: _selectedCharacters.isEmpty
                                  ? const Center(child: Padding(padding: EdgeInsets.all(4.0), child: Text('Sin personajes vinculados.', style: TextStyle(color: Colors.white24, fontSize: 12))))
                                  : Wrap(
                                      spacing: 6, runSpacing: 6,
                                      children: _selectedCharacters.map((c) => InputChip(
                                        avatar: CircleAvatar(
                                        backgroundColor: Colors.black26,
                                        backgroundImage: c.avatarPath != null && File(c.avatarPath!).existsSync()
                                            ? FileImage(File(c.avatarPath!))
                                            : null,
                                        child: c.avatarPath == null || !File(c.avatarPath!).existsSync()
                                            ? const Icon(Icons.person, size: 14, color: Colors.white54)
                                            : null,
                                      ),
                                        label: Text('${c.name} (${c.franchise})', style: const TextStyle(fontSize: 11, color: Colors.white)),
                                        backgroundColor: const Color(0xFF0A84FF).withOpacity(0.2),
                                        onDeleted: () => _toggleLinkCharacter(c),
                                        deleteIconColor: Colors.redAccent,
                                      )).toList(),
                                    ),
                            ),
                            const SizedBox(height: 12),
                            TabBar(
                              controller: _tabController,
                              indicatorColor: const Color(0xFF0A84FF),
                              labelColor: const Color(0xFF0A84FF),
                              unselectedLabelColor: Colors.white38,
                              tabs: const [Tab(text: 'Librería Central'), Tab(text: 'Manual'), Tab(text: 'Internet (API)')],
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: TabBarView(
                                controller: _tabController,
                                children: [
                                  // --- PESTAÑA 1: LIBRERÍA LOCAL (CON BUSCADOR) ---
                                  Column(
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 12.0),
                                        child: TextField(
                                          controller: _localSearchCtrl,
                                          style: const TextStyle(color: Colors.white, fontSize: 13),
                                          decoration: InputDecoration(
                                            filled: true,
                                            fillColor: const Color(0xFF1C1C1E),
                                            prefixIcon: const Icon(Icons.search, color: Colors.white54, size: 18),
                                            suffixIcon: _localSearchCtrl.text.isNotEmpty
                                                ? IconButton(
                                                    icon: const Icon(Icons.cancel, color: Colors.white54, size: 16),
                                                    onPressed: () {
                                                      _localSearchCtrl.clear();
                                                      FocusScope.of(context).unfocus();
                                                    },
                                                  )
                                                : null,
                                            contentPadding: const EdgeInsets.symmetric(vertical: 0),
                                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                                            hintText: 'Buscar personaje o franquicia...',
                                            hintStyle: const TextStyle(color: Colors.white54),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: _localCharacters.isEmpty
                                            ? const Center(child: Text('Librería vacía.\nRegistra uno manualmente o búscalo online.', style: TextStyle(color: Colors.white38), textAlign: TextAlign.center))
                                            : _filteredLocalCharacters.isEmpty
                                                ? const Center(child: Text('No se encontraron coincidencias.', style: TextStyle(color: Colors.white54)))
                                                : ListView.separated(
                                                    physics: const BouncingScrollPhysics(),
                                                    itemCount: _filteredLocalCharacters.length,
                                                    separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                                                    itemBuilder: (context, idx) {
                                                      final char = _filteredLocalCharacters[idx];
                                                      final isLinked = _selectedCharacters.any((c) => c.id == char.id);
                                                      return ListTile(
                                                        contentPadding: EdgeInsets.zero,
                                                        leading: Container(
                                                          width: 36, height: 36,
                                                          decoration: BoxDecoration(
                                                            shape: BoxShape.circle,
                                                            color: Colors.black26,
                                                            border: Border.all(color: Colors.white24, width: 1),
                                                            image: char.avatarPath != null && File(char.avatarPath!).existsSync()
                                                                ? DecorationImage(image: FileImage(File(char.avatarPath!)), fit: BoxFit.cover)
                                                                : null,
                                                          ),
                                                          child: char.avatarPath == null || !File(char.avatarPath!).existsSync()
                                                              ? const Icon(Icons.person, color: Colors.white38, size: 20)
                                                              : null,
                                                        ),
                                                        title: Text(char.name, style: const TextStyle(color: Colors.white, fontSize: 13)),
                                                        subtitle: Text(char.franchise, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                                                        trailing: Row(
                                                          mainAxisSize: MainAxisSize.min,
                                                          children: [
                                                            IconButton(icon: const Icon(Icons.edit_note, color: Colors.white60, size: 18), onPressed: () => _setupForm(char)),
                                                            IconButton(
                                                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                                              tooltip: 'Eliminar perfil',
                                                              onPressed: () async {
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
                                                                                '¿Borrar a "${char.name}"?\nSe desvinculará permanentemente de todas las imágenes.',
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
                                                                                    child: const Text('Eliminar', style: TextStyle(fontWeight: FontWeight.w600)),
                                                                                  ),
                                                                                ],
                                                                              ),
                                                                            ],
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ) ?? false;

                                                                // Solo elimina si el usuario confirmó
                                                                if (confirm) {
                                                                  await widget.metadataService.deleteCharacter(char.id!);
                                                                  _loadLocalCharacters(); 
                                                                  _loadCurrentProfiles();
                                                                  
                                                                  if (mounted) {
                                                                    showGlassSnackBar(context, 'Perfil eliminado correctamente.', icon: Icons.delete_outline);
                                                                  }
                                                                }
                                                              },
                                                            ),
                                                            Checkbox(value: isLinked, activeColor: const Color(0xFF0A84FF), onChanged: (_) => _toggleLinkCharacter(char))
                                                          ],
                                                        ),
                                                      );
                                                    },
                                                  ),
                                      ),
                                    ],
                                  ),

                                  // --- PESTAÑA 2: FORMULARIO MANUAL (CON AUTOCOMPLETADO) ---
                                  SingleChildScrollView(
                                    controller: _manualScrollController,
                                    physics: const BouncingScrollPhysics(),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(_isEditingMode ? 'Modificando entrada' : 'Nueva Entrada', style: const TextStyle(color: Color(0xFF0A84FF), fontWeight: FontWeight.bold, fontSize: 12)),
                                            if (_isEditingMode) TextButton(onPressed: () => setState(() => _setupForm(null)), child: const Text('Limpiar / Crear Nuevo', style: TextStyle(fontSize: 11)))
                                          ],
                                        ),

                                        Center(
                                          child: Padding(
                                            padding: const EdgeInsets.only(bottom: 16), // <-- EL MARGEN AHORA ESTÁ AFUERA DEL STACK
                                            child: Stack(
                                              children: [
                                                Container(
                                                  width: 80, height: 80,
                                                  // <-- MARGEN ELIMINADO AQUÍ
                                                  alignment: Alignment.center,
                                                  decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: Colors.black26,
                                                    border: Border.all(color: Colors.white24, width: 2),
                                                    image: _avatarPathCtrl != null && File(_avatarPathCtrl!).existsSync()
                                                        ? DecorationImage(image: FileImage(File(_avatarPathCtrl!)), fit: BoxFit.cover)
                                                        : null,
                                                  ),
                                                  child: _avatarPathCtrl == null 
                                                      ? const Icon(Icons.add_a_photo_outlined, color: Colors.white38, size: 30)
                                                      : null,
                                                ),
                                                Positioned.fill(
                                                  child: Material(
                                                    color: Colors.transparent,
                                                    child: InkWell(
                                                      borderRadius: BorderRadius.circular(40), // Ahora encaja en un 80x80 perfecto
                                                      onTap: () => _showAvatarSourceMenu(),
                                                    ),
                                                  ),
                                                ),
                                                if (_avatarPathCtrl != null)
                                                  Positioned(
                                                    bottom: 0, right: 0, // <-- Ajustado a 0 para que no flote fuera del círculo
                                                    child: GestureDetector(
                                                      onTap: () => setState(() => _avatarPathCtrl = null),
                                                      child: Container(
                                                        padding: const EdgeInsets.all(4),
                                                        decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
                                                        child: const Icon(Icons.close, size: 12, color: Colors.white),
                                                      ),
                                                    ),
                                                  )
                                              ],
                                            ),
                                          ),
                                        ),
                                        
                                        _buildTextField('Nombre del Personaje *', _nameCtrl),
                                        
                                        // Integración de los campos con autocompletado
                                        _buildAutocompleteField('Franquicia / Origen *', _franchiseCtrl, _franchiseFocusNode, _availableFranchises),
                                        _buildAutocompleteField('Género', _genderCtrl, _genderFocusNode, _availableGenders),
                                        
                                        _buildTextField('Edad', _ageCtrl),
                                        _buildTextField('Cumpleaños (Opcional)', _birthdayCtrl),
                                        const SizedBox(height: 8),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            const Text('Campos Extra Personalizados', style: TextStyle(fontSize: 12, color: Colors.white54)),
                                            TextButton.icon(onPressed: () => setState(() { _customKeysCtrls.add(TextEditingController()); _customValuesCtrls.add(TextEditingController()); _scrollToBottomManual();}), icon: const Icon(Icons.add, size: 12), label: const Text('Añadir campo', style: TextStyle(fontSize: 11)))
                                          ],
                                        ),
                                        ...List.generate(_customKeysCtrls.length, (idx) => Row(
                                          children: [
                                            Expanded(child: _buildTextField('Propiedad', _customKeysCtrls[idx])),
                                            const SizedBox(width: 4),
                                            Expanded(child: _buildTextField('Valor', _customValuesCtrls[idx])),
                                            IconButton(icon: const Icon(Icons.remove_circle, color: Colors.redAccent, size: 16), onPressed: () => setState(() { _customKeysCtrls.removeAt(idx).dispose(); _customValuesCtrls.removeAt(idx).dispose(); }))
                                          ],
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
                                                _scrollToBottomManual(); // <-- AÑADE ESTO
                                              }, 
                                              icon: const Icon(Icons.add, size: 12), 
                                              label: const Text('Añadir otro campo', style: TextStyle(fontSize: 11))
                                            ),
                                          ),
                                        const SizedBox(height: 12),
                                      ],
                                    ),
                                  ),

                                  // --- PESTAÑA 3: CLOUD ENGINE (SIN CAMBIOS) ---
                                  SingleChildScrollView(
                                    child: Column(
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(child: ChoiceChip(label: const Center(child: Text('Anime (AniList)')), selected: _isAnime, onSelected: (s) => setState(() => _isAnime = s))),
                                            const SizedBox(width: 6),
                                            Expanded(child: ChoiceChip(label: const Center(child: Text('Juegos (IGDB)')), selected: !_isAnime, onSelected: (s) => setState(() => _isAnime = !s))),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            Expanded(child: ChoiceChip(label: const Center(child: Text('Por Personaje')), selected: !_searchByFranchise, onSelected: (s) => setState(() => _searchByFranchise = !s))),
                                            const SizedBox(width: 6),
                                            Expanded(child: ChoiceChip(label: Center(child: Text(_isAnime ? 'Por Franquicia' : 'Por Juego')), selected: _searchByFranchise, onSelected: (s) => setState(() => _searchByFranchise = s))),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8),
                                          decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
                                          child: Row(
                                            children: [
                                              Expanded(child: TextField(controller: _apiController, style: const TextStyle(color: Colors.white, fontSize: 13), decoration: const InputDecoration(hintText: 'Ingresa los términos...', border: InputBorder.none), onSubmitted: _searchProfile)),
                                              if (_isSearchingAPI) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                              else IconButton(icon: const Icon(Icons.search, color: Color(0xFF0A84FF)), onPressed: () => _searchProfile(_apiController.text))
                                            ],
                                          ),
                                        )
                                      ],
                                    ),
                                  )
                                ],
                              ),
                            ),
                          ],
                        )
                      : _buildBiographyView(), // Llama a tu función constructora de la biografía
                ),
                
                const SizedBox(height: 12),
                // --- BOTÓN DE SALIDA DINÁMICO ---
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        // Si estamos en la pestaña Manual (índice 1) y no estamos viendo la biografía, ejecuta el guardado
                        if (!_showBiographyMode && _tabController.index == 1) {
                          _saveForm();
                        } else if (!_showBiographyMode && hasProfiles) {
                          setState(() => _showBiographyMode = true);
                        } else {
                          Navigator.pop(context);
                        }
                      }, 
                      child: Text(
                        (!_showBiographyMode && _tabController.index == 1)
                            ? 'Guardar'
                            : ((!_showBiographyMode && hasProfiles) ? 'Ver Biografía' : 'Finalizar Gestión'), 
                        style: const TextStyle(color: Color(0xFF0A84FF), fontWeight: FontWeight.bold)
                      )
                    )
                  ],
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- CROPPER MÁGICO INTERACTIVO ---
class _AvatarCropperDialog extends StatefulWidget {
  final File imageFile;
  const _AvatarCropperDialog({required this.imageFile});

  @override
  State<_AvatarCropperDialog> createState() => _AvatarCropperDialogState();
}

class _AvatarCropperDialogState extends State<_AvatarCropperDialog> {
  final GlobalKey _boundaryKey = GlobalKey();
  final TransformationController _transformController = TransformationController();
  bool _isProcessing = false;
  
  // Rango de zoom
  double _currentScale = 1.0;
  final double _minScale = 0.05;
  final double _maxScale = 6.0;

  @override
  void initState() {
    super.initState();
    // Escuchamos los gestos manuales para mover el slider automáticamente
    _transformController.addListener(_onZoomChanged);
  }

  @override
  void dispose() {
    _transformController.removeListener(_onZoomChanged);
    _transformController.dispose();
    super.dispose();
  }

  void _onZoomChanged() {
    final scale = _transformController.value.getMaxScaleOnAxis();
    // Solo actualizamos el estado si el cambio es notable para evitar redibujados excesivos
    if ((scale - _currentScale).abs() > 0.01) {
      setState(() {
        _currentScale = scale.clamp(_minScale, _maxScale);
      });
    }
  }

  void _setZoom(double targetScale) {
    final matrix = _transformController.value.clone();
    final currentScale = matrix.getMaxScaleOnAxis();
    if (currentScale == 0) return;
    
    final scaleFactor = targetScale / currentScale;

    // Calculamos el centro del contenedor (Mide 200x200 según el ClipOval)
    const double centerX = 100.0;
    const double centerY = 100.0;

    // Extraemos la traslación (paneo) actual
    double dx = matrix.getTranslation().x;
    double dy = matrix.getTranslation().y;

    // Matemática matricial: Ajustamos la posición para que el zoom provenga desde el centro
    double newDx = centerX - (centerX - dx) * scaleFactor;
    double newDy = centerY - (centerY - dy) * scaleFactor;

    // Aplicamos la nueva escala
    matrix.setEntry(0, 0, targetScale);
    matrix.setEntry(1, 1, targetScale);
    matrix.setEntry(2, 2, targetScale);
    
    // Aplicamos el nuevo paneo
    matrix.setTranslationRaw(newDx, newDy, 0.0);

    _transformController.value = matrix;
  }

  Future<void> _captureAndCrop() async {
    setState(() => _isProcessing = true);
    try {
      // 1. Capturamos EXACTAMENTE lo que está dentro del círculo (RepaintBoundary)
      final boundary = _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      // Le damos pixelRatio 2.0 para que el avatar tenga alta resolución (aprox 400x400)
      final image = await boundary.toImage(pixelRatio: 2.0); 
      final byteData = await image.toByteData(format: ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();

      if (mounted) Navigator.pop(context, pngBytes);
    } catch (e) {
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        width: 350,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF252525),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12, width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Encuadrar Avatar', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Desliza y haz zoom para centrar el rostro.', style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 20),
            
            // El Lienzo Mágico
            RepaintBoundary(
              key: _boundaryKey,
              child: ClipOval(
                child: Container(
                  width: 200, height: 200,
                  color: Colors.black, // Fondo negro por si achica mucho la imagen
                  child: InteractiveViewer(
                    transformationController: _transformController,
                    minScale: _minScale,
                    maxScale: _maxScale,
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    constrained: false, // Permite mover la imagen libremente
                    child: Image.file(widget.imageFile),
                  ),
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // --- NUEVO: SLIDER DE PRECISIÓN ---
            Row(
              children: [
                const Icon(Icons.zoom_out, color: Colors.white54, size: 18),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2.0,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                      activeTrackColor: const Color(0xFF0A84FF),
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      // Convertimos la escala a logaritmo natural para el Slider
                      value: math.log(_currentScale),
                      min: math.log(_minScale),
                      max: math.log(_maxScale),
                      onChanged: (value) {
                        // Convertimos de vuelta a escala real usando exponencial
                        final newScale = math.exp(value);
                        setState(() => _currentScale = newScale);
                        _setZoom(newScale); 
                      },
                    ),
                  ),
                ),
                const Icon(Icons.zoom_in, color: Colors.white54, size: 18),
              ],
            ),
            
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: _isProcessing ? null : () => Navigator.pop(context),
                  child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
                ),
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _captureAndCrop,
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0A84FF), foregroundColor: Colors.white),
                  icon: _isProcessing 
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
                      : const Icon(Icons.crop, size: 18),
                  label: Text(_isProcessing ? 'Guardando...' : 'Recortar'),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}