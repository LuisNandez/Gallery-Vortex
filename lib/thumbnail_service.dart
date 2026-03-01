import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';

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
  
  // --- INICIO LÓGICA CACHÉ LRU ---
  // Límite máximo de miniaturas en RAM. 100 es un buen balance entre fluidez y memoria.
  static const int _maxCacheSize = 100; 
  final Map<String, File> _cache = {};

  // Método auxiliar para obtener del caché (y marcar como reciente)
  File? _getFromCache(String key) {
    if (_cache.containsKey(key)) {
      // Al sacarlo y volverlo a meter, Dart lo mueve al final de la fila (más reciente)
      final file = _cache.remove(key)!;
      _cache[key] = file;
      return file;
    }
    return null;
  }

  // Método auxiliar para añadir al caché (y eliminar el más viejo si es necesario)
  void _addToCache(String key, File file) {
    if (_cache.containsKey(key)) {
      _cache.remove(key);
    } else if (_cache.length >= _maxCacheSize) {
      // Si llegamos al límite, sacamos el elemento en la posición 0 (el más antiguo)
      final oldestKey = _cache.keys.first;
      _cache.remove(oldestKey);
      debugPrint("Caché LRU lleno: Liberando de RAM $oldestKey");
    }
    _cache[key] = file;
  }
  // --- FIN LÓGICA CACHÉ LRU ---

  Future<void> initialize() async {
    if (_isInitialized) return;
    final supportDir = await getApplicationSupportDirectory();
    _thumbnailDir = Directory(p.join(supportDir.path, 'thumbnails'));
    if (!await _thumbnailDir!.exists()) {
      await _thumbnailDir!.create(recursive: true);
    }
    _isInitialized = true;
  }

  String _getThumbName(String originalPath) {
    final baseName = p.basenameWithoutExtension(originalPath);
    return '$baseName.thumb.vtx';
  }

  Future<void> bulkGenerate(List<FileSystemEntity> files) async {
    if (_isProcessingBatch) return;
    _isProcessingBatch = true;

    for (var entity in files) {
      if (entity is File && _isSupportedImageOrVideo(entity.path)) {
        final thumbPath = p.join(_thumbnailDir!.path, _getThumbName(entity.path));
        
        if (!await File(thumbPath).exists()) {
          await getThumbnail(entity);
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }
    }
    _isProcessingBatch = false;
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

  String _getRealExtension(String path) {
    if (path.toLowerCase().endsWith('.vtx')) {
      final base = p.basenameWithoutExtension(path);
      final lastZero = base.lastIndexOf('0');
      if (lastZero != -1) {
        return _decipherExtension(base.substring(lastZero));
      }
    }
    return p.extension(path).toLowerCase();
  }

  bool _isSupportedImageOrVideo(String path) {
    final ext = _getRealExtension(path);
    return ['.jpg', '.jpeg', '.png', '.webp', '.mp4', '.mov', '.avi'].contains(ext);
  }

  Future<File> getThumbnail(File originalImage) async {
    if (!_isInitialized) await initialize();

    final originalPath = originalImage.path;
    
    // 1. Intentamos leer de la memoria RAM (Caché LRU)
    final cachedFile = _getFromCache(originalPath);
    if (cachedFile != null) {
      if (await cachedFile.exists()) {
        return cachedFile;
      } else {
        // Si el archivo físico fue borrado por fuera, lo sacamos del caché
        _cache.remove(originalPath);
      }
    }

    final thumbPath = p.join(_thumbnailDir!.path, _getThumbName(originalPath));
    final thumbFile = File(thumbPath);

    // 2. Intentamos leer del Disco Duro
    if (await thumbFile.exists()) {
      _addToCache(originalPath, thumbFile);
      return thumbFile;
    }

    // 3. Si no existe, lo generamos
    if (_isVideoButton(originalPath)) {
      final realExt = _getRealExtension(originalPath); // Averiguamos qué es (ej. .mp4)
      final tempPath = '$originalPath$realExt'; // ej: archivo0nq4.vtx.mp4
      final originalFile = File(originalPath);
      bool success = false;

      try {
        // TRUCO NINJA: Le ponemos la extensión real temporalmente para engañar a Windows
        if (await originalFile.exists()) {
          await originalFile.rename(tempPath);
        }

        success = await plugin.getVideoThumbnail(
          srcFile: tempPath, // Usamos la ruta temporal
          destFile: thumbPath,
          width: 256,
          height: 256,
          format: 'jpeg',
          quality: 75,
        );
      } catch (e) {
        debugPrint("Error nativo en Windows: $e");
      } finally {
        // SUPER IMPORTANTE: Siempre devolvemos el archivo a su estado seguro (.vtx)
        // El bloque 'finally' se ejecuta SIEMPRE, incluso si la app arroja un error arriba.
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          await tempFile.rename(originalPath);
        }
      }

      if (success) {
        final generatedThumb = File(thumbPath);
        _addToCache(originalPath, generatedThumb);
        return generatedThumb;
      } else {
        return originalImage; // Fallback de nuestro Airbag
      }
    } else {
      final request = _ThumbnailRequest(
        inputPath: originalImage.path,
        outputPath: thumbFile.path,
        width: 256,
      );

      final success = await compute(_generateThumbnailIsolate, request);
      
      if (success) {
        _addToCache(originalPath, thumbFile);
      }
    }
    return thumbFile;
  }

  bool _isVideoButton(String path) {
    final ext = _getRealExtension(path);
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