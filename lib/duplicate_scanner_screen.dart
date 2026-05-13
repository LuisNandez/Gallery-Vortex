import 'dart:io';
import 'dart:isolate';
import 'main.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'metadata_service.dart';
import 'thumbnail_service.dart';
import 'ui_utils.dart'; // Para tu showGlassSnackBar
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

// --- MODELO DE DATOS ---
class DuplicateGroup {
  List<File> files;
  File bestFile;
  Set<String> pathsToDelete; // <-- Estado dinámico de selección

  DuplicateGroup({required this.files, required this.bestFile}) 
    // Por defecto, marcamos para eliminar todo MENOS el mejor archivo
    : pathsToDelete = files.where((f) => f.path != bestFile.path).map((f) => f.path).toSet();
}

// --- PANTALLA PRINCIPAL ---
class DuplicateScannerScreen extends StatefulWidget {
  final Directory vaultDir;
  final MetadataService metadataService;
  final ThumbnailService thumbnailService;

  const DuplicateScannerScreen({
    super.key,
    required this.vaultDir,
    required this.metadataService,
    required this.thumbnailService,
  });

  @override
  State<DuplicateScannerScreen> createState() => _DuplicateScannerScreenState();
}

class _DuplicateScannerScreenState extends State<DuplicateScannerScreen> {
  bool _isScanning = true;
  String _statusText = "Preparando escaneo...";
  double _progress = 0.0;
  String _etaText = "Calculando...";
  List<DuplicateGroup> _duplicateGroups = [];
  
  // Guardamos referencias para limpiar la memoria si el usuario sale antes de terminar
  ReceivePort? _receivePort;
  Isolate? _isolate;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    // Si el usuario cierra la ventana, matamos el proceso en segundo plano
    _receivePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
    super.dispose();
  }

  // Función para formatear el tiempo restante de forma amigable
  String _formatETA(double etaMs) {
    if (etaMs < 0 || etaMs.isNaN) return "Calculando...";
    final duration = Duration(milliseconds: etaMs.toInt());
    if (duration.inMinutes > 0) {
      return "${duration.inMinutes} min ${duration.inSeconds.remainder(60)} seg restantes";
    }
    return "${duration.inSeconds} seg restantes";
  }

  Future<void> _startScan() async {
    try {
      final allEntities = await widget.vaultDir.list(recursive: true).toList();
      final imageFiles = allEntities.whereType<File>().where((file) {
        // 1. Descubrimos la extensión real (aunque esté cifrada en .vtx)
        final realExt = _getRealExtensionForScanner(file.path);
        
        // 2. Rechazamos todos los videos inmediatamente
        if (['.mp4', '.mov', '.avi', '.mkv', '.webm'].contains(realExt)) return false;
        
        // 3. Rechazamos los GIFs (siempre son animados)
        if (realExt == '.gif') return false;
        
        // 4. Rechazamos los WebP solo si descubrimos que tienen movimiento
        if (realExt == '.webp' && _isAnimatedWebp(file.path)) return false;

        // 5. Si sobrevivió a todo lo anterior, aceptamos solo si es una imagen estática válida
        return ['.jpg', '.jpeg', '.png', '.webp', '.bmp'].contains(realExt);
      }).toList();

      if (imageFiles.isEmpty) {
        setState(() => _isScanning = false);
        return;
      }

      final paths = imageFiles.map((e) => e.path).toList();

      // --- NUEVO: Obtenemos la ruta exacta de la carpeta thumbnails de GVortex ---
      final supportDir = await getApplicationSupportDirectory();
      final thumbDirPath = p.join(supportDir.path, 'thumbnails');

      _receivePort = ReceivePort();

      // Pasamos thumbDirPath como el tercer argumento de nuestra lista
      _isolate = await Isolate.spawn(vortexScannerWorker, [_receivePort!.sendPort, paths, thumbDirPath]);

      _receivePort!.listen((message) {
        if (message is Map) {
          final type = message['type'];
          
          if (type == 'progress') {
            setState(() {
              _progress = message['progress'];
              _etaText = _formatETA(message['etaMs']);
              _statusText = "Analizando ${message['processed']} de ${message['total']} imágenes...";
            });
          } 
          // ... (El resto del código de los listeners se queda exactamente igual)
          else if (type == 'status') {
            setState(() {
              _progress = 1.0;
              _statusText = message['message'];
              _etaText = "Casi listo...";
            });
          } 
          else if (type == 'done') {
            _receivePort?.close();
            _isolate?.kill();
            
            final rawGroups = message['groups'] as List<List<String>>;
            final groups = <DuplicateGroup>[];
            
            for (var groupPaths in rawGroups) {
              final files = groupPaths.map((path) => File(path)).toList();
              files.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
              groups.add(DuplicateGroup(files: files, bestFile: files.first));
            }

            setState(() {
              _duplicateGroups = groups;
              _isScanning = false;
            });
          }
        }
      });

    } catch (e) {
      if (mounted) {
        setState(() => _isScanning = false);
        showGlassSnackBar(context, 'Error al escanear: $e', icon: Icons.error_outline, iconColor: Colors.redAccent);
      }
    }
  }

  // (Conserva aquí tu función _keepBestAndRemoveRest tal y como la tienes)
  Future<void> _deleteSelectedInGroup(DuplicateGroup group) async {
    final filesToDelete = group.pathsToDelete.map((path) => File(path)).toList();
    if (filesToDelete.isEmpty) return;

    for (final file in filesToDelete) {
      final imageId = p.relative(file.path, from: widget.vaultDir.path);
      await widget.metadataService.deleteMetadata(imageId);
      await widget.thumbnailService.clearThumbnail(p.basename(file.path));
      if (await file.exists()) await file.delete();
    }

    setState(() {
      // 1. Quitamos los archivos borrados de la lista
      group.files.removeWhere((f) => group.pathsToDelete.contains(f.path));
      group.pathsToDelete.clear();
      
      // 2. Si queda 1 o ninguno, ya no es un duplicado, desaparece la tarjeta entera
      if (group.files.length <= 1) {
        _duplicateGroups.remove(group);
      } else {
        // 3. Si quedaron 2 o más, recalculamos cuál es el "mejor" ahora
        group.files.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
        group.bestFile = group.files.first;
      }
    });

    if (mounted) showGlassSnackBar(context, '${filesToDelete.length} duplicados eliminados.', icon: Icons.delete_sweep);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xE61C1C1E),
        title: const Text('Limpieza de Vórtice', style: TextStyle(fontSize: 14)),
        centerTitle: true,
      ),
      body: _isScanning 
          ? _buildLoadingState() 
          : _buildResultsState(),
    );
  }

  // --- NUEVA INTERFAZ DE CARGA CON BARRA DE PROGRESO ---
  Widget _buildLoadingState() {
    return Center(
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12, width: 0.5),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20, offset: const Offset(0, 10))
          ]
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.saved_search_rounded, size: 60, color: Color(0xFF0A84FF)),
            const SizedBox(height: 24),
            Text(_statusText, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 24),
            
            // Barra de progreso animada
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 8,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF0A84FF)),
              ),
            ),
            const SizedBox(height: 16),
            
            // Textos descriptivos (Porcentaje y ETA)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(_progress * 100).toStringAsFixed(1)}%', 
                  style: const TextStyle(color: Color(0xFF0A84FF), fontWeight: FontWeight.bold, fontSize: 13)
                ),
                Text(
                  _etaText, 
                  style: const TextStyle(color: Colors.white54, fontSize: 12)
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // (Conserva aquí tus funciones _buildResultsState y _buildDuplicateCard)
  Widget _buildResultsState() {
    if (_duplicateGroups.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 80, color: Color(0xFF32D74B)),
            SizedBox(height: 16),
            Text('¡Tu bóveda está limpia!', style: TextStyle(fontSize: 18, color: Colors.white)),
            SizedBox(height: 8),
            Text('No se encontraron imágenes duplicadas.', style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _duplicateGroups.length,
      itemBuilder: (context, index) {
        final group = _duplicateGroups[index];
        return _buildDuplicateCard(group);
      },
    );
  }

  Widget _buildDuplicateCard(DuplicateGroup group) {
    final toDeleteCount = group.pathsToDelete.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                const Icon(Icons.content_copy, color: Colors.amber, size: 18),
                const SizedBox(width: 8),
                Text('${group.files.length} Archivos similares', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                const Spacer(),
                
                // Botón interactivo de borrado
                ElevatedButton.icon(
                  onPressed: toDeleteCount > 0 ? () => _deleteSelectedInGroup(group) : null,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: Text('Eliminar $toDeleteCount seleccionados'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent.withOpacity(0.2),
                    foregroundColor: Colors.redAccent,
                    disabledForegroundColor: Colors.white24,
                    disabledBackgroundColor: Colors.white12,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                )
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          SizedBox(
            height: 180,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              itemCount: group.files.length,
              itemBuilder: (context, idx) {
                final file = group.files[idx];
                final isBest = file.path == group.bestFile.path;
                final isMarkedToDelete = group.pathsToDelete.contains(file.path);
                final sizeMB = (file.lengthSync() / (1024 * 1024)).toStringAsFixed(2);

                return GestureDetector(
                  // --- LA MAGIA DE LA COMPARACIÓN: ABRE EL VISOR EN MODO INSTANTÁNEO ---
                  onTap: () {
                    Navigator.push(
                      context,
                      PageRouteBuilder(
                        transitionDuration: const Duration(milliseconds: 300),
                        opaque: false,
                        pageBuilder: (context, _, __) => FullScreenImageViewer(
                          imageFiles: group.files, // Solo le pasa las imágenes de este grupo
                          initialIndex: idx,
                          instantTransition: true, // Corte de cámara directo
                          vaultRootPath: widget.vaultDir.path,
                          metadataService: widget.metadataService,
                          exportCallback: (f) async {}, // Dummy
                          onClose: () => Navigator.pop(context),
                        )
                      )
                    );
                  },
                  child: Container(
                    width: 140,
                    margin: const EdgeInsets.only(right: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isMarkedToDelete 
                            ? Colors.redAccent.withOpacity(0.5) 
                            : isBest ? const Color(0xFF32D74B) : Colors.transparent, 
                        width: 2
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: FutureBuilder<File>(
                            future: widget.thumbnailService.getThumbnail(file),
                            builder: (context, snapshot) {
                              if (!snapshot.hasData) {
                                return Container(
                                  color: const Color(0xFF1C1C1E),
                                  child: const Center(
                                    child: SizedBox(
                                      width: 20, height: 20, 
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A84FF))
                                    )
                                  ),
                                );
                              }
                              return Image.file(
                                snapshot.data!,
                                fit: BoxFit.cover,
                                cacheWidth: 300,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    color: const Color(0xFF1C1C1E),
                                    child: const Center(
                                      child: Icon(Icons.broken_image, color: Colors.white24, size: 30)
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                        
                        // Sombreado rojo si está marcada para borrar
                        if (isMarkedToDelete)
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(6)
                            )
                          ),

                        // --- BOTÓN CHECKBOX PARA SELECCIONAR/DESELECCIONAR ---
                        Positioned(
                          top: 8, right: 8,
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                if (isMarkedToDelete) {
                                  group.pathsToDelete.remove(file.path);
                                } else {
                                  group.pathsToDelete.add(file.path);
                                }
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: isMarkedToDelete ? Colors.redAccent : Colors.black54,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 1.5)
                              ),
                              child: Icon(
                                isMarkedToDelete ? Icons.close : Icons.check,
                                size: 16, color: Colors.white
                              ),
                            ),
                          ),
                        ),

                        // Textos inferiores
                        Positioned(
                          bottom: 0, left: 0, right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            color: Colors.black.withOpacity(0.85),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('$sizeMB MB', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                if (isBest && !isMarkedToDelete) const Text('Sugerido', style: TextStyle(color: Color(0xFF32D74B), fontSize: 10, fontWeight: FontWeight.bold)),
                                if (isMarkedToDelete) const Text('Se eliminará', style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        )
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Pon esto hasta abajo, FUERA de cualquier clase
Future<List<List<String>>> findDuplicatesBackground(List<String> paths) async {
  final List<List<String>> groups = [];
  final Map<String, String> hashMap = {}; 

  // FASE 1: Calcular la huella digital (dHash)
  for (final path in paths) {
    try {
      final bytes = File(path).readAsBytesSync();
      final image = img.decodeImage(bytes);
      
      if (image != null) {
        final grayscale = img.grayscale(image);
        final resized = img.copyResize(grayscale, width: 9, height: 8);
        
        String hash = '';
        for (int y = 0; y < 8; y++) {
          for (int x = 0; x < 8; x++) {
            final p1 = resized.getPixel(x, y).r;
            final p2 = resized.getPixel(x + 1, y).r;
            hash += (p1 < p2) ? '1' : '0';
          }
        }
        hashMap[path] = hash;
      }
    } catch (_) {
      // Ignoramos archivos corruptos
    }
  }

  // FASE 2: Comparar las huellas
  final Set<String> processed = {};
  final pathsWithHashes = hashMap.keys.toList();

  for (int i = 0; i < pathsWithHashes.length; i++) {
    final path1 = pathsWithHashes[i];
    if (processed.contains(path1)) continue;

    final hash1 = hashMap[path1]!;
    final currentGroup = <String>[path1];

    for (int j = i + 1; j < pathsWithHashes.length; j++) {
      final path2 = pathsWithHashes[j];
      if (processed.contains(path2)) continue;

      final hash2 = hashMap[path2]!;
      
      int distance = 0;
      for (int k = 0; k < 64; k++) {
        if (hash1[k] != hash2[k]) distance++;
      }

      // Nivel de tolerancia (5 bits de diferencia)
      if (distance <= 5) {
        currentGroup.add(path2);
        processed.add(path2);
      }
    }

    if (currentGroup.length > 1) {
      groups.add(currentGroup);
    }
    processed.add(path1);
  }

  return groups;
}

// --- FUNCIONES AUXILIARES DE FILTRADO ---

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

String _getRealExtensionForScanner(String path) {
  if (path.toLowerCase().endsWith('.vtx')) {
    final base = p.basenameWithoutExtension(path);
    final lastZero = base.lastIndexOf('0');
    if (lastZero != -1) {
      return _decipherExtension(base.substring(lastZero));
    }
  }
  return p.extension(path).toLowerCase();
}

bool _isAnimatedWebp(String filePath) {
  try {
    final file = File(filePath);
    final raf = file.openSync(mode: FileMode.read);
    final header = raf.readSync(21); 
    raf.closeSync();
    if (header.length >= 21) {
      final isWebP = String.fromCharCodes(header.sublist(8, 12)) == 'WEBP';
      final isVP8X = String.fromCharCodes(header.sublist(12, 16)) == 'VP8X';
      if (isWebP && isVP8X) return (header[20] & 0x02) != 0;
    }
  } catch (_) {}
  return false;
}

void vortexScannerWorker(List<dynamic> args) {
  final SendPort sendPort = args[0];
  final List<String> paths = args[1];
  final String thumbnailsDir = args[2]; // <-- NUEVO: Recibimos la ruta de miniaturas
  
  final List<List<String>> groups = [];
  final Map<String, String> hashMap = {}; 

  final int totalFiles = paths.length;
  final startTime = DateTime.now();

  for (int i = 0; i < totalFiles; i++) {
    final path = paths[i];
    try {
      // --- SUPER OPTIMIZACIÓN 1: LEER MINIATURAS ---
      // Calculamos cómo se llama la miniatura de este archivo en GVortex
      final baseName = p.basenameWithoutExtension(path);
      final thumbPath = p.join(thumbnailsDir, '$baseName.thumb.vtx');
      
      // Si la miniatura existe, leemos esa (100x más rápido). Si no, usamos el original.
      final fileToRead = File(thumbPath).existsSync() ? File(thumbPath) : File(path);

      final bytes = fileToRead.readAsBytesSync();
      final image = img.decodeImage(bytes);
      
      if (image != null) {
        // --- SUPER OPTIMIZACIÓN 2: ORDEN MATEMÁTICO ---
        // 1. Primero encogemos a 9x8 (Destruye millones de píxeles innecesarios en microsegundos)
        final resized = img.copyResize(image, width: 9, height: 8);
        // 2. LUEGO pasamos a blanco y negro (Solo procesa 72 píxeles)
        final grayscale = img.grayscale(resized);
        
        String hash = '';
        for (int y = 0; y < 8; y++) {
          for (int x = 0; x < 8; x++) {
            final p1 = grayscale.getPixel(x, y).r;
            final p2 = grayscale.getPixel(x + 1, y).r;
            hash += (p1 < p2) ? '1' : '0';
          }
        }
        hashMap[path] = hash;
      }
    } catch (_) {
      // Ignoramos archivos corruptos
    }

    // --- REPORTE DE PROGRESO (Igual que antes) ---
    final processed = i + 1;
    
    // Solo enviamos actualización a la UI cada 50 imágenes o al final para no saturar el canal de comunicación
    if (processed % 50 == 0 || processed == totalFiles) {
      final progress = processed / totalFiles;
      final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;
      final avgTimePerFile = elapsedMs / processed;
      final remainingFiles = totalFiles - processed;
      final etaMs = avgTimePerFile * remainingFiles;
      
      sendPort.send({
        'type': 'progress',
        'progress': progress,
        'etaMs': etaMs,
        'processed': processed,
        'total': totalFiles,
      });
    }
  }

  // FASE 2: Comparar las huellas (Esto es casi instantáneo)
  sendPort.send({
    'type': 'status',
    'message': 'Cruzando datos y buscando coincidencias...'
  });

  final Set<String> processedFiles = {};
  final pathsWithHashes = hashMap.keys.toList();

  for (int i = 0; i < pathsWithHashes.length; i++) {
    final path1 = pathsWithHashes[i];
    if (processedFiles.contains(path1)) continue;

    final hash1 = hashMap[path1]!;
    final currentGroup = <String>[path1];

    for (int j = i + 1; j < pathsWithHashes.length; j++) {
      final path2 = pathsWithHashes[j];
      if (processedFiles.contains(path2)) continue;

      final hash2 = hashMap[path2]!;
      
      int distance = 0;
      for (int k = 0; k < 64; k++) {
        if (hash1[k] != hash2[k]) distance++;
      }

      if (distance <= 5) {
        currentGroup.add(path2);
        processedFiles.add(path2);
      }
    }

    if (currentGroup.length > 1) {
      groups.add(currentGroup);
    }
    processedFiles.add(path1);
  }

  sendPort.send({
    'type': 'done',
    'groups': groups,
  });
}