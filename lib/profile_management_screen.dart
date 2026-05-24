import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'metadata_service.dart';
import 'thumbnail_service.dart';
import 'main.dart'; 
import 'ui_utils.dart';

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

  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCharacters();
    _searchCtrl.addListener(_filterCharacters);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
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
      
      // Si el personaje seleccionado ya no está en la lista filtrada o fue borrado, deseleccionar
      if (_selectedCharacter != null && !_filteredCharacters.any((c) => c.id == _selectedCharacter!.id)) {
        _selectCharacter(null);
      } else if (_selectedCharacter != null) {
        // Actualizar datos del personaje seleccionado en caso de que haya sido editado
        _selectedCharacter = _filteredCharacters.firstWhere((c) => c.id == _selectedCharacter!.id);
      }
    });
  }

  void _selectCharacter(LocalCharacter? char) {
    setState(() {
      _selectedCharacter = char;
      if (char != null) {
        _associatedImages = widget.metadataService.getImagesForCharacter(char.id!);
      } else {
        _associatedImages = [];
      }
    });
  }

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

  void _openImage(int index) {
    if (_associatedImages.isEmpty) return;

    final imageFiles = _associatedImages
        .map((id) => File(p.join(widget.vaultRootPath, id)))
        .where((file) => file.existsSync()) // Seguridad extra
        .toList();

    if (imageFiles.isEmpty) return;

    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        opaque: false,
        pageBuilder: (context, _, __) => FullScreenImageViewer(
          imageFiles: imageFiles,
          initialIndex: index,
          exportCallback: (file) async {}, // Puedes conectar tu función de exportación aquí
          onClose: () => Navigator.pop(context),
          metadataService: widget.metadataService,
          vaultRootPath: widget.vaultRootPath,
        ),
      ),
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
          // --- PANEL IZQUIERDO: LISTA DE PERSONAJES ---
          Container(
            width: 320,
            decoration: const BoxDecoration(
              color: Color(0xFF151515),
              border: Border(right: BorderSide(color: Colors.white12, width: 1)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
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
                Expanded(
                  child: _filteredCharacters.isEmpty
                      ? const Center(child: Text('No hay perfiles.', style: TextStyle(color: Colors.white54)))
                      : ListView.separated(
                          physics: const BouncingScrollPhysics(),
                          itemCount: _filteredCharacters.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16, color: Colors.white12),
                          itemBuilder: (context, index) {
                            final char = _filteredCharacters[index];
                            final isSelected = _selectedCharacter?.id == char.id;
                            
                            return ListTile(
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
                              // SOLUCIÓN DESBORDE HORIZONTAL: maxLines y overflow
                              title: Text(char.name, style: const TextStyle(fontSize: 13, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(char.franchise, style: const TextStyle(fontSize: 11, color: Colors.white54), maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () => _selectCharacter(char),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),

          // --- PANEL DERECHO: DETALLES E IMÁGENES (AHORA SCROLLABLE COMPLETO) ---
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
                : CustomScrollView(
                    physics: const BouncingScrollPhysics(),
                    slivers: [
                      // SOLUCIÓN DESBORDE VERTICAL: La cabecera ahora es parte del Scroll
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
                                        ..._selectedCharacter!.customFields.entries.map((e) => _buildAttribute(Icons.info_outline, e.key, e.value)),
                                      ],
                                    ),
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
                                  maxCrossAxisExtent: 160,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  childAspectRatio: 1,
                                ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    final file = File(p.join(widget.vaultRootPath, _associatedImages[index]));
                                    return GestureDetector(
                                      onTap: () => _openImage(index),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: Colors.white12),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: FutureBuilder<File>(
                                            future: widget.thumbnailService.getThumbnail(file),
                                            builder: (context, snapshot) {
                                              if (!snapshot.hasData) {
                                                return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)));
                                              }
                                              return Image.file(snapshot.data!, fit: BoxFit.cover);
                                            },
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                  childCount: _associatedImages.length,
                                ),
                              ),
                            ),
                      // Margen extra al final para que no quede pegado al borde inferior
                      const SliverToBoxAdapter(child: SizedBox(height: 32)),
                    ],
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
      avatarPath: widget.character.avatarPath, // Mantener el original por ahora
      customFields: customs,
    );

    Navigator.pop(context, updated);
  }

  Widget _buildField(String label, TextEditingController ctrl) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: TextField(
        controller: ctrl,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54),
          filled: true,
          fillColor: Colors.black26,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
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
            width: 400,
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E).withOpacity(0.9),
              border: Border.all(color: Colors.white12, width: 0.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min, // SOLUCIÓN: Ajustarse al contenido
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Modificar Perfil', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 20),
                // SOLUCIÓN: Cambiado de Expanded a Flexible
                Flexible(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildField('Nombre *', _nameCtrl),
                        _buildField('Franquicia *', _franchiseCtrl),
                        _buildField('Género', _genderCtrl),
                        _buildField('Edad', _ageCtrl),
                        _buildField('Cumpleaños', _birthdayCtrl),
                        
                        const Divider(color: Colors.white12, height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Campos Extra', style: TextStyle(fontSize: 13, color: Colors.white54)),
                            TextButton.icon(
                              onPressed: () => setState(() { _customKeysCtrls.add(TextEditingController()); _customValuesCtrls.add(TextEditingController()); }), 
                              icon: const Icon(Icons.add, size: 14), 
                              label: const Text('Añadir', style: TextStyle(fontSize: 12))
                            )
                          ],
                        ),
                        ...List.generate(_customKeysCtrls.length, (idx) => Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Row(
                            children: [
                              Expanded(child: _buildField('Propiedad', _customKeysCtrls[idx])),
                              const SizedBox(width: 8),
                              Expanded(child: _buildField('Valor', _customValuesCtrls[idx])),
                              IconButton(icon: const Icon(Icons.remove_circle, color: Colors.redAccent, size: 20), onPressed: () => setState(() { _customKeysCtrls.removeAt(idx).dispose(); _customValuesCtrls.removeAt(idx).dispose(); }))
                            ],
                          ),
                        )),
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
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0A84FF), foregroundColor: Colors.white),
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