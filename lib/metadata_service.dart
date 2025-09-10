// metadata_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _allTagsKey = 'all_tags_list';

// Una clase para guardar toda la metadata de una imagen de forma ordenada.
class ImageMetadata {
  List<String> tags;
  int rating; // 0 = sin calificar, 1-5 = estrellas

  ImageMetadata({this.tags = const [], this.rating = 0});

  // Fábrica para crear un objeto desde un JSON
  factory ImageMetadata.fromJson(Map<String, dynamic> json) {
    return ImageMetadata(
      tags: List<String>.from(json['tags'] ?? []),
      rating: json['rating'] ?? 0,
    );
  }

  // Método para convertir el objeto a un JSON
  Map<String, dynamic> toJson() {
    return {
      'tags': tags,
      'rating': rating,
    };
  }
}

class MetadataService {
  Map<String, ImageMetadata> _imageData = {};
  List<String> _allTags = [];
  bool _isInitialized = false;
  File? _jsonFile;

  Future<void> initialize() async {
    if (_isInitialized) return;

    final appDir = await getApplicationDocumentsDirectory();
    // Cambiamos el nombre del archivo para reflejar su nuevo propósito
    _jsonFile = File(p.join(appDir.path, 'metadata.json'));

    if (await _jsonFile!.exists()) {
      final jsonString = await _jsonFile!.readAsString();
      final Map<String, dynamic> decodedJson = jsonDecode(jsonString);
      _imageData = decodedJson.map((key, value) {
        // Esto permite compatibilidad con datos viejos
        if (value is List) {
          return MapEntry(key, ImageMetadata(tags: List<String>.from(value)));
        }
        return MapEntry(key, ImageMetadata.fromJson(value));
      });
    }

    final prefs = await SharedPreferences.getInstance();
    _allTags = prefs.getStringList(_allTagsKey) ?? [];
    _isInitialized = true;
  }

  ImageMetadata getMetadataForImage(String imageName) {
    return _imageData[imageName] ?? ImageMetadata();
  }

  List<String> getAllTags() => List.from(_allTags);

  Future<void> addTagToImage(String imageName, String tag) async {
    final cleanTag = tag.trim().toLowerCase();
    if (cleanTag.isEmpty) return;

    final metadata = _imageData.putIfAbsent(imageName, () => ImageMetadata());
    if (!metadata.tags.contains(cleanTag)) {
      metadata.tags.add(cleanTag);
    }

    if (!_allTags.contains(cleanTag)) {
      _allTags.add(cleanTag);
    }
    await _saveData();
  }

  Future<void> removeTagFromImage(String imageName, String tag) async {
    _imageData[imageName]?.tags.remove(tag.trim().toLowerCase());
    await _saveData();
  }

  // NUEVO: Método para establecer la calificación
  Future<void> setRatingForImage(String imageName, int rating) async {
    final metadata = _imageData.putIfAbsent(imageName, () => ImageMetadata());
    metadata.rating = rating;
    await _saveData();
  }

  Future<void> _saveData() async {
    await _jsonFile?.writeAsString(jsonEncode(_imageData));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_allTagsKey, _allTags);
  }
}