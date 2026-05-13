import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'metadata_service.dart';
import 'ui_utils.dart';

Future<List<Map<String, dynamic>>> searchAniListCharacters(String characterName) async {
  const String url = 'https://graphql.anilist.co';
  const String query = '''
    query (\$search: String) {
      Page(page: 1, perPage: 5) {
        characters(search: \$search, sort: [SEARCH_MATCH, FAVOURITES_DESC]) {
          id
          name { full }
          gender
          age
          media(sort: POPULARITY_DESC, type: ANIME, page: 1, perPage: 1) {
            nodes { title { romaji english } }
          }
        }
      }
    }
  ''';

  try {
    final response = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
      body: jsonEncode({'query': query, 'variables': {'search': characterName}}),
    );

    if (response.statusCode == 200) {
      final characters = jsonDecode(response.body)['data']?['Page']?['characters'] as List?;
      if (characters != null) return List<Map<String, dynamic>>.from(characters);
    }
  } catch (_) {}
  return [];
}

class ProfileEditorDialog extends StatefulWidget {
  final List<String> imageIds;
  final MetadataService metadataService;

  const ProfileEditorDialog({super.key, required this.imageIds, required this.metadataService});

  @override
  State<ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

class _ProfileEditorDialogState extends State<ProfileEditorDialog> {
  final TextEditingController _aniListController = TextEditingController();
  bool _isSearchingAniList = false;
  Map<String, String>? _currentProfile;

  @override
  void initState() {
    super.initState();
    // Cargamos el perfil de la primera imagen seleccionada (si existe)
    if (widget.imageIds.isNotEmpty) {
      final profile = widget.metadataService.getMetadataForImage(widget.imageIds.first).profile;
      if (profile.isNotEmpty) {
        _currentProfile = Map.from(profile);
      }
    }
  }

  @override
  void dispose() {
    _aniListController.dispose();
    super.dispose();
  }

  Future<void> _searchAniList(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _isSearchingAniList = true);
    final characters = await searchAniListCharacters(query.trim());
    setState(() => _isSearchingAniList = false);

    if (characters.isEmpty) {
      if (mounted) showGlassSnackBar(context, 'No encontrado en AniList.', icon: Icons.error_outline, iconColor: Colors.amber);
      return;
    }

    if (mounted) _showCharacterSelectionDialog(characters);
  }

  void _showCharacterSelectionDialog(List<Map<String, dynamic>> characters) {
    showDialog(
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
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
                decoration: BoxDecoration(
                  color: const Color(0xFF2C2C2E).withOpacity(0.8),
                  border: Border.all(color: Colors.white12, width: 0.5),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: characters.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                  itemBuilder: (context, index) {
                    final char = characters[index];
                    final name = char['name']?['full'] ?? 'Desconocido';
                    String franchise = 'Franquicia desconocida';
                    final mediaNodes = char['media']?['nodes'] as List?;
                    if (mediaNodes != null && mediaNodes.isNotEmpty) {
                      franchise = mediaNodes[0]['title']['english'] ?? mediaNodes[0]['title']['romaji'] ?? franchise;
                    }

                    return ListTile(
                      title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 14)),
                      subtitle: Text(franchise, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      trailing: const Icon(Icons.download, color: Color(0xFF0A84FF), size: 20),
                      onTap: () {
                        Navigator.pop(context); // Cierra selección
                        _saveProfileToImages({
                          'name': name,
                          'franchise': franchise,
                          'gender': char['gender'] ?? 'Desconocido',
                          'age': char['age'] ?? 'Desconocida',
                        });
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _saveProfileToImages(Map<String, String> newProfile) {
    setState(() => _currentProfile = newProfile);
    for (final id in widget.imageIds) {
      widget.metadataService.setProfileForImage(id, newProfile);
    }
    _aniListController.clear();
    showGlassSnackBar(context, 'Perfil actualizado', icon: Icons.person_add);
  }

  void _clearProfile() {
    setState(() => _currentProfile = null);
    for (final id in widget.imageIds) {
      widget.metadataService.setProfileForImage(id, {});
    }
    showGlassSnackBar(context, 'Perfil removido', icon: Icons.delete_outline, iconColor: Colors.redAccent);
  }

  Widget _buildProfileDataRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w600, fontSize: 13))),
          Expanded(child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 13))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12.0),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            width: 340,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF252525).withOpacity(0.65),
              border: Border.all(color: Colors.white12, width: 0.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.person_outline, color: Colors.white54),
                    SizedBox(width: 8),
                    Text('Perfil del Personaje', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white)),
                  ],
                ),
                const SizedBox(height: 20),
                
                // Barra de búsqueda de AniList
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A84FF).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF0A84FF).withOpacity(0.5), width: 1),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.auto_awesome, color: Color(0xFF0A84FF), size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _aniListController,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: const InputDecoration(
                            hintText: 'Buscar en AniList...',
                            hintStyle: TextStyle(color: Colors.white54, fontSize: 13),
                            border: InputBorder.none,
                          ),
                          onSubmitted: _searchAniList,
                        ),
                      ),
                      if (_isSearchingAniList)
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A84FF)))
                      else
                        IconButton(icon: const Icon(Icons.search, color: Color(0xFF0A84FF), size: 20), onPressed: () => _searchAniList(_aniListController.text))
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Tarjeta de Perfil
                if (_currentProfile != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildProfileDataRow('Nombre:', _currentProfile!['name'] ?? ''),
                        _buildProfileDataRow('Franquicia:', _currentProfile!['franchise'] ?? ''),
                        _buildProfileDataRow('Género:', _currentProfile!['gender'] ?? ''),
                        _buildProfileDataRow('Edad:', _currentProfile!['age'] ?? ''),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _clearProfile,
                            icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                            label: const Text('Borrar perfil', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                          ),
                        )
                      ],
                    ),
                  )
                ] else ...[
                  const Center(child: Text('Sin perfil asignado.', style: TextStyle(color: Colors.white54))),
                ],
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cerrar', style: TextStyle(color: Color(0xFF0A84FF), fontWeight: FontWeight.bold)),
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}