// metadata_service.dart
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
//import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ImageMetadata {
  List<String> tags;
  int rating;

  ImageMetadata({this.tags = const [], this.rating = 0});
}

class MetadataService {
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
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE metadata (
            image_id TEXT PRIMARY KEY,
            tags TEXT,
            rating INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE tags (
            tag TEXT PRIMARY KEY
          )
        ''');
      },
    );

    // Cargar todo a memoria para lecturas instantáneas (síncronas) en la UI
    final metadataRows = await _db.query('metadata');
    for (final row in metadataRows) {
      _imageData[row['image_id'] as String] = ImageMetadata(
        tags: List<String>.from(jsonDecode(row['tags'] as String)),
        rating: row['rating'] as int,
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
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateImagePath(String oldId, String newId) async {
    // 1. Si es un archivo individual que se movió
    if (_imageData.containsKey(oldId)) {
      final metadata = _imageData.remove(oldId)!;
      _imageData[newId] = metadata;
      await _db.update(
        'metadata',
        {'image_id': newId},
        where: 'image_id = ?',
        whereArgs: [oldId],
      );
    }
    
    // 2. Si es una CARPETA que se movió, debemos actualizar todo su contenido
    final prefix = oldId + p.separator;
    final keysToUpdate = _imageData.keys.where((k) => k.startsWith(prefix)).toList();
    
    for (final key in keysToUpdate) {
      // Reemplazamos la parte vieja de la ruta por la nueva
      final newKey = newId + key.substring(oldId.length);
      final metadata = _imageData.remove(key)!;
      _imageData[newKey] = metadata;
      await _db.update(
        'metadata',
        {'image_id': newKey},
        where: 'image_id = ?',
        whereArgs: [key],
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
}