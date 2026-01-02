import 'dart:io';
import 'package:flutter/foundation.dart'; // Importante para usar 'compute'
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';

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
Future<bool> _generateThumbnailIsolate(_ThumbnailRequest request) async {
  try {
    final imageBytes = await File(request.inputPath).readAsBytes();
    final image = img.decodeImage(imageBytes);

    if (image != null) {
      final thumbnail = img.copyResize(image, width: request.width);
      await File(request.outputPath).writeAsBytes(img.encodeJpg(thumbnail, quality: 85));
      return true;
    }
  } catch (e) {
    debugPrint("Error en isolate de miniatura: $e");
  }
  return false;
}


class ThumbnailService {
  static final ThumbnailService _instance = ThumbnailService._internal();
  factory ThumbnailService() => _instance;
  ThumbnailService._internal();

  final plugin = FcNativeVideoThumbnail();
  Directory? _thumbnailDir;
  bool _isInitialized = false;
  bool _isProcessingBatch = false;
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

  /// Procesa todas las imágenes de la bóveda que aún no tienen miniatura en segundo plano.
Future<void> bulkGenerate(List<FileSystemEntity> files) async {
  if (_isProcessingBatch) return;
  _isProcessingBatch = true;

  for (var entity in files) {
    if (entity is File && _isSupportedImageOrVideo(entity.path)) {
      final imageName = p.basename(entity.path);
      final thumbPath = p.join(_thumbnailDir!.path, '$imageName.thumb.jpg');
      
      // Si la miniatura no existe, la creamos en segundo plano
      if (!await File(thumbPath).exists()) {
        await getThumbnail(entity);
        // Pequeño delay para no saturar todos los núcleos del CPU al 100%
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
  }
  _isProcessingBatch = false;
}

bool _isSupportedImageOrVideo(String path) {
  final ext = p.extension(path).toLowerCase();
  return ['.jpg', '.jpeg', '.png', '.webp', '.mp4', '.mov', '.avi'].contains(ext);
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
    final thumbPath = p.join(_thumbnailDir!.path, '$imageName.thumb.jpg');
    final thumbFile = File(thumbPath);

    if (await thumbFile.exists()) {
      _cache[originalPath] = thumbFile;
      return thumbFile;
    }

    if (_isVideoButton(originalPath)) {
      try {
        // Generar miniatura en Windows usando APIs nativas
        final success = await plugin.getVideoThumbnail(
          srcFile: originalPath,
          destFile: thumbPath, // Ruta donde se guardará el .jpg
          width: 256,
          height: 256,
          format: 'jpeg',
          quality: 75,
        );

        if (success) {
          final generatedThumb = File(thumbPath);
          _cache[originalPath] = generatedThumb;
          return generatedThumb;
        }
      } catch (e) {
        debugPrint("Error nativo en Windows: $e");
      }
    } else {
    // --- INICIO DE LA MODIFICACIÓN CLAVE ---

    // Creamos el paquete de datos para enviar al isolate.
    final request = _ThumbnailRequest(
        inputPath: originalImage.path,
        outputPath: thumbFile.path,
        width: 256,
      );

      // Ahora capturamos el resultado del compute
      final success = await compute(_generateThumbnailIsolate, request);
      
      if (success) {
        _cache[originalPath] = thumbFile;
      }
    }
    return thumbFile;
  }

  bool _isVideoButton(String path) {
  final ext = p.extension(path).toLowerCase();
  return ['.mp4', '.mov', '.avi', '.mkv'].contains(ext);
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