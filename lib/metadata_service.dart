// metadata_service.dart
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
//import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;

class ImageMetadata {
  List<String> tags;
  int rating;
  int addedTimestamp;
  Map<String, String> profile; // <-- NUEVO: Guardará los datos de AniList

  ImageMetadata({
    List<String>? tags, 
    this.rating = 0, 
    this.addedTimestamp = 0,
    Map<String, String>? profile, // <-- NUEVO
  }) : tags = tags ?? [],
       profile = profile ?? {}; // <-- NUEVO
}

class MetadataService {
  // --- INICIO PATRÓN SINGLETON ---
  // Esto asegura que todas las carpetas y subcarpetas compartan 
  // exactamente la misma memoria y base de datos de etiquetas.
  static final MetadataService _instance = MetadataService._internal();
  factory MetadataService() => _instance;
  MetadataService._internal();
  // --- FIN PATRÓN SINGLETON ---

  final Map<String, ImageMetadata> _imageData = {};
  List<String> _allTags = [];
  bool _isInitialized = false;
  late Database _db;

  Future<void> initialize() async {
    if (_isInitialized) return;

    final supportDir = await getApplicationSupportDirectory();
    final dbPath = p.join(supportDir.path, 'vault_metadata.db');

    _db = await openDatabase(
      dbPath,
      version: 4,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE metadata (
            image_id TEXT PRIMARY KEY,
            tags TEXT,
            rating INTEGER,
            added_timestamp INTEGER,
            profile TEXT -- <-- NUEVA COLUMNA
          )
        ''');
        await db.execute('''
          CREATE TABLE tags (
            tag TEXT PRIMARY KEY
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute('ALTER TABLE metadata ADD COLUMN added_timestamp INTEGER DEFAULT 0');
          } catch (_) {
            // Ignoramos el error si la columna ya se había creado previamente
          }
        }
        if (oldVersion < 3) { 
          try {
            await db.execute('ALTER TABLE metadata ADD COLUMN profile TEXT');
          } catch (e) {
            // Ignoramos el "duplicate column name" silenciosamente.
            // Esto evita cierres inesperados si la columna ya existe por pruebas previas.
            //debugPrint('Nota: La columna profile ya existía en la base de datos.');
          }
        }
      },
    );

    // Cargar todo a memoria para lecturas instantáneas (síncronas) en la UI
    final metadataRows = await _db.query('metadata');
    for (final row in metadataRows) {
      _imageData[row['image_id'] as String] = ImageMetadata(
        tags: List<String>.from(jsonDecode(row['tags'] as String)),
        rating: row['rating'] as int,
        addedTimestamp: (row['added_timestamp'] as int?) ?? 0,
        // <-- NUEVA LECTURA DE DATOS:
        profile: row['profile'] != null ? Map<String, String>.from(jsonDecode(row['profile'] as String)) : {},
      );
    }

    final tagRows = await _db.query('tags');
    _allTags = tagRows.map((row) => row['tag'] as String).toList();

    _isInitialized = true;
  }

  // IMPORTANTE: Ahora recibe el imageId (ruta relativa), no el nombre del archivo
  ImageMetadata getMetadataForImage(String imageId) {
    return _imageData[imageId] ?? ImageMetadata();
  }

  List<String> getAllTags() => List.from(_allTags);

  Future<void> addTagToImage(String imageId, String tag) async {
    final cleanTag = tag.trim().toLowerCase();
    if (cleanTag.isEmpty) return;

    final metadata = _imageData.putIfAbsent(imageId, () => ImageMetadata());
    if (!metadata.tags.contains(cleanTag)) {
      metadata.tags.add(cleanTag);
    }

    if (!_allTags.contains(cleanTag)) {
      _allTags.add(cleanTag);
      await _db.insert('tags', {'tag': cleanTag}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    await _saveSingleMetadata(imageId, metadata);
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

  // Guarda SOLO el registro modificado. Cero cuellos de botella.
  Future<void> _saveSingleMetadata(String imageId, ImageMetadata metadata) async {
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

  Future<void> setAddedTimestamp(String imageId, int timestamp) async {
    final metadata = _imageData.putIfAbsent(imageId, () => ImageMetadata());
    metadata.addedTimestamp = timestamp;
    await _saveSingleMetadata(imageId, metadata);
  }

  Future<void> updateImagePath(String oldId, String newId) async {
    // 1. Si es un archivo individual que se movió
    if (_imageData.containsKey(oldId)) {
      final metadata = _imageData.remove(oldId)!;
      _imageData[newId] = metadata; // Actualizamos memoria RAM
      
      // Eliminamos el rastro de la ruta antigua
      await _db.delete('metadata', where: 'image_id = ?', whereArgs: [oldId]);
      
      // Insertamos en la nueva ruta. 'ConflictAlgorithm.replace' es la magia:
      // Si existía un "registro fantasma" con esa ruta, lo sobrescribe sin dar error.
      await _db.insert(
        'metadata',
        {
          'image_id': newId,
          'tags': jsonEncode(metadata.tags),
          'rating': metadata.rating,
          'added_timestamp': metadata.addedTimestamp,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    
    // 2. Si es una CARPETA que se movió, debemos actualizar todo su contenido
    final prefix = oldId + p.separator;
    final keysToUpdate = _imageData.keys.where((k) => k.startsWith(prefix)).toList();
    
    for (final key in keysToUpdate) {
      final newKey = newId + key.substring(oldId.length);
      final metadata = _imageData.remove(key)!;
      _imageData[newKey] = metadata;
      
      // Mismo proceso: Borrar el viejo e insertar/reemplazar el nuevo
      await _db.delete('metadata', where: 'image_id = ?', whereArgs: [key]);
      
      await _db.insert(
        'metadata',
        {
          'image_id': newKey,
          'tags': jsonEncode(metadata.tags),
          'rating': metadata.rating,
          'added_timestamp': metadata.addedTimestamp,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  // Bonus: Borrar la metadata cuando eliminas la imagen para no dejar datos fantasma
  Future<void> deleteMetadata(String imageId) async {
    _imageData.remove(imageId);
    await _db.delete('metadata', where: 'image_id = ?', whereArgs: [imageId]);
    
    final prefix = imageId + p.separator;
    final keysToDelete = _imageData.keys.where((k) => k.startsWith(prefix)).toList();
    for (final key in keysToDelete) {
      _imageData.remove(key);
      await _db.delete('metadata', where: 'image_id = ?', whereArgs: [key]);
    }
  }

  // Borra una etiqueta de la faz de la tierra (globalmente)
  Future<void> deleteTagGlobal(String tag) async {
    final cleanTag = tag.trim().toLowerCase();
    _allTags.remove(cleanTag);
    await _db.delete('tags', where: 'tag = ?', whereArgs: [cleanTag]);

    // Eliminar la etiqueta de la metadata de cada imagen en memoria y DB
    for (final entry in _imageData.entries) {
      if (entry.value.tags.contains(cleanTag)) {
        entry.value.tags.remove(cleanTag);
        await _saveSingleMetadata(entry.key, entry.value);
      }
    }
  }

  // Renombra una etiqueta en todo el sistema
  Future<void> renameTagGlobal(String oldTag, String newTag) async {
    final cleanOld = oldTag.trim().toLowerCase();
    final cleanNew = newTag.trim().toLowerCase();
    if (cleanNew.isEmpty || cleanOld == cleanNew) return;

    // 1. Actualizar lista global
    if (!_allTags.contains(cleanNew)) {
      _allTags.add(cleanNew);
      await _db.insert('tags', {'tag': cleanNew}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    _allTags.remove(cleanOld);
    await _db.delete('tags', where: 'tag = ?', whereArgs: [cleanOld]);

    // 2. Actualizar todas las imágenes que tenían la etiqueta vieja
    for (final entry in _imageData.entries) {
      if (entry.value.tags.contains(cleanOld)) {
        entry.value.tags.remove(cleanOld);
        if (!entry.value.tags.contains(cleanNew)) {
          entry.value.tags.add(cleanNew);
        }
        await _saveSingleMetadata(entry.key, entry.value);
      }
    }
  }

  // Cuenta cuántas imágenes están usando una etiqueta específica
  int countImagesWithTag(String tag) {
    final cleanTag = tag.trim().toLowerCase();
    int count = 0;
    
    // Recorremos todas las imágenes cargadas en memoria RAM
    for (final metadata in _imageData.values) {
      if (metadata.tags.contains(cleanTag)) {
        count++;
      }
    }
    return count;
  }
  Future<void> setProfileForImage(String imageId, Map<String, String> profileData) async {
    final metadata = _imageData.putIfAbsent(imageId, () => ImageMetadata());
    metadata.profile = profileData;
    await _saveSingleMetadata(imageId, metadata);
  }
}

Future<List<Map<String, dynamic>>> searchAniListCharacters(String characterName) async {
  const String url = 'https://graphql.anilist.co';
  
  // ¡CORRECCIONES!: 
  // 1. characters(sort: [SEARCH_MATCH, FAVOURITES_DESC]) para que el más famoso salga primero.
  // 2. media(page: 1, perPage: 1) en lugar del 'first: 1' que causaba el error.
  const String query = '''
    query (\$search: String) {
      Page(page: 1, perPage: 5) {
        characters(search: \$search, sort: [SEARCH_MATCH, FAVOURITES_DESC]) {
          id
          name {
            full
          }
          gender
          age
          media(sort: POPULARITY_DESC, type: ANIME, page: 1, perPage: 1) {
            nodes {
              title {
                romaji
                english
              }
            }
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
      final data = jsonDecode(response.body);
      final characters = data['data']?['Page']?['characters'] as List?;
      
      if (characters != null) {
        return List<Map<String, dynamic>>.from(characters);
      }
    } else {
      // Ahora, si la API se queja por algo, lo verás en la consola (Debug Console)
      print("Error de AniList (Código ${response.statusCode}): ${response.body}");
    }
  } catch (e) {
    print("Error de red conectando con AniList: $e");
  }
  return [];
}