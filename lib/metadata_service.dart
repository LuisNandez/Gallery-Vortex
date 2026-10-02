// metadata_service.dart
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'ui_utils.dart' show normalizeForSearch;
import 'search_ranking.dart';

class LocalCharacter {
  final int? id;
  String name;
  String franchise;
  String gender;
  String age;
  String birthday;
  String? avatarPath;
  Map<String, String> customFields;

  LocalCharacter({
    this.id,
    required this.name,
    required this.franchise,
    this.gender = 'Desconocido',
    this.age = 'Desconocida',
    this.birthday = 'Desconocido',
    this.avatarPath,
    Map<String, String>? customFields,
  }) : customFields = customFields ?? {};

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'franchise': franchise,
      'gender': gender,
      'age': age,
      'birthday': birthday,
      'avatar_path': avatarPath,
      'custom_fields': jsonEncode(customFields),
    };
  }

  factory LocalCharacter.fromMap(Map<String, dynamic> map) {
    return LocalCharacter(
      id: map['id'] as int?,
      name: map['name'] as String,
      franchise: map['franchise'] as String,
      gender: map['gender'] as String? ?? 'Desconocido',
      age: map['age'] as String? ?? 'Desconocida',
      birthday: map['birthday'] as String? ?? 'Desconocido',
      avatarPath: map['avatar_path'] as String?,
      customFields: map['custom_fields'] != null
          ? Map<String, String>.from(jsonDecode(map['custom_fields'] as String))
          : {},
    );
  }
}

class ImageMetadata {
  List<String> tags;
  int rating;
  int addedTimestamp;
  List<int> characterIds; // Soporta múltiples personajes relacionales
  Map<String, String> profile; // Mantenido por retrocompatibilidad estructurada

  ImageMetadata({
    List<String>? tags,
    this.rating = 0,
    this.addedTimestamp = 0,
    List<int>? characterIds,
    Map<String, String>? profile,
  }) : tags = tags ?? [],
       characterIds = characterIds ?? [],
       profile = profile ?? {};
}

class MetadataService {
  static final MetadataService _instance = MetadataService._internal();
  factory MetadataService() => _instance;
  MetadataService._internal();

  final Map<String, ImageMetadata> _imageData = {};
  List<String> _allTags = [];
  final Map<int, LocalCharacter> _charactersCache = {};

  // Índice de búsqueda: por imagen, un único texto ya normalizado (sin
  // acentos, minúsculas) con sus etiquetas, campos de perfil y personajes.
  // Se construye la primera vez que se busca y se invalida al modificar la
  // imagen. Así la barra de búsqueda hace UN `contains` por archivo en lugar
  // de normalizar cientos de etiquetas en cada tecla.
  final Map<String, ImageSearchDoc> _searchTextCache = {};

  // Índices para las sugerencias de la barra de búsqueda (se reconstruyen
  // solos la próxima vez que se necesitan tras un cambio).
  List<_TagEntry>? _tagIndex;
  Map<String, int>? _tagCounts;
  Map<int, _CharEntry>? _charIndex;
  bool _isInitialized = false;
  late Database _db;

  /// Cierra la base de datos ordenadamente (al cerrar la app). Después el
  /// servicio no se puede usar hasta llamar de nuevo a initialize().
  Future<void> close() async {
    if (!_isInitialized) return;
    _isInitialized = false;
    try {
      await _db.close();
    } catch (_) {}
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    final supportDir = await getApplicationSupportDirectory();
    final dbPath = p.join(supportDir.path, 'vault_metadata.db');

    _db = await openDatabase(
      dbPath,
      version: 7, // Versión maestra con soporte multi-perfil e intermedio
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE metadata (
            image_id TEXT PRIMARY KEY,
            tags TEXT,
            rating INTEGER,
            added_timestamp INTEGER,
            profile TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE tags (tag TEXT PRIMARY KEY)
        ''');
        await _createCharacterTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try { await db.execute('ALTER TABLE metadata ADD COLUMN added_timestamp INTEGER DEFAULT 0'); } catch (_) {}
        }
        if (oldVersion < 3) {
          try { await db.execute('ALTER TABLE metadata ADD COLUMN profile TEXT'); } catch (_) {}
        }
        if (oldVersion < 5) {
          await _createCharacterTables(db);
        }
        if (oldVersion < 6) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS image_characters (
              image_id TEXT,
              character_id INTEGER,
              PRIMARY KEY (image_id, character_id)
            )
          ''');
          // Migrar datos viejos individuales si existían
          try {
            final legacy = await db.query('metadata', columns: ['image_id', 'character_id']);
            for (var row in legacy) {
              if (row['character_id'] != null) {
                await db.insert('image_characters', {
                  'image_id': row['image_id'] as String,
                  'character_id': row['character_id'] as int,
                }, conflictAlgorithm: ConflictAlgorithm.ignore);
              }
            }
          } catch (_) {}
        }
        if (oldVersion < 7) {
          // <--- NUEVA ACTUALIZACIÓN: Añadir la columna de avatar a tablas existentes
          try { await db.execute('ALTER TABLE characters ADD COLUMN avatar_path TEXT'); } catch (_) {}
        }
      },
    );

    // 1. Cargar metadatos principales a memoria RAM
    final metadataRows = await _db.query('metadata');
    for (final row in metadataRows) {
      final imgId = row['image_id'] as String;
      _imageData[imgId] = ImageMetadata(
        tags: row['tags'] != null ? List<String>.from(jsonDecode(row['tags'] as String)) : [],
        rating: row['rating'] as int? ?? 0,
        addedTimestamp: (row['added_timestamp'] as int?) ?? 0,
        characterIds: [],
        profile: row['profile'] != null ? Map<String, String>.from(jsonDecode(row['profile'] as String)) : {},
      );
    }

    // 2. Cargar mapeos relacionales mutitarget
    final relRows = await _db.query('image_characters');
    for (final row in relRows) {
      final imgId = row['image_id'] as String;
      final charId = row['character_id'] as int;
      if (_imageData.containsKey(imgId)) {
        _imageData[imgId]!.characterIds.add(charId);
      }
    }

    final charRows = await _db.query('characters');
    for (final row in charRows) {
      final char = LocalCharacter.fromMap(row);
      if (char.id != null) {
        _charactersCache[char.id!] = char;
      }
    }

    final tagRows = await _db.query('tags');
    _allTags = tagRows.map((row) => row['tag'] as String).toList();

    _isInitialized = true;
  }

  Future<void> _createCharacterTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS characters (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        franchise TEXT NOT NULL,
        gender TEXT,
        age TEXT,
        birthday TEXT,
        custom_fields TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS image_characters (
        image_id TEXT,
        character_id INTEGER,
        PRIMARY KEY (image_id, character_id)
      )
    ''');
  }

  // --- CRUD CENTRAL DE PERSONAJES LOCALES ---

  Future<int> insertCharacter(LocalCharacter character) async {
    final id = await _db.insert('characters', character.toMap());
    // ---> NUEVO: Guardar en caché
    _charactersCache[id] = LocalCharacter(
      id: id,
      name: character.name,
      franchise: character.franchise,
      gender: character.gender,
      age: character.age,
      birthday: character.birthday,
      avatarPath: character.avatarPath,
      customFields: character.customFields,
    );
    _charIndex = null;
    return id;
  }

  Future<void> updateCharacter(LocalCharacter character) async {
    if (character.id == null) return;
    await _db.update('characters', character.toMap(), where: 'id = ?', whereArgs: [character.id]);
    // ---> NUEVO: Actualizar caché
    _charactersCache[character.id!] = character;
    _searchTextCache.clear(); // nombre/franquicia pudieron cambiar
    _charIndex = null;
  }

  Future<void> deleteCharacter(int id) async {
    await _db.delete('characters', where: 'id = ?', whereArgs: [id]);
    await _db.delete('image_characters', where: 'character_id = ?', whereArgs: [id]);
    
    // ---> NUEVO: Eliminar de la caché
    _charactersCache.remove(id); 
    
    for (final meta in _imageData.values) {
      meta.characterIds.remove(id);
    }
    _searchTextCache.clear();
    _charIndex = null;
  }

  /// Documento de búsqueda de una imagen (etiquetas, perfil y personajes ya
  /// normalizados, separados por campo). Cacheado; ver [_searchTextCache].
  ImageSearchDoc getSearchDoc(String imageId) {
    final cached = _searchTextCache[imageId];
    if (cached != null) return cached;

    final metadata = _imageData[imageId];
    if (metadata == null) return ImageSearchDoc.empty;

    final tags = <String>[for (final t in metadata.tags) normalizeForSearch(t)];
    final profileValues = <String>[
      for (final v in metadata.profile.values)
        if (v.trim().isNotEmpty) normalizeForSearch(v)
    ];
    final characters = <String>[];
    final franchises = <String>[];
    for (final charId in metadata.characterIds) {
      final character = _charactersCache[charId];
      if (character == null) continue;
      characters.add(normalizeForSearch(character.name));
      if (character.franchise.trim().isNotEmpty) {
        franchises.add(normalizeForSearch(character.franchise));
      }
    }

    return _searchTextCache[imageId] = ImageSearchDoc(
      tags: tags,
      characters: characters,
      franchises: franchises,
      profileValues: profileValues,
      all: [...tags, ...profileValues, ...characters, ...franchises].join('\n'),
    );
  }

  // --- SUGERENCIAS PARA LA BARRA DE BÚSQUEDA ---

  /// Perfiles cuyo nombre (o franquicia) coincide con [normalizedQuery],
  /// de mejor a peor coincidencia.
  List<LocalCharacter> suggestCharacters(String normalizedQuery, {int limit = 3}) {
    if (normalizedQuery.isEmpty || _charactersCache.isEmpty) return const [];
    final index = _charIndex ??= {
      for (final c in _charactersCache.values)
        if (c.id != null)
          c.id!: _CharEntry(normalizeForSearch(c.name), normalizeForSearch(c.franchise)),
    };

    final scored = <MapEntry<LocalCharacter, double>>[];
    for (final c in _charactersCache.values) {
      final entry = index[c.id];
      if (entry == null) continue;
      final byName = matchQuality(entry.name, normalizedQuery) * 100;
      final byFranchise = matchQuality(entry.franchise, normalizedQuery) * 40;
      final s = byName > byFranchise ? byName : byFranchise;
      if (s > 0) scored.add(MapEntry(c, s));
    }
    if (scored.isEmpty) return const [];
    scored.sort((a, b) {
      final byScore = b.value.compareTo(a.value);
      return byScore != 0
          ? byScore
          : a.key.name.toLowerCase().compareTo(b.key.name.toLowerCase());
    });
    return [for (final e in scored.take(limit)) e.key];
  }

  /// Etiquetas que coinciden con [normalizedQuery]: primero las que mejor
  /// coinciden y, a igualdad, las más usadas.
  List<TagSuggestion> suggestTags(String normalizedQuery, {int limit = 5}) {
    if (normalizedQuery.isEmpty || _allTags.isEmpty) return const [];
    final index = _tagIndex ??= [
      for (final t in _allTags) _TagEntry(t, normalizeForSearch(t)),
    ];

    final scored = <MapEntry<String, double>>[];
    for (final e in index) {
      if (!e.norm.contains(normalizedQuery)) continue;
      scored.add(MapEntry(e.tag, matchQuality(e.norm, normalizedQuery)));
    }
    if (scored.isEmpty) return const [];

    final counts = _tagCounts ??= _computeTagCounts();
    scored.sort((a, b) {
      final byScore = b.value.compareTo(a.value);
      if (byScore != 0) return byScore;
      final byCount = (counts[b.key] ?? 0).compareTo(counts[a.key] ?? 0);
      if (byCount != 0) return byCount;
      final byLen = a.key.length.compareTo(b.key.length);
      return byLen != 0 ? byLen : a.key.compareTo(b.key);
    });
    return [
      for (final e in scored.take(limit)) TagSuggestion(e.key, counts[e.key] ?? 0),
    ];
  }

  Map<String, int> _computeTagCounts() {
    final counts = <String, int>{};
    for (final metadata in _imageData.values) {
      for (final tag in metadata.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    return counts;
  }

  // ---> NUEVO: Método síncrono para leer desde la UI al instante
  LocalCharacter? getCharacterSync(int id) {
    return _charactersCache[id];
  }

  Future<List<LocalCharacter>> getAllCharacters() async {
    final rows = await _db.query('characters', orderBy: 'name ASC');
    return rows.map((row) => LocalCharacter.fromMap(row)).toList();
  }

  Future<LocalCharacter?> getCharacterById(int id) async {
    final rows = await _db.query('characters', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return LocalCharacter.fromMap(rows.first);
  }

  // Comprueba si un personaje exacto ya existe en la base de datos local por nombre y franquicia
  Future<LocalCharacter?> findExistingCharacter(String name, String franchise) async {
    final rows = await _db.query(
      'characters',
      where: 'LOWER(name) = ? AND LOWER(franchise) = ?',
      whereArgs: [name.trim().toLowerCase(), franchise.trim().toLowerCase()],
    );
    if (rows.isEmpty) return null;
    return LocalCharacter.fromMap(rows.first);
  }

  // --- INTERMEDIARIOS MUCHOS A MUCHOS ---

  Future<void> addCharacterToImage(String imageId, int characterId) async {
    final metadata = _imageData.putIfAbsent(imageId, () => ImageMetadata());
    if (!metadata.characterIds.contains(characterId)) {
      metadata.characterIds.add(characterId);
      _searchTextCache.remove(imageId);
      await _db.insert('image_characters', {
        'image_id': imageId,
        'character_id': characterId
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> removeCharacterFromImage(String imageId, int characterId) async {
    if (_imageData.containsKey(imageId)) {
      _imageData[imageId]!.characterIds.remove(characterId);
      _searchTextCache.remove(imageId);
      await _db.delete('image_characters', where: 'image_id = ? AND character_id = ?', whereArgs: [imageId, characterId]);
    }
  }

  // --- REPARACIÓN DE MÉTODOS DE ETIQUETAS (SOLUCIÓN A TU ERROR EN PANTALLA) ---

  ImageMetadata getMetadataForImage(String imageId) {
    return _imageData[imageId] ?? ImageMetadata();
  }

  List<String> getAllTags() => List.from(_allTags);

  Future<void> addTagToImage(String imageId, String tag) async {
    final cleanTag = tag.trim().toLowerCase();
    if (cleanTag.isEmpty) return;

    final metadata = _imageData.putIfAbsent(imageId, () => ImageMetadata());
    if (!metadata.tags.contains(cleanTag)) metadata.tags.add(cleanTag);

    if (!_allTags.contains(cleanTag)) {
      _allTags.add(cleanTag);
      _tagIndex = null;
      await _db.insert('tags', {'tag': cleanTag}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await _saveSingleMetadata(imageId, metadata);
  }

  /// Añade varias etiquetas de una sola vez a la misma imagen, haciendo
  /// UN solo guardado en disco al final (en vez de uno por etiqueta como
  /// hace `addTagToImage`). Pensado para el etiquetado automático por IA
  /// (WD14), donde una sola imagen puede recibir 20-40 etiquetas de golpe.
  Future<void> addTagsToImage(String imageId, List<String> tags) async {
    if (tags.isEmpty) return;

    final metadata = _imageData.putIfAbsent(imageId, () => ImageMetadata());
    bool changed = false;

    for (final rawTag in tags) {
      final cleanTag = rawTag.trim().toLowerCase();
      if (cleanTag.isEmpty) continue;

      if (!metadata.tags.contains(cleanTag)) {
        metadata.tags.add(cleanTag);
        changed = true;
      }
      if (!_allTags.contains(cleanTag)) {
        _allTags.add(cleanTag);
        _tagIndex = null;
        await _db.insert('tags', {'tag': cleanTag}, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }

    if (changed) {
      await _saveSingleMetadata(imageId, metadata);
    }
  }

  Future<void> removeTagFromImage(String imageId, String tag) async {
    final cleanTag = tag.trim().toLowerCase();
    if (_imageData.containsKey(imageId)) {
      _imageData[imageId]!.tags.remove(cleanTag);
      await _saveSingleMetadata(imageId, _imageData[imageId]!);
    }
  }

  Future<void> setRatingForImage(String imageId, int rating) async {
    final metadata = _imageData.putIfAbsent(imageId, () => ImageMetadata());
    metadata.rating = rating;
    await _saveSingleMetadata(imageId, metadata);
  }

  Future<void> setAddedTimestamp(String imageId, int timestamp) async {
    final metadata = _imageData.putIfAbsent(imageId, () => ImageMetadata());
    metadata.addedTimestamp = timestamp;
    await _saveSingleMetadata(imageId, metadata);
  }

  Future<void> _saveSingleMetadata(String imageId, ImageMetadata metadata) async {
    _searchTextCache.remove(imageId);
    _tagCounts = null;
    await _db.insert(
      'metadata',
      {
        'image_id': imageId,
        'tags': jsonEncode(metadata.tags),
        'rating': metadata.rating,
        'added_timestamp': metadata.addedTimestamp,
        'profile': jsonEncode(metadata.profile),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateImagePath(String oldId, String newId) async {
    if (_imageData.containsKey(oldId)) {
      final metadata = _imageData.remove(oldId)!;
      _imageData[newId] = metadata;
      _searchTextCache.remove(oldId);
      _searchTextCache.remove(newId);
      await _db.delete('metadata', where: 'image_id = ?', whereArgs: [oldId]);
      await _saveSingleMetadata(newId, metadata);

      final links = await _db.query('image_characters', where: 'image_id = ?', whereArgs: [oldId]);
      await _db.delete('image_characters', where: 'image_id = ?', whereArgs: [oldId]);
      for (var l in links) {
        await _db.insert('image_characters', {'image_id': newId, 'character_id': l['character_id'] as int});
      }
    }
  }

  /// Duplica los metadatos (etiquetas, estrellas, perfiles) de una imagen a
  /// otra. Usado al COPIAR archivos: la copia conserva todo y recibe una
  /// fecha de ingreso nueva.
  Future<void> copyMetadata(String fromId, String toId) async {
    final src = _imageData[fromId];
    if (src == null) return;
    final copy = ImageMetadata(
      tags: List<String>.from(src.tags),
      rating: src.rating,
      addedTimestamp: DateTime.now().millisecondsSinceEpoch,
      characterIds: List<int>.from(src.characterIds),
      profile: Map<String, String>.from(src.profile),
    );
    _imageData[toId] = copy;
    _searchTextCache.remove(toId);
    await _saveSingleMetadata(toId, copy);
    for (final charId in copy.characterIds) {
      await _db.insert(
        'image_characters',
        {'image_id': toId, 'character_id': charId},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<void> deleteMetadata(String imageId) async {
    _imageData.remove(imageId);
    _searchTextCache.remove(imageId);
    _tagCounts = null;
    await _db.delete('metadata', where: 'image_id = ?', whereArgs: [imageId]);
    await _db.delete('image_characters', where: 'image_id = ?', whereArgs: [imageId]);
  }

  Future<void> deleteTagGlobal(String tag) async {
    final cleanTag = tag.trim().toLowerCase();
    _allTags.remove(cleanTag);
    _searchTextCache.clear();
    _tagIndex = null;
    _tagCounts = null;
    await _db.delete('tags', where: 'tag = ?', whereArgs: [cleanTag]);
    for (final entry in _imageData.entries) {
      if (entry.value.tags.contains(cleanTag)) {
        entry.value.tags.remove(cleanTag);
        await _saveSingleMetadata(entry.key, entry.value);
      }
    }
  }

  /// Elimina TODAS las etiquetas del sistema: de la lista global y de
  /// cada imagen que tuviera alguna. No toca calificaciones, personajes ni
  /// ningún otro dato de la imagen, solo las etiquetas. Usado por el botón
  /// "Eliminar todas las etiquetas" de Ajustes › Gestionar Etiquetas.
  Future<void> deleteAllTagsGlobal() async {
    _allTags.clear();
    _searchTextCache.clear();
    _tagIndex = null;
    _tagCounts = null;
    await _db.delete('tags');
    for (final entry in _imageData.entries) {
      if (entry.value.tags.isNotEmpty) {
        entry.value.tags.clear();
        await _saveSingleMetadata(entry.key, entry.value);
      }
    }
  }

  /// Quita todas las etiquetas de un conjunto concreto de imágenes (no
  /// afecta al resto de la bóveda ni a la lista global de etiquetas
  /// conocidas, ya que otras imágenes pueden seguir usándolas). Usado por
  /// el botón "Eliminar todas" del editor de etiquetas de un archivo.
  Future<void> clearTagsForImages(List<String> imageIds) async {
    for (final imageId in imageIds) {
      final metadata = _imageData[imageId];
      if (metadata != null && metadata.tags.isNotEmpty) {
        metadata.tags.clear();
        await _saveSingleMetadata(imageId, metadata);
      }
    }
  }

  Future<void> renameTagGlobal(String oldTag, String newTag) async {
    final cleanOld = oldTag.trim().toLowerCase();
    final cleanNew = newTag.trim().toLowerCase();
    if (cleanNew.isEmpty || cleanOld == cleanNew) return;

    if (!_allTags.contains(cleanNew)) {
      _allTags.add(cleanNew);
      _tagIndex = null;
      await _db.insert('tags', {'tag': cleanNew}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    _allTags.remove(cleanOld);
    _searchTextCache.clear();
    _tagIndex = null;
    _tagCounts = null;
    await _db.delete('tags', where: 'tag = ?', whereArgs: [cleanOld]);

    for (final entry in _imageData.entries) {
      if (entry.value.tags.contains(cleanOld)) {
        entry.value.tags.remove(cleanOld);
        if (!entry.value.tags.contains(cleanNew)) entry.value.tags.add(cleanNew);
        await _saveSingleMetadata(entry.key, entry.value);
      }
    }
  }

  int countImagesWithTag(String tag) {
    final cleanTag = tag.trim().toLowerCase();
    int count = 0;
    for (final metadata in _imageData.values) {
      if (metadata.tags.contains(cleanTag)) count++;
    }
    return count;
  }

  // Mantener firma por compatibilidad con llamados antiguos de perfiles planos si quedaban rastros
  Future<void> setProfileForImage(String imageId, Map<String, String> profileData) async {
    final metadata = _imageData.putIfAbsent(imageId, () => ImageMetadata());
    metadata.profile = profileData;
    await _saveSingleMetadata(imageId, metadata);
  }

  Future<String> saveAvatarImage(List<int> bytes) async {
    final supportDir = await getApplicationSupportDirectory();
    final avatarDir = Directory(p.join(supportDir.path, 'avatars'));
    if (!await avatarDir.exists()) await avatarDir.create(recursive: true);
    
    final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.png';
    final file = File(p.join(avatarDir.path, fileName));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  // --- NUEVO: Obtener todas las imágenes vinculadas a un personaje ---
  List<String> getImagesForCharacter(int characterId) {
    List<String> matchingImages = [];
    _imageData.forEach((imageId, metadata) {
      if (metadata.characterIds.contains(characterId)) {
        matchingImages.add(imageId);
      }
    });
    return matchingImages;
  }

  /// Nº de imágenes vinculadas a cada perfil (characterId -> cantidad),
  /// calculado en UNA sola pasada. Usado por Administración de Perfiles para
  /// mostrar contadores sin llamar a [getImagesForCharacter] por cada perfil.
  Map<int, int> getCharacterImageCounts() {
    final counts = <int, int>{};
    for (final metadata in _imageData.values) {
      for (final id in metadata.characterIds) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// Para cada imagen que tenga al menos una de las etiquetas de [tags],
  /// devuelve cuáles de ellas tiene (imageId -> etiquetas coincidentes).
  /// Si se indica [excludeCharacterId], se omiten las imágenes que ya están
  /// vinculadas a ese personaje. Usado por las "Sugerencias" de
  /// Administración de Perfiles.
  Map<String, List<String>> getImageTagHits(Set<String> tags,
      {int? excludeCharacterId}) {
    final result = <String, List<String>>{};
    _imageData.forEach((imageId, metadata) {
      if (excludeCharacterId != null &&
          metadata.characterIds.contains(excludeCharacterId)) {
        return;
      }
      List<String>? hits;
      for (final t in metadata.tags) {
        if (tags.contains(t)) (hits ??= <String>[]).add(t);
      }
      if (hits != null) result[imageId] = hits;
    });
    return result;
  }
}

class _TagEntry {
  final String tag;
  final String norm;
  const _TagEntry(this.tag, this.norm);
}

class _CharEntry {
  final String name;
  final String franchise;
  const _CharEntry(this.name, this.franchise);
}