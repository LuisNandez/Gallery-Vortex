import 'dart:io';
import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watcher/watcher.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'video_player_widget.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Imports de los nuevos archivos
import 'metadata_service.dart';
import 'tag_editor_dialog.dart';
import 'rating_stars_display.dart';
import 'pin_input_boxes.dart';
import 'thumbnail_service.dart'; // ¡IMPORTANTE! Importar el nuevo servicio

const String _vortexFolderPathKey = 'vortex_folder_path';
const String _masterPinKey = 'master_pin';
const String _thumbnailExtentKey = 'thumbnail_extent';
const String _closeActionKey = 'close_action'; // 'exit' or 'minimize'
const String _startupActionKey = 'startup_action'; // bool

enum CloseAction { exit, minimize }

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  
  await windowManager.ensureInitialized();

  PackageInfo packageInfo = await PackageInfo.fromPlatform();
  launchAtStartup.setup(
    appName: packageInfo.appName,
    appPath: Platform.resolvedExecutable,
    args: ['--minimized'],
  );

  WindowOptions windowOptions = const WindowOptions(
    size: Size(800, 600),
    center: true,
    backgroundColor: Colors.black,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (args.contains('--minimized')) {
      // Si existe (inicio automático), inicia oculta
      await windowManager.hide();
    } else {
      // Si no existe (inicio manual), se muestra
      await windowManager.show();
      await windowManager.focus();
    }
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GVortex',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const AuthWrapper(),
    );
  }
}

class BackgroundServiceScreen extends StatelessWidget {
  const BackgroundServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.shield_moon_outlined, size: 40, color: Colors.white38),
            SizedBox(height: 16),
            Text(
              'GVortex está activo en segundo plano.',
              style: TextStyle(color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WindowListener, TrayListener {
  bool _isAuthenticated = false;
  bool _isWindowVisible = true;

  final GlobalKey<_VaultExplorerScreenState> _vaultExplorerKey = GlobalKey<_VaultExplorerScreenState>();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initTray();
  }
  
  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initTray() async {
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png',
    );
    Menu menu = Menu(items: [
      MenuItem(key: 'show_window', label: 'Mostrar Aplicación'),
      MenuItem.separator(),
      MenuItem(key: 'exit_application', label: 'Cerrar Aplicación'),
    ]);
    await trayManager.setContextMenu(menu);
    await trayManager.setToolTip('Galería Vórtice');
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    setState(() {
      _isWindowVisible = true;
      _isAuthenticated = false;
    });
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show_window') {
      windowManager.show();
      setState(() {
        _isWindowVisible = true;
        _isAuthenticated = false;
      });
    } else if (menuItem.key == 'exit_application') {
      windowManager.destroy();
    }
  }

  // --- NUEVOS LISTENERS DE VENTANA ---
  @override
  void onWindowHide() {
    setState(() {
      _isWindowVisible = false;
      // Le decimos a VaultExplorer que libere sus recursos de UI.
      _vaultExplorerKey.currentState?.pause();
    });
  }

  @override
  void onWindowShow() {
    setState(() {
      _isWindowVisible = true;
      _isAuthenticated = false; // Forzar re-autenticación por seguridad.
      // Le decimos a VaultExplorer que se prepare para ser mostrado.
      _vaultExplorerKey.currentState?.resume();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 1. El explorador SIEMPRE está vivo para que el Watcher funcione,
        // pero lo ocultamos (Offstage) si no está visible o no hay PIN ingresado.
        Offstage(
          offstage: !_isWindowVisible || !_isAuthenticated,
          child: VaultExplorerScreen(
            key: _vaultExplorerKey,
            setAuthenticated: (value) {
              setState(() {
                _isAuthenticated = value;
              });
            },
          ),
        ),
        
        // 2. Pantallas de estado superpuestas (Bloqueo o Background)
        if (!_isWindowVisible)
          const BackgroundServiceScreen()
        else if (!_isAuthenticated)
          PinAuthScreen(
            onAuthenticated: () {
              setState(() {
                _isAuthenticated = true;
              });
            },
            setAuthenticated: (value) {
              setState(() {
                _isAuthenticated = value;
              });
            },
          ),
      ],
    );
  }
}

class VaultExplorerScreen extends StatefulWidget {
  final Directory? currentDirectory;
  final Function(bool) setAuthenticated;

  const VaultExplorerScreen({
    super.key,
    this.currentDirectory,
    required this.setAuthenticated,
  });

  @override
  State<VaultExplorerScreen> createState() => _VaultExplorerScreenState();
}

class _VaultExplorerScreenState extends State<VaultExplorerScreen>
    with WindowListener{
  List<FileSystemEntity> _vaultContents = [];
  bool _isLoading = true;
  bool _isPaused = false;
  String? _vortexPath;
  StreamSubscription<WatchEvent>? _watcherSubscription;
  late Directory _currentVaultDir;
  late Directory _vaultRootDir;
  final TextEditingController _folderNameController = TextEditingController();

  // Instancias de los servicios
  final MetadataService _metadataService = MetadataService();
  final ThumbnailService _thumbnailService = ThumbnailService();

  // State for selection and clipboard
  Set<FileSystemEntity> _selectedItems = {};
  static List<FileSystemEntity> _clipboard = [];
  static bool _isCutOperation = false;

  // State for marquee selection
  final GlobalKey _gridDetectorKey = GlobalKey();
  Offset? _marqueeStart;
  Rect? _marqueeRect;
  final Map<int, GlobalKey> _itemKeys = {};

  // State for double tap logic
  Timer? _doubleTapTimer;
  FileSystemEntity? _lastTappedEntity;

  // State for Shift selection
  int? _shiftSelectionAnchorIndex;

  // State for custom context menu
  OverlayEntry? _contextMenuOverlay;

  // State for thumbnail size
  double _thumbnailExtent = 150.0;
  
  // Scroll controller
  final ScrollController _scrollController = ScrollController();

  bool _isSupportedFile(String filePath) {
  final ext = p.extension(filePath).toLowerCase();
  return _isImageFile(filePath) || ['.mp4', '.mov', '.avi', '.mkv'].contains(ext);
}


  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initializeAppServices();
  }

  void pause() {
    print("VaultExplorer pausado. Liberando recursos de UI...");
    setState(() {
      _isPaused = true;
      // Vaciamos las listas grandes para liberar RAM.
      _vaultContents.clear();
      _itemKeys.clear();
      _selectedItems.clear();
      // Le pedimos al servicio de miniaturas que limpie su caché de memoria RAM.
      _thumbnailService.clearMemoryCache();
      // NO cancelamos el _watcherSubscription, ya que debe seguir funcionando.
    });
  }

  void resume() {
    print("VaultExplorer reanudado. Recargando contenido...");
    setState(() {
      _isPaused = false; // <-- Desactivamos la pausa
    });
    // Volvemos a cargar las imágenes al abrir la ventana
    if (_vortexPath != null) {
      _loadVaultContents();
    }
  }

  void _initializeAppServices() async {
    await windowManager.setPreventClose(true);
    final supportDir = await getApplicationSupportDirectory();
    _vaultRootDir = Directory(p.join(supportDir.path, 'vault'));
    _currentVaultDir = widget.currentDirectory ?? _vaultRootDir;
    
    // Inicializa todos los servicios
    await _metadataService.initialize();
    await _thumbnailService.initialize();

    _initializeState();
    //_initTray();
  }

  /// Mueve una carpeta entera desde el Vórtice a la bóveda.
  Future<void> _absorbDirectory(Directory dir) async {
    final dirName = p.basename(dir.path);
    final newPathInVault = await _getUniquePath(_vaultRootDir, dirName);
    try {
      await dir.rename(newPathInVault);
    } catch (e) {
      debugPrint("Error al absorber la carpeta ${dir.path}: $e");
    }
  }

  /// Revisa recursivamente si una carpeta es válida para ser absorbida.
  Future<bool> _isDirectoryValidForAbsorption(Directory dir) async {
    final List<FileSystemEntity> contents = await dir.list().toList();

    if (contents.isEmpty) {
      return true;
    }

    for (final entity in contents) {
      if (entity is File) {
        if (!_isImageFile(entity.path)) {
          return false;
        }
      } else if (entity is Directory) {
        final isSubDirValid = await _isDirectoryValidForAbsorption(entity);
        if (!isSubDirValid) {
          return false;
        }
      }
    }
    return true;
  }

  /*Future<void> _initTray() async {
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png',
    );
    Menu menu = Menu(items: [
      MenuItem(key: 'show_window', label: 'Mostrar Aplicación'),
      MenuItem.separator(),
      MenuItem(key: 'exit_application', label: 'Cerrar Aplicación'),
    ]);
    await trayManager.setContextMenu(menu);
    await trayManager.setToolTip('Galería Vórtice');
  }*/

  @override
  void dispose() {
    windowManager.removeListener(this);
    _watcherSubscription?.cancel();
    _folderNameController.dispose();
    _doubleTapTimer?.cancel();
    _hideContextMenu();
    _scrollController.dispose();
    super.dispose();
  }

  // --- Window and Tray Listener Methods ---
  @override
  void onWindowClose() async { // <-- Convertir a async
    // --- LÓGICA MODIFICADA ---
    final prefs = await SharedPreferences.getInstance();
    final closeAction = prefs.getString(_closeActionKey) ?? CloseAction.minimize.name;

    if (closeAction == CloseAction.exit.name) {
      windowManager.destroy(); // Cierra la app
    } else {
      windowManager.hide(); // Minimiza a la bandeja
    }
    // --- FIN DE LA MODIFICACIÓN ---
  }

  /*@override
  void onTrayIconMouseDown() {
    windowManager.show();
    widget.setAuthenticated(false);
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show_window') {
      windowManager.show();
      widget.setAuthenticated(false);
    } else if (menuItem.key == 'exit_application') {
      windowManager.destroy();
    }
  }*/

  // --- Core Business Logic ---
  Future<void> _initializeState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedSize = prefs.getDouble(_thumbnailExtentKey) ?? 150.0;
    final path = prefs.getString(_vortexFolderPathKey);
    
    setState(() {
      _thumbnailExtent = savedSize;
    });

    if (path != null && path.isNotEmpty) {
      setState(() {
        _vortexPath = path;
      });
      await _absorbInitialVortexContents(Directory(path), reloadUI: false);
      _startWatcher(path);
    }

    await _loadVaultContents();
  }

  Future<void> _loadVaultContents({bool quiet = false}) async {
    // Solo mostramos el indicador si NO es una recarga silenciosa
    if (!quiet) {
      setState(() => _isLoading = true);
    }

    if (!await _currentVaultDir.exists()) {
      await _currentVaultDir.create(recursive: true);
    }
    final contents = await _currentVaultDir.list().toList();
    contents.sort((a, b) {
      if (a is Directory && b is File) return -1;
      if (a is File && b is Directory) return 1;
      return a.path.compareTo(b.path);
    });

    setState(() {
      _vaultContents = contents;
      _itemKeys.clear();
      _isLoading = false; // Siempre lo apagamos al terminar por seguridad
      _shiftSelectionAnchorIndex = null;
    });
    
    _thumbnailService.bulkGenerate(contents);
  }

  Future<bool> _waitUntilFileIsReady(File file) async {
    int lastSize = -1;
    int stableCount = 0;

    // Hacemos un bucle hasta que el archivo esté completamente listo.
    // Esto soporta descargas que pueden tardar horas.
    while (true) {
      try {
        if (!await file.exists()) {
          return false; // El archivo fue borrado o la descarga se canceló
        }

        int currentSize = await file.length();

        if (currentSize == lastSize && currentSize > 0) {
          stableCount++;
          // Exigimos 3 comprobaciones idénticas seguidas (1.5 segundos de estabilidad)
          if (stableCount >= 3) {
            // Verificación final: Intentamos abrir el archivo sin destruirlo.
            // Si Chrome/Windows aún lo está escribiendo, esto lanzará una excepción.
            RandomAccessFile? raf;
            try {
              raf = await file.open(mode: FileMode.append);
              await raf.close();
              return true; // ¡El archivo está 100% listo para ser movido!
            } catch (e) {
              stableCount = 0; // Aún tiene un candado de escritura, seguimos esperando
            }
          }
        } else {
          stableCount = 0; // El tamaño cambió, sigue copiándose
        }
        lastSize = currentSize;
      } catch (e) {
        // Ignoramos errores temporales si el archivo está fuertemente bloqueado
        stableCount = 0;
      }

      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  void _startWatcher(String path) {
    _watcherSubscription?.cancel();
    final watcher = DirectoryWatcher(path);
    
    _watcherSubscription = watcher.events.listen((event) async {
      // Cuando detectamos que "aparece" un archivo nuevo...
      if (event.type == ChangeType.ADD && _isSupportedFile(event.path)) {
        final file = File(event.path);
        
        // 1. Esperamos pacientemente a que termine de copiarse/descargarse
        final isReady = await _waitUntilFileIsReady(file);
        
        // 2. Solo cuando está listo (y si no cerramos la app mientras tanto), lo absorbemos
        if (isReady && mounted) {
          await _absorbImage(file);
        }
      }
    });
  }

  Future<String> _getUniquePath(
      Directory destinationDir, String fileName) async {
    String baseName = p.basenameWithoutExtension(fileName);
    String extension = p.extension(fileName);
    String newPath = p.join(destinationDir.path, fileName);
    int counter = 1;
    while (await File(newPath).exists() || await Directory(newPath).exists()) {
      fileName = '$baseName ($counter)$extension';
      newPath = p.join(destinationDir.path, fileName);
      counter++;
    }
    return newPath;
  }
  
  Future<void> _moveFileRobustly(File sourceFile, String newPath) async {
    try {
      await sourceFile.rename(newPath);
    } on FileSystemException {
      final newFile = await sourceFile.copy(newPath);
      if (await newFile.exists()) {
        await sourceFile.delete();
      }
    }
  }

  Future<void> _absorbImage(File imageFile, {bool reloadUI = true}) async {
    if (!await imageFile.exists()) return;
    
    final String originalFileName = p.basename(imageFile.path);
    final String baseName = p.basenameWithoutExtension(originalFileName);
    
    final bool meetsFormat = 
        int.tryParse(baseName) != null && baseName.length == 13;
    
    String newName;
    if (meetsFormat) {
      newName = originalFileName;
    } else {
      // Generamos el timestamp y mantenemos la extensión original
      final String extension = p.extension(imageFile.path);
      newName = '${DateTime.now().millisecondsSinceEpoch}$extension';
    }
    
    // Aplicamos nuestra ofuscación limpia: 12345.jpg -> 12345_jpg.vtx
    newName = _obfuscateName(newName);
    
    final newPathInVault = await _getUniquePath(_vaultRootDir, newName);

    try {
      await _moveFileRobustly(imageFile, newPathInVault);
      if (p.equals(_currentVaultDir.path, _vaultRootDir.path)) {
        // NUEVO: Solo recargamos la lista gráfica si NO estamos pausados
        if (reloadUI && !_isPaused) {
          await _loadVaultContents(quiet: true);
        }
      }
    } catch (e) {
      debugPrint("Error al absorber ${imageFile.path}: $e");
    }
  }
  
  Future<void> _absorbInitialVortexContents(Directory vortexDir, {bool reloadUI = true}) async {
    if (!await vortexDir.exists()) return;

    final contents = await vortexDir.list().toList();
    for (final entity in contents) {
      if (entity is File) {
        if (_isSupportedFile(entity.path)) {
          await _absorbImage(entity, reloadUI: false);
        }
      } else if (entity is Directory) {
        final bool isValid = await _isDirectoryValidForAbsorption(entity);
        if (isValid) {
          await _absorbDirectory(entity);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Carpeta "${p.basename(entity.path)}" ignorada: contiene archivos no válidos o está vacía.')),
            );
          }
        }
      }
    }

    if (reloadUI) {
      await _loadVaultContents();
    }
  }

  Future<void> _moveEntity(FileSystemEntity entity, Directory destination) async {
    try {
      final entityName = p.basename(entity.path);
      final newPath = await _getUniquePath(destination, entityName);
      
      // --- INICIO DE LA MODIFICACIÓN ---
      // Calculamos las rutas relativas (IDs) ANTES de mover el archivo
      final oldId = p.relative(entity.path, from: _vaultRootDir.path);
      final newId = p.relative(newPath, from: _vaultRootDir.path);

      if (entity is File) {
        await _moveFileRobustly(entity, newPath);
      } else {
        await entity.rename(newPath);
      }

      // Le avisamos a la base de datos que la ruta cambió para que mueva las etiquetas
      await _metadataService.updateImagePath(oldId, newId);
      // --- FIN DE LA MODIFICACIÓN ---

    } catch (e) {
      debugPrint("Error moving entity: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al mover el archivo: $e')),
        );
      }
    }
  }

  // --- User Interaction Handlers ---

  void _handleCut() {
    _hideContextMenu();
    if (_selectedItems.isEmpty) return;
    setState(() {
      _VaultExplorerScreenState._clipboard = _selectedItems.toList();
      _VaultExplorerScreenState._isCutOperation = true;
      _selectedItems.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              '${_VaultExplorerScreenState._clipboard.length} elemento(s) cortado(s).')),
    );
  }

  Future<void> _handlePaste() async {
    _hideContextMenu();
    if (_VaultExplorerScreenState._clipboard.isEmpty) return;
    
    for (final entity in _VaultExplorerScreenState._clipboard) {
      if (p.equals(p.dirname(entity.path), _currentVaultDir.path)) {
        continue;
      }
      await _moveEntity(entity, _currentVaultDir);
    }
    
    setState(() {
      _VaultExplorerScreenState._clipboard = [];
      _VaultExplorerScreenState._isCutOperation = false;
    });
    
    await _loadVaultContents(quiet: true);
  }

  void _showContextMenu(BuildContext context, Offset position) {
    _hideContextMenu();
    final screenSize = MediaQuery.of(context).size;
    const estimatedMenuWidth = 150.0;
    const estimatedMenuHeight = 200.0; 

    double? top, bottom, left, right;

    if (position.dy + estimatedMenuHeight > screenSize.height) {
      bottom = screenSize.height - position.dy;
    } else {
      top = position.dy;
    }

    if (position.dx + estimatedMenuWidth > screenSize.width) {
      right = screenSize.width - position.dx;
    } else {
      left = position.dx;
    }

    final hasImageSelected = _selectedItems.any((item) => item is File);
    
    final items = <Widget>[
      if (_selectedItems.isNotEmpty)
        _ContextMenuItemWidget(
            title: 'Mover',
            onTap: _handleCut,
            icon: Icons.drive_file_move_outline),
      if (_VaultExplorerScreenState._clipboard.isNotEmpty)
        _ContextMenuItemWidget(
            title: 'Pegar',
            onTap: _handlePaste,
            icon: Icons.content_paste_go),
      
      if (hasImageSelected)
        _ContextMenuItemWidget(
          title: 'Etiquetas',
          onTap: () {
            _hideContextMenu();
            final selectedImageIds = _selectedItems.whereType<File>().map((f) => p.relative(f.path, from: _vaultRootDir.path)).toList();

            showDialog(
              context: context,
              builder: (context) => TagEditorDialog(
                imageIds: selectedImageIds,
                metadataService: _metadataService,
              ),
            );
          },
          icon: Icons.label_outline,
        ),
      
      if (hasImageSelected)
        _ContextMenuItemWidget(
          title: 'Calificación',
          onTap: () {
            _hideContextMenu();
            _showRatingMenu(context, position);
          },
          icon: Icons.star_outline,
        ),
      
      if (_selectedItems.isNotEmpty) const Divider(height: 1, thickness: 1),
      if (_selectedItems.isNotEmpty)
        _ContextMenuItemWidget(
            title: 'Exportar',
            onTap: _handleExport,
            icon: Icons.download_for_offline_outlined),
      if (_selectedItems.isNotEmpty)
        _ContextMenuItemWidget(
            title: 'Eliminar',
            onTap: _handleDelete,
            icon: Icons.delete_forever_outlined,
            isDestructive: true),
    ];

    if (items.whereType<_ContextMenuItemWidget>().isEmpty && _VaultExplorerScreenState._clipboard.isEmpty && !hasImageSelected) return;

    _contextMenuOverlay = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  _hideContextMenu();
                  setState(() => _selectedItems.clear());
                },
                onSecondaryTap: () {
                   _hideContextMenu();
                   setState(() => _selectedItems.clear());
                },
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              top: top,
              bottom: bottom,
              left: left,
              right: right,
              child: Material(
                elevation: 4.0,
                color: const Color(0xFF424242),
                borderRadius: BorderRadius.circular(8.0),
                child: IntrinsicWidth(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: items,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    Overlay.of(context).insert(_contextMenuOverlay!);
  }
  
  void _showRatingMenu(BuildContext context, Offset position) {
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  
    showMenu(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: List.generate(6, (index) {
        return PopupMenuItem(
          value: index,
          child: Row(
            children: [
              if (index == 0)
                const Text("Sin calificar")
              else
                RatingStarsDisplay(rating: index, iconSize: 20),
            ],
          ),
        );
      }),
    ).then((newRating) {
  if (newRating != null) {
    for (final entity in _selectedItems.whereType<File>()) {
      final imageId = p.relative(entity.path, from: _vaultRootDir.path); // <-- Usamos el ID
      _metadataService.setRatingForImage(imageId, newRating);
    }
    setState(() {});
  }
});
  }

  void _hideContextMenu() {
    if (_contextMenuOverlay != null) {
      _contextMenuOverlay!.remove();
      _contextMenuOverlay = null;
    }
  }
  
  void _showFullScreenViewer(List<File> imageFiles, int initialIndex) {
    _hideContextMenu();
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FullScreenImageViewer(
          imageFiles: imageFiles,
          initialIndex: initialIndex,
          exportCallback: (file) async => await _handleSingleExport(file),
          onClose: () => Navigator.pop(context), // Cierra la pantalla de forma nativa
          metadataService: _metadataService,
          vaultRootPath: _vaultRootDir.path,
        ),
      ),
    );
  }

  void _onItemTap(FileSystemEntity entity, {bool isDoubleClick = false}) {
    if (isDoubleClick) {
      if (entity is Directory) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VaultExplorerScreen(
              currentDirectory: entity,
              setAuthenticated: widget.setAuthenticated,
            ),
          ),
        ).then((_) => _loadVaultContents());
      } else if (entity is File) {
        final imageFiles = _vaultContents.whereType<File>().toList();
        int initialIndex = imageFiles.indexWhere((f) => p.equals(f.path, entity.path));
        if (initialIndex == -1) {
          initialIndex = 0; 
        }
        if (imageFiles.isNotEmpty) {
          _showFullScreenViewer(imageFiles, initialIndex);
        }
      }
    }
  }

  void _handleItemTap(FileSystemEntity entity, int index) {
    _hideContextMenu();

    final isShiftPressed = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftLeft) ||
        RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftRight);

    final isCtrlPressed = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlLeft) ||
        RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.controlRight) ||
        (Platform.isMacOS &&
            (RawKeyboard.instance.keysPressed
                    .contains(LogicalKeyboardKey.metaLeft) ||
                RawKeyboard.instance.keysPressed
                    .contains(LogicalKeyboardKey.metaRight)));

    setState(() {
      if (isShiftPressed) {
        if (_shiftSelectionAnchorIndex == null) {
          _shiftSelectionAnchorIndex = index;
          _selectedItems = {entity};
        } else {
          final start =
              index < _shiftSelectionAnchorIndex! ? index : _shiftSelectionAnchorIndex!;
          final end =
              index > _shiftSelectionAnchorIndex! ? index : _shiftSelectionAnchorIndex!;
          _selectedItems =
              _vaultContents.sublist(start, end + 1).toSet();
        }
      } else if (isCtrlPressed) {
        if (_selectedItems.contains(entity)) {
          _selectedItems.remove(entity);
        } else {
          _selectedItems.add(entity);
        }
        _shiftSelectionAnchorIndex = index;
      } else {
        if (_doubleTapTimer != null &&
            _doubleTapTimer!.isActive &&
            _lastTappedEntity == entity) {
          _doubleTapTimer!.cancel();
          _lastTappedEntity = null;
          _onItemTap(entity, isDoubleClick: true);
        } else {
          _selectedItems = {entity};
          _shiftSelectionAnchorIndex = index; 

          _lastTappedEntity = entity;
          _doubleTapTimer?.cancel();
          _doubleTapTimer = Timer(kDoubleTapTimeout, () {
            _lastTappedEntity = null;
          });
        }
      }
    });
  }


  // --- Marquee Selection Handlers ---
  void _onMarqueeStart(DragStartDetails details) {
    _hideContextMenu();
    _marqueeStart = details.localPosition;
    _marqueeRect = null;
    setState(() => _selectedItems.clear());
  }

  void _onMarqueeUpdate(DragUpdateDetails details) {
    if (_marqueeStart == null) return;

    final RenderBox? gridDetectorBox =
        _gridDetectorKey.currentContext?.findRenderObject() as RenderBox?;
    if (gridDetectorBox == null || !gridDetectorBox.hasSize) return;

    setState(() {
      _marqueeRect = Rect.fromPoints(_marqueeStart!, details.localPosition);
      final tempSelection = <FileSystemEntity>{};

      for (int i = 0; i < _vaultContents.length; i++) {
        final key = _itemKeys[i];
        if (key?.currentContext != null) {
          final itemBox = key!.currentContext!.findRenderObject() as RenderBox;

          final topLeftGlobal = itemBox.localToGlobal(Offset.zero);
          final topLeftLocal = gridDetectorBox.globalToLocal(topLeftGlobal);

          final itemRect = Rect.fromLTWH(topLeftLocal.dx, topLeftLocal.dy,
              itemBox.size.width, itemBox.size.height);

          if (_marqueeRect!.overlaps(itemRect)) {
            tempSelection.add(_vaultContents[i]);
          }
        }
      }
      _selectedItems = tempSelection;
    });
  }

  void _onMarqueeEnd(DragEndDetails details) {
    setState(() {
      _marqueeStart = null;
      _marqueeRect = null;
    });
  }

  // --- Dialogs and Other UI Helpers ---
  Future<void> _selectVortexFolder() async {
    bool confirm = await _showConfirmationDialog(
          title: 'Seleccionar Carpeta Vórtice',
          content:
              'Las imágenes que ya están en esta carpeta y las que muevas en el futuro serán MOVIDAS a la raíz de la bóveda privada.\n\n¿Deseas continuar?',
        ) ??
        false;
    if (!confirm) return;

    try {
      String? directoryPath = await FilePicker.platform.getDirectoryPath();
      if (directoryPath != null) {
        setState(() => _isLoading = true);
        final directory = Directory(directoryPath);
        
        await _absorbInitialVortexContents(directory, reloadUI: false);

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_vortexFolderPathKey, directoryPath);
        await _loadVaultContents();
        setState(() {
          _vortexPath = directoryPath;
        });
        _startWatcher(directoryPath);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al procesar la carpeta: $e')),
        );
      }
    }
  }

  Future<void> _clearVortexPathSetting() async {
    await _watcherSubscription?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_vortexFolderPathKey);
    setState(() {
      _vortexPath = null;
    });
  }

  bool _isImageFile(String filePath) {
    final lowercasedPath = filePath.toLowerCase();
    return lowercasedPath.endsWith('.jpg') ||
        lowercasedPath.endsWith('.jpeg') ||
        lowercasedPath.endsWith('.png') ||
        lowercasedPath.endsWith('.gif') ||
        lowercasedPath.endsWith('.bmp') ||
        lowercasedPath.endsWith('.webp');
  }

  

  Future<bool?> _showConfirmationDialog(
      {required String title, required String content}) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Aceptar')),
        ],
      ),
    );
  }

  Future<void> _showCreateFolderDialog() async {
    _folderNameController.clear();
    return showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Crear Nueva Carpeta'),
            content: TextField(
              controller: _folderNameController,
              autofocus: true,
              decoration:
                  const InputDecoration(hintText: "Nombre de la carpeta"),
            ),
            actions: [
              TextButton(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.of(context).pop(),
              ),
              TextButton(
                child: const Text('Crear'),
                onPressed: () async {
                  if (_folderNameController.text.isNotEmpty) {
                    final newDir = Directory(p.join(
                        _currentVaultDir.path, _folderNameController.text));
                    if (!await newDir.exists()) {
                      await newDir.create();
                      if (mounted) Navigator.of(context).pop();
                      await _loadVaultContents(quiet: true);
                    }
                  }
                },
              ),
            ],
          );
        });
  }

  // --- Build Methods ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _isLoading ? const Text("Cargando...") : _buildBreadcrumbs(),
        titleSpacing: 0,
        backgroundColor: Colors.black26,
        actions: [
          if (!_isLoading && _vortexPath != null)
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: 'Crear carpeta',
              onPressed: _showCreateFolderDialog,
            ),
          if (!_isLoading &&
              _vortexPath != null &&
              widget.currentDirectory == null)
            IconButton(
              icon: const Icon(Icons.restore_from_trash),
              tooltip: 'Restaurar todo y olvidar carpeta',
              onPressed: _restoreAllAndClear,
            ),
            IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Ajustes',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _vortexPath == null
                    ? _buildEmptyState(
                        icon: Icons.all_inclusive,
                        title: 'No has seleccionado una carpeta Vórtice.',
                        subtitle:
                            'Usa el botón para elegir una carpeta y empezar a vigilarla.',
                      )
                    : _buildFileExplorerBody(),
          ),
          if (_vortexPath != null && !_isLoading) _buildThumbnailSlider(),
        ],
      ),
      floatingActionButton: widget.currentDirectory == null
          ? FloatingActionButton.extended(
              onPressed: _selectVortexFolder,
              label: Text(_vortexPath == null
                  ? 'Seleccionar Vórtice'
                  : 'Cambiar Vórtice'),
              icon: const Icon(Icons.all_inclusive),
            )
          : null,
    );
  }
  
  Widget _buildThumbnailSlider(){
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        children: [
          const Icon(Icons.photo_size_select_small),
          SizedBox(
            width: 300,
            child: Slider(
              value: _thumbnailExtent,
              min: 100,
              max: 250,
              divisions: 15,
              label: '${_thumbnailExtent.toInt()}px',
              onChanged: (value) async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setDouble(_thumbnailExtentKey, value);
                setState(() {
                  _thumbnailExtent = value;
                });
              },
            ),
          ),
          const Icon(Icons.photo_size_select_large),
        ],
      ),
    );
  }

  Widget _buildFileExplorerBody() {
    return _vaultContents.isEmpty
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _hideContextMenu();
              setState(() {
                _selectedItems.clear();
                _shiftSelectionAnchorIndex = null;
              });
            },
            onSecondaryTapUp: (details) {
              _hideContextMenu();
              setState(() => _selectedItems.clear());
              _showContextMenu(context, details.globalPosition);
            },
            child: SizedBox.expand(
              child: _buildEmptyState(
                icon: Icons.shield_outlined,
                title: 'La carpeta está vacía.',
                subtitle: _VaultExplorerScreenState._clipboard.isNotEmpty
                    ? 'Haz clic derecho para pegar elementos.'
                    : 'Mueve imágenes a tu carpeta Vórtice o crea nuevas carpetas.',
              ),
            ),
          )
        : Stack(
            children: [
              GestureDetector(
                onTap: () {
                  setState(() {
                    _selectedItems.clear();
                    _shiftSelectionAnchorIndex = null;
                  });
                },
                onSecondaryTapUp: (details) {
                  _hideContextMenu();
                  setState(() => _selectedItems.clear());
                  _showContextMenu(context, details.globalPosition);
                },
                onPanStart: _onMarqueeStart,
                onPanUpdate: _onMarqueeUpdate,
                onPanEnd: _onMarqueeEnd,
                behavior: HitTestBehavior.translucent,
                child: _buildFileExplorerGrid(),
              ),
              if (_marqueeRect != null)
                Positioned.fromRect(
                  rect: _marqueeRect!,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: Colors.deepPurpleAccent, width: 1),
                      color: Colors.deepPurpleAccent.withOpacity(0.2),
                    ),
                  ),
                ),
            ],
          );
  }

  Widget _buildBreadcrumbs() {
    String relativePath =
        p.relative(_currentVaultDir.path, from: _vaultRootDir.path);
    List<String> pathParts =
        relativePath == '.' ? [] : relativePath.split(p.separator);

    List<Widget> breadcrumbWidgets = [
      InkWell(
        onTap: () {
          if (widget.currentDirectory != null) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8.0),
          child: Icon(Icons.home, size: 20),
        ),
      )
    ];

    for (int i = 0; i < pathParts.length; i++) {
      breadcrumbWidgets.add(
          const Icon(Icons.chevron_right, size: 16, color: Colors.white54));
      breadcrumbWidgets.add(
        InkWell(
          onTap: () {
            if (i < pathParts.length - 1) {
              int popCount = (pathParts.length - 1) - i;
              for (int j = 0; j < popCount; j++) {
                Navigator.of(context).pop();
              }
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: Text(pathParts[i], style: const TextStyle(fontSize: 16)),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: breadcrumbWidgets,
      ),
    );
  }

  Widget _buildEmptyState(
      {required IconData icon,
      required String title,
      required String subtitle}) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 80, color: Colors.white54),
        const SizedBox(height: 16),
        Text(title,
            style: const TextStyle(fontSize: 18), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(subtitle,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center),
        ),
      ],
    );
  }

  Widget _buildFileExplorerGrid() {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: GridView.builder(
        key: _gridDetectorKey,
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: _thumbnailExtent,
          mainAxisSpacing: 8.0,
          crossAxisSpacing: 8.0,
        ),
        itemCount: _vaultContents.length,
        itemBuilder: (context, index) {
          final entity = _vaultContents[index];
          _itemKeys.putIfAbsent(index, () => GlobalKey());
          return KeyedSubtree(
            key: _itemKeys[index],
            child: _buildDraggableItem(entity, index),
          );
        },
      ),
    );
  }

  Widget _buildDraggableItem(FileSystemEntity entity, int index) {
    List<FileSystemEntity> draggedItems = [];
    if (_selectedItems.contains(entity)) {
      draggedItems = _selectedItems.toList();
    } else {
      draggedItems = [entity];
    }

    return Draggable<List<FileSystemEntity>>(
      data: draggedItems,
      feedback: _buildDragFeedback(draggedItems),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      childWhenDragging: Opacity(
        opacity: 0.4,
        child: entity is Directory
            ? _buildFolderItem(entity, index)
            : _buildImageItem(entity as File, index),
      ),
      child: entity is Directory
          ? _buildFolderItem(entity, index)
          : _buildImageItem(entity as File, index),
    );
  }

  Widget _buildDragFeedback(List<FileSystemEntity> items) {
    final firstItem = items.first;
    
    // 1. Determinamos qué mostrar en la vista previa del arrastre
    Widget previewWidget;
    if (firstItem is File) {
      final ext = p.extension(firstItem.path).toLowerCase();
      final isVideo = ['.mp4', '.mov', '.avi', '.mkv'].contains(ext);
      
      if (isVideo) {
        // Si es video, mostramos un ícono representativo
        previewWidget = Container(
          color: Colors.grey.shade900,
          child: const Center(
            child: Icon(Icons.movie_creation_outlined, size: 50, color: Colors.white70),
          ),
        );
      } else {
        // Si es imagen, la dibujamos
        previewWidget = Image.file(firstItem, fit: BoxFit.cover);
      }
    } else {
      // Si es carpeta
      previewWidget = const Icon(Icons.folder, size: 100, color: Colors.amber);
    }

    return Material(
      color: Colors.transparent,
      child: Transform.translate(
        offset: const Offset(-50, -50),
        child: Stack(
          children: [
            SizedBox(
              width: 100,
              height: 100,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8.0),
                child: previewWidget,
              ),
            ),
            if (items.length > 1)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.deepPurple,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    items.length.toString(),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderItem(Directory directory, int index) {
    final isSelected = _selectedItems.contains(directory);
    return DragTarget<List<FileSystemEntity>>(
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        return GestureDetector(
          onTap: () => _handleItemTap(directory, index),
          onSecondaryTapUp: (details) {
            _hideContextMenu();
            if (!_selectedItems.contains(directory)) {
              setState(() => _selectedItems = {directory});
            }
            _showContextMenu(context, details.globalPosition);
          },
          child: Container(
            decoration: BoxDecoration(
              color: isHovered
                  ? Colors.deepPurple.withOpacity(0.6)
                  : isSelected
                      ? Colors.deepPurple.withOpacity(0.4)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(8.0),
              border: Border.all(
                color: isHovered || isSelected
                    ? Colors.deepPurpleAccent
                    : Colors.transparent,
                width: 2,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder, size: _thumbnailExtent * 0.4, color: Colors.amber),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: Text(
                    p.basename(directory.path),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
              ],
            ),
          ),
        );
      },
      onWillAccept: (data) {
        if (data == null) return false;
        for (final entity in data) {
          if (entity.path == directory.path ||
              (entity is Directory &&
                  p.isWithin(directory.path, entity.path))) {
            return false;
          }
        }
        return true;
      },
      onAccept: (data) async {
        for (final entity in data) {
          await _moveEntity(entity, directory);
        }
        setState(() => _selectedItems.clear());
        await _loadVaultContents(quiet: true);
    },
    );
  }

  Widget _buildImageItem(File imageFile, int index) {
    final isSelected = _selectedItems.contains(imageFile);

    // NUEVO: Calculamos la ruta relativa para usarla como ID único
    final imageId = p.relative(imageFile.path, from: _vaultRootDir.path);

    // Simplemente devolvemos nuestro nuevo widget y le pasamos los datos necesarios
    return ImageItemWidget(
      imageFile: imageFile,
      imageId: imageId, // <-- AQUÍ ESTÁ EL PARÁMETRO QUE FALTABA
      isSelected: isSelected,
      extent: _thumbnailExtent,
      metadataService: _metadataService,
      thumbnailService: _thumbnailService,
      onTap: () => _handleItemTap(imageFile, index),
      onSecondaryTapUp: (details) {
        _hideContextMenu();
        if (!_selectedItems.contains(imageFile)) {
          setState(() => _selectedItems = {imageFile});
        }
        _showContextMenu(context, details.globalPosition);
      },
    );
  }

  Future<void> _handleDelete() async {
    _hideContextMenu();
    if (_selectedItems.isEmpty) return;
    final count = _selectedItems.length;
    final itemText =
        count == 1 ? 'el elemento seleccionado' : 'los $count elementos seleccionados';
    bool confirm = await _showConfirmationDialog(
          title: 'Confirmar Eliminación',
          content:
              '¿Estás seguro de que quieres eliminar $itemText permanentemente? Esta acción no se puede deshacer.',
        ) ??
        false;
    if (!confirm) {
      setState(() => _selectedItems.clear());
      return;
    }

    for (final entity in _selectedItems) {
      if (entity.existsSync()) {
        
        // NUEVO: Borramos su rastro en la base de datos
        final idToDelete = p.relative(entity.path, from: _vaultRootDir.path);
        await _metadataService.deleteMetadata(idToDelete);

        if (entity is File) {
          await _thumbnailService.clearThumbnail(p.basename(entity.path));
          await entity.delete();
        } else if (entity is Directory) {
          await entity.delete(recursive: true);
        }
      }
    }
    
    setState(() {
      _selectedItems.clear();
    });
    await _loadVaultContents(quiet: true);
  }

  Future<void> _handleExport() async {
    _hideContextMenu();
    if (_selectedItems.isEmpty) return;

    // 1. Abrimos el selector de carpetas de Windows
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Seleccionar carpeta de exportación',
    );

    // Si el usuario cierra la ventana sin elegir nada, cancelamos
    if (selectedDirectory == null) return;

    final exportRootDir = Directory(selectedDirectory);

    for (final entity in _selectedItems) {
      if (entity is File) {
        // 2. Le quitamos el cifrado al nombre (Ej: foto0nq4.vtx -> foto.mp4)
        final cleanName = _getDeobfuscatedName(p.basename(entity.path));
        
        // 3. Nos aseguramos de no sobrescribir nada si ya existe un archivo igual
        final newPath = await _getUniquePath(exportRootDir, cleanName);
        await entity.copy(newPath);
      } else if (entity is Directory) {
        // Si es una carpeta, delegamos la copia a la función recursiva
        final newDirPath = await _getUniquePath(exportRootDir, p.basename(entity.path));
        await _copyDirectory(entity, Directory(newDirPath));
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('${_selectedItems.length} elemento(s) exportado(s) con éxito a ${exportRootDir.path}.')));
    }
    setState(() => _selectedItems.clear());
  }

  Future<void> _handleSingleExport(File file) async {
    // Abrimos el selector de carpetas
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Seleccionar carpeta de exportación',
    );

    if (selectedDirectory == null) return;

    final exportRootDir = Directory(selectedDirectory);
    
    // Usamos las funciones de descifrado que ya tienes para limpiar el nombre
    final cleanName = _getDeobfuscatedName(p.basename(file.path));
    final newPath = await _getUniquePath(exportRootDir, cleanName);

    try {
      await file.copy(newPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Archivo exportado con éxito a ${exportRootDir.path}.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Error al exportar: $e')));
      }
    }
  }

  Future<void> _restoreAllAndClear() async {
    bool confirm = await _showConfirmationDialog(
          title: 'Restaurar Todo',
          content:
              '¿Deseas mover TODAS las imágenes y carpetas de vuelta a la carpeta Vórtice? La app olvidará la carpeta después de esto.',
        ) ??
        false;
    if (!confirm || !mounted || _vortexPath == null) return;
    
    setState(() => _isLoading = true);
    
    await _watcherSubscription?.cancel();
    _watcherSubscription = null;

    final vortexDir = Directory(_vortexPath!);
    await _restoreDirectoryContents(_vaultRootDir, vortexDir);
    
    await _clearVortexPathSetting();
    await _loadVaultContents();
    
    setState(() => _isLoading = false);
     if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Todos los archivos han sido restaurados.')),
      );
    }
  }

  Future<void> _restoreDirectoryContents(Directory source, Directory destination) async {
    final List<FileSystemEntity> contents = await source.list().toList();

    for (final entity in contents) {
      try {
        if (entity is File) {
          final newPath = await _getUniquePath(destination, p.basename(entity.path));
          await _moveFileRobustly(entity, newPath);
        } else if (entity is Directory) {
          final newDestDir = Directory(await _getUniquePath(destination, p.basename(entity.path)));
          await newDestDir.create();
          await _restoreDirectoryContents(entity, newDestDir);
          
          await entity.delete(recursive: true);
        }
      } catch (e) {
        debugPrint("Error restaurando '${entity.path}': $e");
      }
    }
  }


  Future<void> _handleSingleRestore(File imageFile) async {
    if (!await imageFile.exists() || _vortexPath == null) return;

    final vortexDir = Directory(_vortexPath!);
    final fileName = p.basename(imageFile.path);
    final newPath = await _getUniquePath(vortexDir, fileName);

    try {
      await _moveFileRobustly(imageFile, newPath);
       if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Imagen restaurada con éxito.')),
        );
      }
    } catch (e) {
      debugPrint("Error al restaurar ${imageFile.path}: $e");
    }
  }


  Future<Directory?> _getPicturesDirectory() async {
    Directory? picturesDir;
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) {
        picturesDir = Directory(p.join(userProfile, 'Pictures'));
      }
    } else if (Platform.isLinux || Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null) {
        picturesDir = Directory(p.join(home, 'Pictures'));
      }
    }
    return picturesDir ?? await getDownloadsDirectory();
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final entity in source.list()) {
      if (entity is File) {
        // Desencriptamos los archivos que están dentro de las carpetas
        final cleanName = _getDeobfuscatedName(p.basename(entity.path));
        final newPath = await _getUniquePath(destination, cleanName);
        await entity.copy(newPath);
      } else if (entity is Directory) {
        // Las carpetas no están cifradas, mantienen su nombre normal
        final newPath = p.join(destination.path, p.basename(entity.path));
        await _copyDirectory(entity, Directory(newPath));
      }
    }
  }
  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SettingsScreen()),
    );
  }
}

class _ContextMenuItemWidget extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final bool isDestructive;

  const _ContextMenuItemWidget({
    required this.title,
    required this.icon,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? Colors.redAccent : null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Text(title, style: TextStyle(color: color)),
          ],
        ),
      ),
    );
  }
}

class ImageItemWidget extends StatefulWidget {
  final File imageFile;
  final String imageId;
  final bool isSelected;
  final double extent;
  final VoidCallback onTap;
  final GestureTapUpCallback onSecondaryTapUp;
  final MetadataService metadataService;
  final ThumbnailService thumbnailService;

  const ImageItemWidget({
    super.key,
    required this.imageFile,
    required this.imageId,
    required this.isSelected,
    required this.extent,
    required this.onTap,
    required this.onSecondaryTapUp,
    required this.metadataService,
    required this.thumbnailService,
  });

  @override
  State<ImageItemWidget> createState() => _ImageItemWidgetState();
}

class _ImageItemWidgetState extends State<ImageItemWidget> {
  File? _thumbFile; // Guardará el resultado de la carga
  
  @override
  void initState() {
    super.initState();
    // Cargamos la miniatura UNA SOLA VEZ cuando el widget se crea
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    // Obtenemos la miniatura y actualizamos el estado de ESTE widget
    final thumb = await widget.thumbnailService.getThumbnail(widget.imageFile);
    if (mounted) { // Nos aseguramos que el widget todavía existe
      setState(() {
        _thumbFile = thumb;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rating = widget.metadataService.getMetadataForImage(widget.imageId).rating;
    
    // 1. AHORA SÍ usamos la función que descifra el .vtx para saber si es video
    final bool isVideo = _isVideo(widget.imageFile.path);

    return GestureDetector(
      onTap: widget.onTap,
      onSecondaryTapUp: widget.onSecondaryTapUp,
      child: Hero(
        tag: widget.imageFile.path,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8.0),
            border: Border.all(
              color: widget.isSelected ? Colors.deepPurpleAccent : Colors.transparent,
              width: 2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6.0),
            child: _thumbFile == null
                ? Container(
                    color: Colors.grey.shade800,
                    child: const Center(
                      child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.0)),
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        _thumbFile!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            color: Colors.grey.shade900,
                            child: const Center(
                              child: Icon(Icons.broken_image, color: Colors.white54, size: 40),
                            ),
                          );
                        },
                        gaplessPlayback: true,
                      ),
                      
                      // 2. CAPA DEL BOTÓN DE PLAY (Solo si es video)
                      if (isVideo) ...[
                        Container(color: Colors.black26), // Oscurece un poco la miniatura
                        const Center(
                          child: Icon(
                            Icons.play_circle_fill,
                            color: Colors.white, 
                            size: 48,
                          ),
                        ),
                      ],

                      // 3. Sombreado inferior
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: widget.extent * 0.35,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                Colors.black.withOpacity(0.8),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                      
                      // 4. Estrellas
                      if (rating > 0)
                        Positioned(
                          bottom: 4,
                          right: 4,
                          child: RatingStarsDisplay(
                            rating: rating,
                            iconSize: widget.extent / 10,
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class FullScreenImageViewer extends StatefulWidget {
  final List<File> imageFiles;
  final int initialIndex;
  final Future<void> Function(File file) exportCallback;
  final VoidCallback onClose;
  final MetadataService metadataService;
  final String vaultRootPath;

  const FullScreenImageViewer({
    super.key,
    required this.imageFiles,
    required this.initialIndex,
    required this.exportCallback,
    required this.onClose,
    required this.metadataService,
    required this.vaultRootPath,
  });

  @override
  State<FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<FullScreenImageViewer> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  Future<void> _exportCurrentImage() async {
    final currentFile = widget.imageFiles[_currentIndex];
    await widget.exportCallback(currentFile);
    widget.onClose();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentFile = widget.imageFiles[_currentIndex];
    // Calculamos el ID relativo para poder consultar la base de datos
    final imageId = p.relative(currentFile.path, from: widget.vaultRootPath);
    final currentRating = widget.metadataService.getMetadataForImage(imageId).rating;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: widget.onClose,
        ),
        actions: [
          // 1. Botón de Etiquetas
          IconButton(
            icon: const Icon(Icons.label_outline, color: Colors.white),
            tooltip: 'Etiquetas',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => TagEditorDialog(
                  imageIds: [imageId],
                  metadataService: widget.metadataService,
                ),
              ).then((_) => setState(() {})); // Refresca la vista si cambian las etiquetas
            },
          ),
          
          // 2. Menú de Calificación (Estrellas)
          PopupMenuButton<int>(
            icon: currentRating > 0 
                ? const Icon(Icons.star, color: Colors.amber)
                : const Icon(Icons.star_outline, color: Colors.white),
            tooltip: 'Calificación',
            color: const Color(0xFF424242),
            itemBuilder: (context) => List.generate(6, (index) {
              return PopupMenuItem(
                value: index,
                child: Row(
                  children: [
                    if (index == 0)
                      const Text("Sin calificar", style: TextStyle(color: Colors.white))
                    else
                      RatingStarsDisplay(rating: index, iconSize: 20),
                  ],
                ),
              );
            }),
            onSelected: (newRating) {
              widget.metadataService.setRatingForImage(imageId, newRating);
              setState(() {}); // Actualiza el icono de estrella
            },
          ),

          // 3. Botón de Exportar
          IconButton(
            icon: const Icon(Icons.download_for_offline_outlined, color: Colors.white),
            tooltip: 'Exportar',
            onPressed: _exportCurrentImage,
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: widget.imageFiles.length,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            itemBuilder: (context, index) {
              final imageFile = widget.imageFiles[index];
              
              final bool isVideo = _isVideo(imageFile.path);
              if (isVideo) {
                // Retornamos el video SIN Hero para evitar el congelamiento
                return VideoViewerWidget(videoFile: imageFile);
              }
              return Hero(
                tag: imageFile.path,
                child: InteractiveViewer(
                  panEnabled: false,
                  minScale: 1.0,
                  maxScale: 4.0,
                  child: Image.file(
                    imageFile,
                    fit: BoxFit.contain,
                  ),
                ),
              );
            },
          ),
          if (_currentIndex > 0)
            Positioned(
              left: 10,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new,
                      color: Colors.white),
                  onPressed: () {
                    _pageController.previousPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  },
                ),
              ),
            ),
          if (_currentIndex < widget.imageFiles.length - 1)
            Positioned(
              right: 10,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon:
                      const Icon(Icons.arrow_forward_ios, color: Colors.white),
                  onPressed: () {
                    _pageController.nextPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

enum _AuthState { checking, setup, setupConfirm, login }

class PinAuthScreen extends StatefulWidget {
  final VoidCallback onAuthenticated;
  final Function(bool) setAuthenticated;

  const PinAuthScreen({
    super.key,
    required this.onAuthenticated,
    required this.setAuthenticated,
  });

  @override
  State<PinAuthScreen> createState() => _PinAuthScreenState();
}

class _PinAuthScreenState extends State<PinAuthScreen> with WindowListener {
  _AuthState _currentState = _AuthState.checking;
  final _pinController = TextEditingController();
  String _tempPin = '';
  String? _errorMessage;
  int _pinLength = 0;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _checkPinStatus();

    _pinController.addListener(() {
      setState(() {});
    });
  }

  @override
  void onWindowClose() async { // <-- Convertir a async
    // --- LÓGICA MODIFICADA ---
    final prefs = await SharedPreferences.getInstance();
    final closeAction = prefs.getString(_closeActionKey) ?? CloseAction.minimize.name;
    
    if (closeAction == CloseAction.exit.name) {
      windowManager.destroy(); // Cierra la app
    } else {
      windowManager.hide(); // Minimiza a la bandeja
      widget.setAuthenticated(true); // Mantiene el comportamiento original de saltar el auth si se minimiza
    }
    // --- FIN DE LA MODIFICACIÓN ---
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _checkPinStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPin = prefs.getString(_masterPinKey);
    if (savedPin != null && savedPin.isNotEmpty) {
      setState(() {
        _pinLength = savedPin.length;
        _currentState = _AuthState.login;
      });
    } else {
      setState(() => _currentState = _AuthState.setup);
    }
  }

  void _onPinSubmitted() async {
    final enteredPin = _pinController.text;

    if (_currentState == _AuthState.setup && (enteredPin.length < 4 || enteredPin.length > 8)) {
      setState(() => _errorMessage = 'El PIN debe tener entre 4 y 8 dígitos.');
      return;
    }
    setState(() => _errorMessage = null);

    switch (_currentState) {
      case _AuthState.setup:
        _tempPin = enteredPin;
        setState(() {
          _pinLength = _tempPin.length;
          _currentState = _AuthState.setupConfirm;
        });
        _pinController.clear();
        break;
      case _AuthState.setupConfirm:
        if (enteredPin == _tempPin) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_masterPinKey, enteredPin);
          widget.onAuthenticated();
        } else {
          setState(() {
            _errorMessage = 'Los PIN no coinciden. Vuelve a crearlo.';
            _currentState = _AuthState.setup;
          });
          _pinController.clear();
        }
        break;
      case _AuthState.login:
        final prefs = await SharedPreferences.getInstance();
        final savedPin = prefs.getString(_masterPinKey);
        if (savedPin == enteredPin) {
          widget.onAuthenticated();
        } else {
          setState(() => _errorMessage = 'PIN incorrecto.');
          _pinController.clear();
        }
        break;
      case _AuthState.checking:
        break;
    }
  }

  String _getTitle() {
    switch (_currentState) {
      case _AuthState.checking:
        return 'Verificando...';
      case _AuthState.setup:
        return 'Crea tu PIN Maestro';
      case _AuthState.setupConfirm:
        return 'Confirma tu PIN';
      case _AuthState.login:
        return 'Ingresa tu PIN';
    }
  }
  
  Widget _buildPinInputArea() {
    return SizedBox(
      width: (_pinLength * 56).toDouble(),
      height: 50,
      child: Stack(
        alignment: Alignment.center,
        children: [
          PinInputBoxes(
            pinLength: _pinLength,
            enteredPin: _pinController.text,
          ),
          TextField(
            controller: _pinController,
            maxLength: _pinLength,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            showCursor: false,
            style: const TextStyle(color: Colors.transparent),
            decoration: const InputDecoration(
              border: InputBorder.none,
              counterText: '',
            ),
            onChanged: (value) {
              setState(() {});
              if (value.length == _pinLength) {
                _onPinSubmitted();
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool useBoxesUI = _currentState == _AuthState.login || _currentState == _AuthState.setupConfirm;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.security, size: 60),
              const SizedBox(height: 20),
              Text(_getTitle(), style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 20),

              if (useBoxesUI)
                _buildPinInputArea()
              else
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _pinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.center,
                    maxLength: 8,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'PIN (4-8 dígitos)',
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _onPinSubmitted(),
                  ),
                ),
              
              const SizedBox(height: 16),
              if (_errorMessage != null)
                Text(
                  _errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),

              if (_currentState == _AuthState.setup) ...[
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _onPinSubmitted,
                  child: const Text('Continuar'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  CloseAction _closeAction = CloseAction.minimize;
  bool _startup = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final closeActionName = prefs.getString(_closeActionKey) ?? CloseAction.minimize.name;
    final startup = await launchAtStartup.isEnabled();

    if (mounted) {
      setState(() {
        _closeAction = CloseAction.values.firstWhere(
          (e) => e.name == closeActionName,
          orElse: () => CloseAction.minimize,
        );
        _startup = startup;
        _isLoading = false;
      });
    }
  }

  Future<void> _setCloseAction(CloseAction? value) async {
    if (value == null) return;
    setState(() => _closeAction = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_closeActionKey, value.name);
  }

  Future<void> _setStartup(bool value) async {
    setState(() => _startup = value);
    try {
      if (value) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }

      // Guardamos en prefs solo como respaldo (opcional)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_startupActionKey, value);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              value 
              ? 'Inicio automático activado.' 
              : 'Inicio automático desactivado.'
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      // Si algo falla (ej. permisos), revertimos el switch
      if (mounted) {
        setState(() => _startup = !value);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al cambiar el inicio automático: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ajustes'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                Text(
                  'Comportamiento de la Aplicación',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const Divider(height: 20),
                ListTile(
                  title: const Text('Al presionar el botón de cerrar (X)'),
                  subtitle: Text(_closeAction == CloseAction.minimize
                      ? 'Minimizar a la bandeja'
                      : 'Cerrar la aplicación'),
                ),
                RadioListTile<CloseAction>(
                  title: const Text('Minimizar a la bandeja'),
                  value: CloseAction.minimize,
                  groupValue: _closeAction,
                  onChanged: _setCloseAction,
                ),
                RadioListTile<CloseAction>(
                  title: const Text('Cerrar la aplicación'),
                  subtitle: const Text('La aplicación se cerrará completamente.'),
                  value: CloseAction.exit,
                  groupValue: _closeAction,
                  onChanged: _setCloseAction,
                ),
                const SizedBox(height: 24),
                Text(
                  'Inicio del Sistema',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const Divider(height: 20),
                SwitchListTile(
                  title: const Text('Iniciar con Windows'),
                  subtitle: const Text('La app se iniciará automáticamente al encender el PC.'),
                  value: _startup,
                  onChanged: _setStartup,
                ),
              ],
            ),
    );
  }
}

// --- UTILIDADES DE OFUSCACIÓN (CIFRADO PERSONALIZADO) ---
  
  // Cifra la extensión (Ej: .png -> 0qoh)
  String _cipherExtension(String ext) {
    String result = '';
    for (int i = 0; i < ext.length; i++) {
      String char = ext[i].toLowerCase();
      if (char == '.') {
        result += '0';
      } else if (RegExp(r'[a-z]').hasMatch(char)) {
        int charCode = char.codeUnitAt(0);
        int nextCode = charCode == 122 ? 97 : charCode + 1; // z -> a
        result += String.fromCharCode(nextCode);
      } else {
        result += char; // Mantiene números como el 4
      }
    }
    return result;
  }

  // Descifra la extensión (Ej: 0qoh -> .png)
  String _decipherExtension(String ciphered) {
    String result = '';
    for (int i = 0; i < ciphered.length; i++) {
      String char = ciphered[i].toLowerCase();
      if (char == '0') {
        result += '.';
      } else if (RegExp(r'[a-z]').hasMatch(char)) {
        int charCode = char.codeUnitAt(0);
        int prevCode = charCode == 97 ? 122 : charCode - 1; // a -> z
        result += String.fromCharCode(prevCode);
      } else {
        result += char; // Mantiene números como el 4
      }
    }
    return result;
  }

  // Convierte: "imagen.mp4" -> "imagen0nq4.vtx"
  String _obfuscateName(String originalName) {
    if (originalName.toLowerCase().endsWith('.vtx')) return originalName;

    final ext = p.extension(originalName); // Ej: .mp4
    final base = p.basenameWithoutExtension(originalName); // Ej: imagen
    final cipheredExt = _cipherExtension(ext); // Ej: 0nq4

    return '$base$cipheredExt.vtx';
  }

  // Convierte: "imagen0nq4.vtx" -> "imagen.mp4"
  String _getDeobfuscatedName(String filename) {
    if (filename.toLowerCase().endsWith('.vtx')) {
      final base = p.basenameWithoutExtension(filename); // Ej: imagen0nq4
      final lastZero = base.lastIndexOf('0'); // Buscamos dónde empieza el cifrado
      
      if (lastZero != -1) {
        final realBase = base.substring(0, lastZero); // imagen
        final realExt = _decipherExtension(base.substring(lastZero)); // .mp4
        return '$realBase$realExt';
      }
      return base;
    }
    return filename;
  }

  // Obtiene la extensión real oculta: ".mp4"
  String _getRealExtension(String filename) {
    if (filename.toLowerCase().endsWith('.vtx')) {
      final base = p.basenameWithoutExtension(filename);
      final lastZero = base.lastIndexOf('0');
      
      if (lastZero != -1) {
        return _decipherExtension(base.substring(lastZero));
      }
    }
    return p.extension(filename).toLowerCase();
  }

  // Detecta videos leyendo la extensión real descifrada
  bool _isVideo(String filePath) {
    final ext = _getRealExtension(filePath);
    return ['.mp4', '.mov', '.avi', '.mkv'].contains(ext);
  }