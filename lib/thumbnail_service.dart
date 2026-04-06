import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle; // NUEVO: Para extraer el ejecutable
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
// ¡Adiós a package:image!

class ThumbnailService {
  static final ThumbnailService _instance = ThumbnailService._internal();
  factory ThumbnailService() => _instance;
  ThumbnailService._internal();

  final plugin = FcNativeVideoThumbnail();
  Directory? _thumbnailDir;
  File? _cwebpExe; // NUEVO: Guardará la ruta física de cwebp.exe en Windows
  bool _isInitialized = false;
  bool _isProcessingBatch = false;

  final ValueNotifier<bool> isGeneratingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<double> progressNotifier = ValueNotifier<double>(0.0);
  
  
  // --- INICIO LÓGICA CACHÉ LRU ---
  static const int _maxCacheSize = 100; 
  final Map<String, File> _cache = {};

  File? _getFromCache(String key) {
    if (_cache.containsKey(key)) {
      final file = _cache.remove(key)!;
      _cache[key] = file;
      return file;
    }
    return null;
  }

  void _addToCache(String key, File file) {
    if (_cache.containsKey(key)) {
      _cache.remove(key);
    } else if (_cache.length >= _maxCacheSize) {
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
    
    // 1. Crear carpeta de miniaturas
    _thumbnailDir = Directory(p.join(supportDir.path, 'thumbnails'));
    if (!await _thumbnailDir!.exists()) {
      await _thumbnailDir!.create(recursive: true);
    }

    // 2. Extraer silenciosamente cwebp.exe de los assets a la computadora
    _cwebpExe = File(p.join(supportDir.path, 'cwebp.exe'));
    if (!await _cwebpExe!.exists()) {
      try {
        final byteData = await rootBundle.load('assets/cwebp.exe');
        await _cwebpExe!.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      } catch (e) {
        debugPrint("Error al extraer cwebp.exe: $e");
      }
    }

    _isInitialized = true;
  }

  // CAMBIO: Ahora nombraremos las miniaturas como .webp en lugar de .vtx
  String _getThumbName(String originalPath) {
    final baseName = p.basenameWithoutExtension(originalPath);
    return '$baseName.thumb.vtx';
  }

  Future<void> bulkGenerate(List<FileSystemEntity> files) async {
    if (_isProcessingBatch) return;
    _isProcessingBatch = true;

    final List<FileSystemEntity> safeFilesCopy = List.from(files);
    final List<File> filesToProcess = [];

    // 1. Filtrar rápido los que realmente necesitan miniatura
    for (var entity in safeFilesCopy) {
      if (entity is File && _isSupportedImageOrVideo(entity.path)) {
        final thumbPath = p.join(_thumbnailDir!.path, _getThumbName(entity.path));
        if (!await File(thumbPath).exists()) {
          filesToProcess.add(entity);
        }
      }
    }

    final int totalFiles = filesToProcess.length;
    
    // Si hay archivos por procesar, encendemos el panel flotante
    if (totalFiles > 0) {
      isGeneratingNotifier.value = true;
      progressNotifier.value = 0.0;
    }

    int processedCount = 0;
    final int batchSize = (Platform.numberOfProcessors > 2) ? Platform.numberOfProcessors - 1 : 2;

    for (int i = 0; i < filesToProcess.length; i += batchSize) {
      final end = (i + batchSize < totalFiles) ? i + batchSize : totalFiles;
      final batch = filesToProcess.sublist(i, end);

      // Lanzamos el lote
      await Future.wait(batch.map((file) => getThumbnail(file)));

      // 2. Calculamos y actualizamos el progreso
      processedCount += batch.length;
      progressNotifier.value = processedCount / totalFiles;

      // Respiro para Flutter
      await Future.delayed(const Duration(milliseconds: 10));
    }

    // Al terminar, apagamos el panel flotante
    isGeneratingNotifier.value = false;
    progressNotifier.value = 0.0;
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

  bool _isVideoButton(String path) {
    final ext = _getRealExtension(path);
    return ['.mp4', '.mov', '.avi', '.mkv'].contains(ext);
  }

  Future<File> getThumbnail(File originalImage) async {
    if (!_isInitialized) await initialize();

    final originalPath = originalImage.path;
    
    // 1. Intentamos leer de la memoria RAM
    final cachedFile = _getFromCache(originalPath);
    if (cachedFile != null) {
      if (await cachedFile.exists()) {
        return cachedFile;
      } else {
        _cache.remove(originalPath);
      }
    }

    final thumbPath = p.join(_thumbnailDir!.path, _getThumbName(originalPath));
    final thumbFile = File(thumbPath);

    // 2. Intentamos leer del Disco Duro
    if (await thumbFile.exists()) {
      if (await thumbFile.length() > 0) {
        _addToCache(originalPath, thumbFile);
        return thumbFile;
      } else {
        await thumbFile.delete();
      }
    }

    // 3. Si no existe, lo generamos
    if (_isVideoButton(originalPath)) {
      final realExt = _getRealExtension(originalPath); 
      final tempPath = '$originalPath$realExt'; 
      final originalFile = File(originalPath);
      bool success = false;

      try {
        if (await originalFile.exists()) {
          await originalFile.rename(tempPath);
        }

        success = await plugin.getVideoThumbnail(
          srcFile: tempPath, 
          destFile: thumbPath,
          width: 256,
          height: 256,
          format: 'jpeg',
          quality: 75,
        );
      } catch (e) {
        debugPrint("Error nativo en Windows: $e");
      } finally {
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
        return originalImage; 
      }
    } else {
      // CAMBIO: Usamos cwebp.exe directo con la terminal en lugar del Isolate
      final success = await _generateWithCwebp(originalImage.path, thumbFile.path, 256);
      
      if (success) {
        _addToCache(originalPath, thumbFile);
      }
    }
    return thumbFile;
  }

  // --- NUEVA FUNCIÓN: Ejecuta el motor cwebp en segundo plano ---
  Future<bool> _generateWithCwebp(String inputPath, String outputPath, int width) async {
    if (_cwebpExe == null || !await _cwebpExe!.exists()) return false;

    try {
      // Orden: "ejecuta cwebp silenciosamente, redimensiona el ancho a 256 y guarda"
      final result = await Process.run(_cwebpExe!.path, [
        '-quiet',
        '-resize', width.toString(), '0',
        '-q', '75', // Calidad de compresión
        inputPath,
        '-o',
        outputPath
      ]);

      return result.exitCode == 0;
    } catch (e) {
      debugPrint("Error ejecutando cwebp: $e");
      return false;
    }
  }

  Future<void> clearThumbnail(String originalImageName) async {
    final thumbName = _getThumbName(originalImageName); 
    final thumbFile = File(p.join(_thumbnailDir!.path, thumbName));
    
    if (await thumbFile.exists()) {
      await thumbFile.delete();
    }
    
    _cache.removeWhere((key, value) => p.basename(key) == originalImageName);
  }

  Future<void> renameThumbnail(String oldOriginalPath, String newOriginalPath) async {
    final oldThumbName = _getThumbName(oldOriginalPath);
    final newThumbName = _getThumbName(newOriginalPath);
    
    final oldThumbFile = File(p.join(_thumbnailDir!.path, oldThumbName));
    final newThumbFile = File(p.join(_thumbnailDir!.path, newThumbName));

    // Solo renombramos físicamente si el nombre final realmente cambió 
    // (Ej: Si cambiaste el nombre de "foto.vtx" a "viaje.vtx", pero no si solo la moviste de carpeta)
    if (await oldThumbFile.exists() && oldThumbFile.path != newThumbFile.path) {
      try {
        await oldThumbFile.rename(newThumbFile.path);
      } catch (e) {
        await oldThumbFile.copy(newThumbFile.path);
        await oldThumbFile.delete();
      }
    }

    // Y siempre transferimos la miniatura a la nueva llave en la memoria RAM (caché)
    if (_cache.containsKey(oldOriginalPath)) {
      final thumbFile = _cache.remove(oldOriginalPath)!;
      _cache[newOriginalPath] = newThumbFile.existsSync() ? newThumbFile : thumbFile;
    }
  }

  void clearMemoryCache() {
    _cache.clear();
  }
}