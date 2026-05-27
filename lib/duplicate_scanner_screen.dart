import 'dart:io';
import 'dart:isolate';
import 'dart:ui'; // Para el ImageFilter.blur
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;

import 'main.dart';
import 'metadata_service.dart';
import 'thumbnail_service.dart';
import 'ui_utils.dart'; 

// --- MODELO DE DATOS ---
class DuplicateGroup {
  List<File> files;
  File bestFile;
  Set<String> pathsToDelete;

  DuplicateGroup({required this.files, required this.bestFile}) 
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
  
  ReceivePort? _receivePort;
  Isolate? _isolate;

  // Calculador global de seleccionados
  int get _totalMarkedToDelete => _duplicateGroups.fold(0, (sum, group) => sum + group.pathsToDelete.length);

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _receivePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
    super.dispose();
  }

  String _formatETA(double etaMs) {
    if (etaMs < 0 || etaMs.isNaN) return "Calculando...";
    final duration = Duration(milliseconds: etaMs.toInt());
    if (duration.inMinutes > 0) {
      return "${duration.inMinutes} min ${duration.inSeconds.remainder(60)} seg";
    }
    return "${duration.inSeconds} seg";
  }

  Future<void> _startScan() async {
    try {
      final allEntities = await widget.vaultDir.list(recursive: true).toList();
      final imageFiles = allEntities.whereType<File>().where((file) {
        final realExt = _getRealExtensionForScanner(file.path);
        if (['.mp4', '.mov', '.avi', '.mkv', '.webm'].contains(realExt)) return false;
        if (realExt == '.gif') return false;
        if (realExt == '.webp' && _isAnimatedWebp(file.path)) return false;
        return ['.jpg', '.jpeg', '.png', '.webp', '.bmp'].contains(realExt);
      }).toList();

      if (imageFiles.isEmpty) {
        setState(() => _isScanning = false);
        return;
      }

      final paths = imageFiles.map((e) => e.path).toList();
      final supportDir = await getApplicationSupportDirectory();
      final thumbDirPath = p.join(supportDir.path, 'thumbnails');

      _receivePort = ReceivePort();
      _isolate = await Isolate.spawn(vortexScannerWorker, [_receivePort!.sendPort, paths, thumbDirPath]);

      _receivePort!.listen((message) {
        if (message is Map) {
          final type = message['type'];
          
          if (type == 'progress') {
            setState(() {
              _progress = message['progress'];
              _etaText = _formatETA(message['etaMs']);
              _statusText = "Analizando ${message['processed']} de ${message['total']} imágenes";
            });
          } 
          else if (type == 'status') {
            setState(() {
              _progress = 1.0;
              _statusText = message['message'];
              _etaText = "Casi listo";
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
        showGlassSnackBar(context, 'Error al escanear: $e', icon: Icons.error_outline);
      }
    }
  }

  // --- BORRADO GLOBAL OPTIMIZADO ---
  Future<void> _deleteAllSelected() async {
    int deletedCount = 0;
    int failedCount = 0; // Para contar los que Windows no quiso soltar
    
    // Clonamos la lista para iterar sin alterar el for
    for (var group in _duplicateGroups.toList()) {
      final filesToDelete = group.pathsToDelete.map((path) => File(path)).toList();
      if (filesToDelete.isEmpty) continue;

      for (final file in filesToDelete) {
        try {
          final imageId = p.relative(file.path, from: widget.vaultDir.path);
          
          // 1. Expulsamos la imagen de la memoria caché de Flutter
          await FileImage(file).evict();
          
          // 2. Le damos a Windows 150 milisegundos para soltar el bloqueo
          await Future.delayed(const Duration(milliseconds: 150));

          if (await file.exists()) {
            await file.delete(); // Ahora sí, lo borramos
          }
          
          // 3. Borramos metadatos y miniaturas solo si el borrado físico tuvo éxito
          await widget.metadataService.deleteMetadata(imageId);
          await widget.thumbnailService.clearThumbnail(p.basename(file.path));
          
          deletedCount++;
        } catch (e) {
          debugPrint("No se pudo borrar el archivo (Bloqueado): ${file.path}");
          failedCount++;
          // Si falla, lo desmarcamos para que no cause errores gráficos
          group.pathsToDelete.remove(file.path);
        }
      }

      setState(() {
        // Limpiamos los exitosos de la interfaz
        group.files.removeWhere((f) => !f.existsSync());
        group.pathsToDelete.clear();
        
        if (group.files.length <= 1) {
          _duplicateGroups.remove(group);
        } else {
          group.files.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
          group.bestFile = group.files.first;
        }
      });
    }

    if (mounted) {
      if (failedCount > 0) {
        showGlassSnackBar(context, '$deletedCount eliminados. $failedCount estaban en uso por Windows.', icon: Icons.warning_amber_rounded, iconColor: Colors.amber);
      } else if (deletedCount > 0) {
        showGlassSnackBar(context, '$deletedCount elementos depurados del Vórtice.', icon: Icons.auto_delete_outlined);
      }
    }
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

  Widget _buildLoadingState() {
    return Center(
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: const Color(0xFF151515),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12, width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.layers_clear_outlined, size: 60, color: Colors.white70),
            const SizedBox(height: 24),
            Text(_statusText, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
            const SizedBox(height: 24),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 6,
                backgroundColor: Colors.white10,
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF0A84FF)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(_progress * 100).toStringAsFixed(1)}%', 
                  style: const TextStyle(color: Colors.white70, fontSize: 12)
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

  Widget _buildResultsState() {
    if (_duplicateGroups.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 60, color: Colors.white54),
            SizedBox(height: 16),
            Text('Vórtice optimizado', style: TextStyle(fontSize: 16, color: Colors.white)),
            SizedBox(height: 8),
            Text('No se encontraron imágenes redundantes.', style: TextStyle(color: Colors.white38, fontSize: 13)),
          ],
        ),
      );
    }

    return Stack(
      children: [
        ListView.builder(
          padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 100), // Espacio para el panel inferior
          itemCount: _duplicateGroups.length,
          itemBuilder: (context, index) {
            final group = _duplicateGroups[index];
            return _buildDuplicateCard(group);
          },
        ),
        
        // --- BARRA FLOTANTE GLOBAL (Elegante y no intrusiva) ---
        if (_totalMarkedToDelete > 0)
          Positioned(
            bottom: 24, left: 0, right: 0,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF252525).withOpacity(0.85),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.white12, width: 0.5),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20, offset: const Offset(0, 10))
                      ]
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.auto_delete_outlined, color: Colors.white70, size: 20),
                        const SizedBox(width: 12),
                        Text(
                          '$_totalMarkedToDelete elementos seleccionados', 
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)
                        ),
                        const SizedBox(width: 24),
                        ElevatedButton(
                          onPressed: _deleteAllSelected,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          ),
                          child: const Text('Eliminar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        )
                      ],
                    ),
                  ),
                ),
              ),
            ),
          )
      ],
    );
  }

  Widget _buildDuplicateCard(DuplicateGroup group) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Row(
              children: [
                const Icon(Icons.difference_outlined, color: Colors.white54, size: 18),
                const SizedBox(width: 10),
                Text('${group.files.length} Coincidencias detectadas', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                const Spacer(),
                
                // Menú QoL (Calidad de Vida) por grupo
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz, color: Colors.white54, size: 20),
                  color: const Color(0xFF2C2C2E),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Colors.white12, width: 0.5)),
                  tooltip: 'Opciones de selección',
                  onSelected: (val) {
                    setState(() {
                      if (val == 'auto') {
                        group.pathsToDelete = group.files.where((f) => f.path != group.bestFile.path).map((f) => f.path).toSet();
                      } else if (val == 'clear') {
                        group.pathsToDelete.clear();
                      }
                    });
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'auto', 
                      child: Row(
                        children: [
                          Icon(Icons.auto_awesome, size: 16, color: Colors.white70),
                          SizedBox(width: 10),
                          Text('Conservar de mayor resolución', style: TextStyle(fontSize: 13, color: Colors.white)),
                        ],
                      )
                    ),
                    const PopupMenuItem(
                      value: 'clear', 
                      child: Row(
                        children: [
                          Icon(Icons.deselect, size: 16, color: Colors.white70),
                          SizedBox(width: 10),
                          Text('Desmarcar todos', style: TextStyle(fontSize: 13, color: Colors.white)),
                        ],
                      )
                    ),
                  ]
                )
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          SizedBox(
            height: 190,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(16),
              itemCount: group.files.length,
              itemBuilder: (context, idx) {
                final file = group.files[idx];
                final isBest = file.path == group.bestFile.path;
                final isMarkedToDelete = group.pathsToDelete.contains(file.path);
                final sizeMB = (file.lengthSync() / (1024 * 1024)).toStringAsFixed(2);

                return GestureDetector(
                  onTap: () {
                    // Acción primaria ahora es seleccionar/deseleccionar para mayor fluidez.
                    // Si se quiere ver la imagen completa, se usará long press o doble tap (o al revés, según prefieras).
                    // Para mantener la lógica visual, asignaré la selección al tap normal.
                    setState(() {
                      if (isMarkedToDelete) {
                        group.pathsToDelete.remove(file.path);
                      } else {
                        group.pathsToDelete.add(file.path);
                      }
                    });
                  },
                  onDoubleTap: () {
                    // Doble tap para comparar a pantalla completa
                    Navigator.push(
                      context,
                      PageRouteBuilder(
                        transitionDuration: const Duration(milliseconds: 300),
                        opaque: false,
                        pageBuilder: (context, _, __) => FullScreenImageViewer(
                          imageFiles: group.files, 
                          initialIndex: idx,
                          instantTransition: true, 
                          vaultRootPath: widget.vaultDir.path,
                          metadataService: widget.metadataService,
                          exportCallback: (f) async {}, 
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
                            ? Colors.white54 
                            : isBest ? Colors.transparent : Colors.transparent, 
                        width: isMarkedToDelete ? 1.5 : 0
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
                                      width: 16, height: 16, 
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24)
                                    )
                                  ),
                                );
                              }
                              return Image.file(
                                snapshot.data!,
                                fit: BoxFit.cover,
                                cacheWidth: 300,
                                errorBuilder: (context, error, stackTrace) => Container(
                                  color: const Color(0xFF1C1C1E),
                                  child: const Center(child: Icon(Icons.broken_image, color: Colors.white24, size: 30)),
                                ),
                              );
                            },
                          ),
                        ),
                        
                        // Sombreado elegante para los descartados
                        if (isMarkedToDelete)
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.65),
                              borderRadius: BorderRadius.circular(6)
                            )
                          ),

                        // --- CHECKBOX MINIMALISTA ---
                        Positioned(
                          top: 8, right: 8,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: isMarkedToDelete ? Colors.white : Colors.black45,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 1.5)
                            ),
                            child: Icon(
                              Icons.check,
                              size: 14, 
                              color: isMarkedToDelete ? Colors.black : Colors.transparent
                            ),
                          ),
                        ),

                        // Gradiente inferior para legibilidad
                        Positioned(
                          bottom: 0, left: 0, right: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(6), bottomRight: Radius.circular(6)),
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter, end: Alignment.topCenter,
                                colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('$sizeMB MB', style: TextStyle(color: isMarkedToDelete ? Colors.white54 : Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                if (isBest && !isMarkedToDelete) 
                                  const Text('Recomendado', style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w500)),
                                if (isMarkedToDelete) 
                                  const Text('Descartado', style: TextStyle(color: Colors.white54, fontSize: 10, decoration: TextDecoration.lineThrough)),
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

// --- LÓGICA DE ESCANEO (BACKGROUND) ---
// Se mantiene intacta al no estar relacionada con la UI directamente, 
// pero se adjunta para mantener el archivo autosuficiente.

Future<List<List<String>>> findDuplicatesBackground(List<String> paths) async {
  final List<List<String>> groups = [];
  final Map<String, String> hashMap = {}; 

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
    } catch (_) {}
  }

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
  RandomAccessFile? raf;
  try {
    final file = File(filePath);
    raf = file.openSync(mode: FileMode.read);
    final header = raf.readSync(21); 
    if (header.length >= 21) {
      final isWebP = String.fromCharCodes(header.sublist(8, 12)) == 'WEBP';
      final isVP8X = String.fromCharCodes(header.sublist(12, 16)) == 'VP8X';
      if (isWebP && isVP8X) return (header[20] & 0x02) != 0;
    }
  } catch (_) {
    // Ignoramos el error, pero pasamos al finally
  } finally {
    // ESTO ES CLAVE: Asegura que Windows libere el archivo siempre
    try { raf?.closeSync(); } catch (_) {}
  }
  return false;
}

void vortexScannerWorker(List<dynamic> args) {
  final SendPort sendPort = args[0];
  final List<String> paths = args[1];
  final String thumbnailsDir = args[2]; 
  
  final List<List<String>> groups = [];
  final Map<String, String> hashMap = {}; 

  final int totalFiles = paths.length;
  final startTime = DateTime.now();

  for (int i = 0; i < totalFiles; i++) {
    final path = paths[i];
    try {
      final baseName = p.basenameWithoutExtension(path);
      final thumbPath = p.join(thumbnailsDir, '$baseName.thumb.vtx');
      
      final fileToRead = File(thumbPath).existsSync() ? File(thumbPath) : File(path);

      final bytes = fileToRead.readAsBytesSync();
      final image = img.decodeImage(bytes);
      
      if (image != null) {
        final resized = img.copyResize(image, width: 9, height: 8);
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
    } catch (_) {}

    final processed = i + 1;
    
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