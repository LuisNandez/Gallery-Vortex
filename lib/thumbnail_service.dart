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
  File? _gif2webpExe;
  File? _ffmpegExe;
  File? _ffprobeExe;
  bool _isInitialized = false;
  bool _isProcessingBatch = false;

  final ValueNotifier<bool> isGeneratingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<double> progressNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> isGeneratingAnimNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<double> animProgressNotifier = ValueNotifier<double>(0.0);
  
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
    _gif2webpExe = File(p.join(supportDir.path, 'gif2webp.exe'));
    if (!await _gif2webpExe!.exists()) {
      try {
        final byteData = await rootBundle.load('assets/gif2webp.exe');
        await _gif2webpExe!.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      } catch (e) {
        debugPrint("Error al extraer gif2webp.exe: $e");
      }
    }
    _ffmpegExe = File(p.join(supportDir.path, 'ffmpeg.exe'));
    if (!await _ffmpegExe!.exists()) {
      try {
        final byteData = await rootBundle.load('assets/ffmpeg.exe');
        await _ffmpegExe!.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      } catch (e) {
        debugPrint("Error al extraer ffmpeg.exe: $e");
      }
    }
    _ffprobeExe = File(p.join(supportDir.path, 'ffprobe.exe'));

if (!await _ffprobeExe!.exists()) {
  try {
    final byteData = await rootBundle.load('assets/ffprobe.exe');
    await _ffprobeExe!.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
    debugPrint("ffprobe.exe extraído con éxito.");
  } catch (e) {
    debugPrint("¡ERROR FATAL! No se pudo extraer ffprobe.exe: $e");
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
    
    // FASE 1: Miniaturas Estáticas (Rápido)
    await _processStaticBatch(safeFilesCopy);

    // FASE 2: Miniaturas Animadas (Lento - Segundo Plano)
    await _processAnimatedBatch(safeFilesCopy);

    _isProcessingBatch = false;
  }

  Future<void> _processStaticBatch(List<FileSystemEntity> files) async {
    final List<File> toProcess = [];
    for (var entity in files) {
      if (entity is File && _isSupportedImageOrVideo(entity.path)) {
        final thumbPath = p.join(_thumbnailDir!.path, _getThumbName(entity.path));
        if (!await File(thumbPath).exists()) toProcess.add(entity);
      }
    }

    if (toProcess.isEmpty) return;

    isGeneratingNotifier.value = true;
    int processed = 0;
    // Concurrencia alta para imágenes (usa muchos núcleos)
    final batchSize = (Platform.numberOfProcessors > 2) ? Platform.numberOfProcessors - 1 : 2;

    for (int i = 0; i < toProcess.length; i += batchSize) {
      final end = (i + batchSize < toProcess.length) ? i + batchSize : toProcess.length;
      await Future.wait(toProcess.sublist(i, end).map((file) => getThumbnail(file)));
      processed += (end - i);
      progressNotifier.value = processed / toProcess.length;
    }
    isGeneratingNotifier.value = false;
  }

  Future<void> _processAnimatedBatch(List<FileSystemEntity> files) async {
    final List<File> videosToAnimate = [];
    for (var entity in files) {
      if (entity is File && _isVideoButton(entity.path)) {
        final animPath = p.join(_thumbnailDir!.path, _getAnimatedThumbName(entity.path));
        if (!await File(animPath).exists()) videosToAnimate.add(entity);
      }
    }

    if (videosToAnimate.isEmpty) return;

    isGeneratingAnimNotifier.value = true;
    animProgressNotifier.value = 0.0;

    int processed = 0;
    // IMPORTANTE: FFmpeg consume mucha CPU. Solo procesamos 1 o 2 videos a la vez 
    // para no congelar la computadora del usuario.
    const ffmpegBatchSize = 1; 

    for (int i = 0; i < videosToAnimate.length; i += ffmpegBatchSize) {
      final end = (i + ffmpegBatchSize < videosToAnimate.length) ? i + ffmpegBatchSize : videosToAnimate.length;
      
      // Llamamos a tu función de FFmpeg que creamos antes
      await Future.wait(videosToAnimate.sublist(i, end).map((file) => getAnimatedThumbnail(file)));
      
      processed += (end - i);
      animProgressNotifier.value = processed / videosToAnimate.length;
      
      // Pequeño respiro para el sistema
      await Future.delayed(const Duration(milliseconds: 100));
    }
    isGeneratingAnimNotifier.value = false;
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
    // ¡Añadimos .gif, .bmp, .mkv y .webm a la lista VIP!
    return [
      // Imágenes
      '.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', 
      // Videos
      '.mp4', '.mov', '.avi', '.mkv', '.webm'
    ].contains(ext);
  }

  bool _isVideoButton(String path) {
    final ext = _getRealExtension(path);
    return ['.mp4', '.mov', '.avi', '.mkv', '.webm'].contains(ext);
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
      final tempThumbPath = '$thumbPath.jpg'; 
      
      final originalFile = File(originalPath);
      bool success = false;

      try {
        if (await originalFile.exists()) {
          await originalFile.rename(tempPath);
        }

        // 1. Intentamos con el plugin nativo
        success = await plugin.getVideoThumbnail(
          srcFile: tempPath, 
          destFile: tempThumbPath, 
          width: 256,
          height: 256,
          format: 'jpeg',
          quality: 75,
        );

        // --- EL DETECTOR DE MENTIRAS ---
        // El plugin a veces devuelve 'true' pero crea un archivo inútil de 0 bytes.
        if (success) {
          final checkFile = File(tempThumbPath);
          if (!await checkFile.exists() || await checkFile.length() < 100) {
            success = false; // Lo desmentimos y forzamos el uso de FFmpeg
          }
        }

        // 2. Si falló (o fue un falso éxito), entra FFmpeg al rescate
        if (!success && _ffmpegExe != null && await _ffmpegExe!.exists()) {
          
          // --- ¡EL TRUCO ROBADO DEL PREVIEW ANIMADO! ---
          double startTimeInSeconds = 0.0;
          if (_ffprobeExe != null && await _ffprobeExe!.exists()) {
            final probeResult = await Process.run(_ffprobeExe!.path, [
              '-v', 'error',
              '-show_entries', 'format=duration',
              '-of', 'default=noprint_wrappers=1:nokey=1',
              tempPath
            ]);
            
            if (probeResult.exitCode == 0) {
              final durationStr = probeResult.stdout.toString().trim();
              final totalDuration = double.tryParse(durationStr) ?? 0.0;
              // Buscamos un fotograma seguro al 33% del video
              startTimeInSeconds = totalDuration / 3; 
            }
          }

          final result = await Process.run(_ffmpegExe!.path, [
            // IMPORTANTE: -ss va ANTES de -i para que salte la basura inicial instantáneamente
            '-ss', startTimeInSeconds.toStringAsFixed(2), 
            '-i', tempPath,
            '-vframes', '1', 
            '-vf', 'scale=256:-1',
            '-q:v', '2', // Calidad alta de JPEG
            '-y',
            tempThumbPath 
          ]);
          
          success = result.exitCode == 0;
          
          // Verificamos que FFmpeg también haya cumplido
          if (success) {
            final checkFile = File(tempThumbPath);
            if (!await checkFile.exists() || await checkFile.length() < 100) {
              success = false;
            }
          } else {
            debugPrint("Error FFmpeg estático: ${result.stderr}");
          }
        }

        // 3. Si tuvimos éxito comprobado, le ponemos el formato de tu bóveda (.vtx)
        if (success) {
          await File(tempThumbPath).rename(thumbPath);
        }

      } catch (e) {
        debugPrint("Error al generar miniatura de video: $e");
      } finally {
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          await tempFile.rename(originalPath);
        }
        
        final orphanedTempThumb = File(tempThumbPath);
        if (await orphanedTempThumb.exists()) {
          await orphanedTempThumb.delete();
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
      final realExt = _getRealExtension(originalImage.path);
      bool success = false;

      if (realExt == '.gif') {
        // ¡Usamos el nuevo motor para GIFs!
        success = await _generateWithGif2Webp(originalImage.path, thumbFile.path, 256);
      } else {
        // Usamos cwebp normal para JPG, PNG, y WebP estático
        success = await _generateWithCwebp(originalImage.path, thumbFile.path, 256);
      }

      if (success) {
        _addToCache(originalPath, thumbFile);
        return thumbFile; 
      } else {
        // Fallback: Si es un WebP animado (que estas herramientas no pueden 
        // redimensionar bien) devolvemos el original. 
        // (La Fase 1 en main.dart se encargará de que no consuma RAM).
        return originalImage; 
      }
    }
  }

  Future<bool> _generateWithGif2Webp(String inputPath, String outputPath, int width) async {
    if (_gif2webpExe == null || !await _gif2webpExe!.exists()) return false;

    try {
      final result = await Process.run(_gif2webpExe!.path, [
        '-q', '60', // Calidad ajustada para miniaturas ligeras
        '-resize', width.toString(), '0', // Redimensionar manteniendo aspecto
        '-min_size', // Optimiza los frames para que pese menos
        inputPath,
        '-o', outputPath
      ]);

      return result.exitCode == 0;
    } catch (e) {
      debugPrint("Error ejecutando gif2webp: $e");
      return false;
    }
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

  // NUEVO: Nomenclatura para el archivo animado
  String _getAnimatedThumbName(String originalPath) {
    final baseName = p.basenameWithoutExtension(originalPath);
    // Cambiamos .webp por .vtx
    return '$baseName.anim.vtx'; 
  }

  Future<File?> getAnimatedThumbnail(File originalVideo) async {
    if (_ffmpegExe == null || !_ffmpegExe!.existsSync() || 
        _ffprobeExe == null || !_ffprobeExe!.existsSync()) {
      return null;
    }

    final originalPath = originalVideo.path;
    final animPath = p.join(_thumbnailDir!.path, _getAnimatedThumbName(originalPath));
    final animFile = File(animPath);

    if (await animFile.exists() && await animFile.length() > 0) {
      return animFile;
    }

    final realExt = _getRealExtension(originalPath);
    final tempPath = '$originalPath$realExt';
    bool renamed = false;

    try {
      await originalVideo.rename(tempPath);
      renamed = true;

      // --- PASO 1: EL ESPÍA (ffprobe) ---
      // Le pedimos que nos devuelva SOLO la duración en segundos (ej. "120.5")
      final probeResult = await Process.run(_ffprobeExe!.path, [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        tempPath
      ]);

      double startTimeInSeconds = 0.0;
      
      if (probeResult.exitCode == 0) {
        final durationStr = probeResult.stdout.toString().trim();
        final totalDuration = double.tryParse(durationStr) ?? 0.0;
        
        // ¡Calculamos el 33% del video!
        startTimeInSeconds = totalDuration / 3;
      }

      // --- PASO 2: EL CREADOR (ffmpeg) ---
      final result = await Process.run(_ffmpegExe!.path, [
        // Usamos el tiempo exacto que calculamos
        '-ss', startTimeInSeconds.toStringAsFixed(2), 
        '-t', '3',         
        '-i', tempPath,
        '-vf', 'fps=10,scale=256:-1:flags=lanczos', 
        '-loop', '0',
        '-f', 'webp',      
        '-y',              
        animPath
      ]);

      if (result.exitCode == 0) {
        return animFile;
      } else {
        debugPrint("Error en FFmpeg: ${result.stderr}");
        return null;
      }
    } catch (e) {
      debugPrint("Excepción al generar animación: $e");
      return null;
    } finally {
      if (renamed) {
        await File(tempPath).rename(originalPath);
      }
    }
  }
}