import 'dart:io';
import 'package:flutter/foundation.dart'; // Importante para usar 'compute'
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;

// PASO 1: Crear una clase de ayuda para pasar los datos al isolate.
// Esto es más limpio y seguro que usar un Map.
class _ThumbnailRequest {
  final String inputPath;
  final String outputPath;
  final int width;

  _ThumbnailRequest({
    required this.inputPath,
    required this.outputPath,
    required this.width,
  });
}

// PASO 2: Crear una función global (fuera de la clase) que hará el trabajo pesado.
// La función 'compute' solo puede ejecutar funciones globales o métodos estáticos.
Future<void> _generateThumbnailIsolate(_ThumbnailRequest request) async {
  // Leemos los bytes de la imagen original
  final imageBytes = await File(request.inputPath).readAsBytes();
  final image = img.decodeImage(imageBytes);

  if (image != null) {
    // Redimensionamos la imagen
    final thumbnail = img.copyResize(image, width: request.width);
    
    // Guardamos la miniatura en la ruta de salida
    // Usamos 'await' aquí para asegurarnos de que la escritura termine.
    await File(request.outputPath).writeAsBytes(img.encodeJpg(thumbnail, quality: 85));
  }
}


class ThumbnailService {
  static final ThumbnailService _instance = ThumbnailService._internal();
  factory ThumbnailService() => _instance;
  ThumbnailService._internal();

  Directory? _thumbnailDir;
  bool _isInitialized = false;
  final Map<String, File> _cache = {};

  Future<void> initialize() async {
    if (_isInitialized) return;
    final appDir = await getApplicationDocumentsDirectory();
    _thumbnailDir = Directory(p.join(appDir.path, 'thumbnails'));
    if (!await _thumbnailDir!.exists()) {
      await _thumbnailDir!.create(recursive: true);
    }
    _isInitialized = true;
  }

  Future<File> getThumbnail(File originalImage) async {
    if (!_isInitialized) await initialize();

    final originalPath = originalImage.path;
    if (_cache.containsKey(originalPath)) {
      // Si la ruta ya está en caché, la devolvemos inmediatamente.
      // Comprobamos si el archivo existe por si fue borrado externamente.
      if (await _cache[originalPath]!.exists()) {
        return _cache[originalPath]!;
      }
    }

    final imageName = p.basename(originalPath);
    final thumbFile = File(p.join(_thumbnailDir!.path, imageName));

    if (await thumbFile.exists()) {
      _cache[originalPath] = thumbFile;
      return thumbFile;
    }

    // --- INICIO DE LA MODIFICACIÓN CLAVE ---

    // Creamos el paquete de datos para enviar al isolate.
    final request = _ThumbnailRequest(
      inputPath: originalImage.path,
      outputPath: thumbFile.path,
      width: 256, // Tamaño fijo para las miniaturas
    );

    // Usamos 'compute' para ejecutar nuestra función en un isolate separado.
    // La UI NO se congelará durante esta operación.
    await compute(_generateThumbnailIsolate, request);

    // --- FIN DE LA MODIFICACIÓN CLAVE ---
    
    // Una vez que 'compute' ha terminado, el archivo ya existe.
    // Lo añadimos a la caché y lo devolvemos.
    _cache[originalPath] = thumbFile;
    return thumbFile;
  }

  Future<void> clearThumbnail(String originalImageName) async {
    if (!_isInitialized) await initialize();
    final thumbFile = File(p.join(_thumbnailDir!.path, originalImageName));
    if (await thumbFile.exists()) {
      await thumbFile.delete();
    }
    _cache.removeWhere((key, value) => p.basename(key) == originalImageName);
  }
  void clearMemoryCache() {
    _cache.clear();
  }
}