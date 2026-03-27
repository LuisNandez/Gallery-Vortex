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
import 'package:local_notifier/local_notifier.dart';
import 'dart:ui';
import 'package:google_fonts/google_fonts.dart';

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
const String _showNotificationsKey = 'show_notifications';
const String _sortCriteriaKey = 'sort_criteria';
const String _sortAscendingKey = 'sort_ascending';

enum SortCriteria { date, name, size }
enum CloseAction { exit, minimize }

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  bool startHidden = args.contains('--minimized');

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  
  await windowManager.ensureInitialized();
  await localNotifier.setup(
    appName: 'GVortex',
    shortcutPolicy: ShortcutPolicy.requireCreate, // <-- ESTA ES LA MAGIA PARA WINDOWS
  );

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
    if (startHidden) {
      await windowManager.hide();
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  });

  // Le pasamos el estado a MyApp
  runApp(MyApp(startHidden: startHidden));
}

class SiguienteImagenIntent extends Intent { const SiguienteImagenIntent(); }
class AnteriorImagenIntent extends Intent { const AnteriorImagenIntent(); }
class GridUpIntent extends Intent { const GridUpIntent(); }
class GridDownIntent extends Intent { const GridDownIntent(); }
class GridLeftIntent extends Intent { const GridLeftIntent(); }
class GridRightIntent extends Intent { const GridRightIntent(); }
class GridEnterIntent extends Intent { const GridEnterIntent(); }
class CloseViewerIntent extends Intent { const CloseViewerIntent(); }

class MyApp extends StatelessWidget {
  final bool startHidden; // <-- NUEVO
  const MyApp({super.key, this.startHidden = false});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GVortex',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        // Tipografía personalizada con Google Fonts (Inter) y colores adaptados al modo oscuro
        textTheme: GoogleFonts.interTextTheme(
          ThemeData.dark().textTheme,
        ).apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
        // Paleta de colores estilo macOS Dark Mode
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF0A84FF), // Azul clásico de macOS
          secondary: Color(0xFF5E5CE6), // Púrpura sutil
          surface: Color(0xFF1E1E1E), // Gris oscuro para tarjetas/diálogos
          background: Color(0xFF000000), // Fondo negro profundo
        ),
        scaffoldBackgroundColor: const Color(0xFF000000),
        // Tipografía del sistema (San Francisco en Apple, Segoe en Windows)
        fontFamily: Platform.isMacOS || Platform.isIOS ? '.SF Pro Text' : 'Segoe UI',
        
        // AppBars planos y translúcidos
        appBarTheme: const AppBarThemeData(
          backgroundColor: Color(0xE61C1C1E), // Gris muy oscuro con ligera transparencia
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          iconTheme: IconThemeData(color: Colors.white, size: 20),
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.5,
          ),
        ),
        
        // Diálogos con bordes más suaves y sin sombras gigantes
        dialogTheme: const DialogThemeData(
          backgroundColor: Color(0xFF2C2C2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
          elevation: 10,
        ),
        
        // Menús emergentes (Dropdowns) estilo panel flotante
        popupMenuTheme: PopupMenuThemeData(
          color: const Color(0xFF2C2C2E),
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Colors.white12, width: 0.5), // Borde finísimo
          ),
        ),
        
        dividerTheme: const DividerThemeData(color: Colors.white12, thickness: 0.5),
      ),
      home: AuthWrapper(startHidden: startHidden),
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
  final bool startHidden;
  const AuthWrapper({super.key, this.startHidden = false});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WindowListener, TrayListener {
  bool _isAuthenticated = false;
  late bool _isWindowVisible;

  final GlobalKey<_VaultExplorerScreenState> _vaultExplorerKey = GlobalKey<_VaultExplorerScreenState>();

  @override
  void initState() {
    super.initState();
    _isWindowVisible = !widget.startHidden;
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
    await trayManager.setToolTip('Galería Vórtice');
    // Eliminamos el setContextMenu de aquí. Lo crearemos dinámicamente en el clic derecho.
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    setState(() {
      _isWindowVisible = true;
      _isAuthenticated = false;
    });
    _vaultExplorerKey.currentState?.resume();
  }

  @override
  void onTrayIconRightMouseDown() async {
    // Leemos la variable directamente usando la GlobalKey
    final isPaused = _vaultExplorerKey.currentState?.isWatcherPaused ?? false;
    
    Menu menu = Menu(items: [
      MenuItem(key: 'show_window', label: 'Mostrar Aplicación'),
      // Mostramos un texto distinto según el estado de la variable
      MenuItem(
        key: 'toggle_watcher', 
        label: isPaused ? '▶ Reanudar Vórtice' : '⏸ Pausar Vórtice'
      ),
      MenuItem.separator(),
      MenuItem(key: 'exit_application', label: 'Cerrar Aplicación'),
    ]);
    
    await trayManager.setContextMenu(menu);
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show_window') {
      windowManager.show();
      setState(() {
        _isWindowVisible = true;
        _isAuthenticated = false;
      });
      _vaultExplorerKey.currentState?.resume();
    } else if (menuItem.key == 'toggle_watcher') {
      // Mandamos a llamar la función del explorador desde aquí afuera
      _vaultExplorerKey.currentState?.toggleWatcher();
    } else if (menuItem.key == 'exit_application') {
      windowManager.destroy();
    }
  }

  void onWindowHide() {
    setState(() {
      _isWindowVisible = false;
      // Le decimos a VaultExplorer que libere sus recursos de UI.
      _vaultExplorerKey.currentState?.pause();
    });
  }

  void onWindowShow() {
    setState(() {
      _isWindowVisible = true;
      _isAuthenticated = false; // Forzar re-autenticación por seguridad.
      // Le decimos a VaultExplorer que se prepare para ser mostrado.
      _vaultExplorerKey.currentState?.resume();
    });
  }
  
  @override
  void onWindowMinimize() {
    // Si el usuario minimiza con el botón (-), también activamos la pausa
    _vaultExplorerKey.currentState?.pause();
  }

  @override
  void onWindowRestore() {
    // Al restaurar la ventana desde la barra de tareas, reanudamos
    _vaultExplorerKey.currentState?.resume();
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
            startPaused: widget.startHidden,
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
  final bool startPaused;

  const VaultExplorerScreen({
    super.key,
    this.currentDirectory,
    required this.setAuthenticated,
    this.startPaused = false,
  });

  @override
  State<VaultExplorerScreen> createState() => _VaultExplorerScreenState();
}

class _VaultExplorerScreenState extends State<VaultExplorerScreen>
    with WindowListener{
  List<FileSystemEntity> _vaultContents = [];
  bool _isLoading = true;
  late bool _isPaused;
  bool _isWatcherPaused = false;
  String? _vortexPath;
  StreamSubscription<WatchEvent>? _watcherSubscription;
  final Set<String> _processingFiles = {};
  late Directory _currentVaultDir;
  late Directory _vaultRootDir;
  final TextEditingController _folderNameController = TextEditingController();

  // Instancias de los servicios
  final MetadataService _metadataService = MetadataService();
  final ThumbnailService _thumbnailService = ThumbnailService();

  // State for selection and clipboard
  Set<FileSystemEntity> _selectedItems = {};
  static List<FileSystemEntity> _clipboard = [];

  int _focusedIndex = -1;

  bool get isWatcherPaused => _isWatcherPaused;

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

  // State para notificaciones
  int _backgroundAbsorbedCount = 0;
  Timer? _notificationTimer;

  // State para ordenamiento
  SortCriteria _currentSortCriteria = SortCriteria.date;
  bool _sortAscending = true; // true = más viejo/A-Z/más liviano primero

  // NUEVAS VARIABLES PARA EL MENÚ DE FILTRO ESTILO MAC
  final GlobalKey _sortButtonKey = GlobalKey();
  OverlayEntry? _sortOverlay;

  bool _isSupportedFile(String filePath) {
  final ext = p.extension(filePath).toLowerCase();
  return _isImageFile(filePath) || ['.mp4', '.mov', '.avi', '.mkv'].contains(ext);
}


  @override
  void initState() {
    super.initState();
    _isPaused = widget.startPaused;
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
    _sortOverlay?.remove();
    _scrollController.dispose();
    _notificationTimer?.cancel();
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
      pause();
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
    final sortIndex = prefs.getInt(_sortCriteriaKey) ?? SortCriteria.date.index;
    final sortAscending = prefs.getBool(_sortAscendingKey) ?? true;
    
    setState(() {
      _thumbnailExtent = savedSize;
      _currentSortCriteria = SortCriteria.values[sortIndex];
      _sortAscending = sortAscending;
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
    if (!quiet) {
      setState(() => _isLoading = true);
    }

    if (!await _currentVaultDir.exists()) {
      await _currentVaultDir.create(recursive: true);
    }
    
    final contents = await _currentVaultDir.list().toList();

    // --- MAGIA DE OPTIMIZACIÓN (CACHÉ) ---
    // Pre-calculamos los valores UNA SOLA VEZ para que el ordenamiento sea instantáneo
    final Map<String, int> sizeCache = {};
    final Map<String, String> nameCache = {};
    final Map<String, int> timeCache = {};

    if (contents.isNotEmpty) {
      for (final entity in contents) {
        if (entity is File) {
          if (_currentSortCriteria == SortCriteria.size) {
            sizeCache[entity.path] = entity.lengthSync(); // Solo 1 lectura al disco duro por archivo
          } else if (_currentSortCriteria == SortCriteria.name) {
            nameCache[entity.path] = _getDeobfuscatedName(p.basename(entity.path)).toLowerCase();
          } else if (_currentSortCriteria == SortCriteria.date) {
            final id = p.relative(entity.path, from: _vaultRootDir.path);
            timeCache[entity.path] = _metadataService.getMetadataForImage(id).addedTimestamp;
          }
        }
      }
    }
    // --- FIN DE LA MAGIA ---

    contents.sort((a, b) {
      // Las carpetas siempre van primero
      if (a is Directory && b is File) return -1;
      if (a is File && b is Directory) return 1;

      int comparison = 0;

      if (a is File && b is File) {
        switch (_currentSortCriteria) {
          case SortCriteria.date:
            // Leemos de nuestra RAM, sin calcular nada
            final timeA = timeCache[a.path] ?? 0;
            final timeB = timeCache[b.path] ?? 0;
            comparison = timeA.compareTo(timeB);
            if (comparison == 0) comparison = a.path.compareTo(b.path);
            break;
            
          case SortCriteria.name:
            final nameA = nameCache[a.path] ?? '';
            final nameB = nameCache[b.path] ?? '';
            comparison = nameA.compareTo(nameB);
            break;
            
          case SortCriteria.size:
            final sizeA = sizeCache[a.path] ?? 0;
            final sizeB = sizeCache[b.path] ?? 0;
            comparison = sizeA.compareTo(sizeB);
            break;
        }
      } else if (a is Directory && b is Directory) {
        comparison = p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
      }

      return _sortAscending ? comparison : -comparison;
    });

    setState(() {
      _vaultContents = contents;
      _itemKeys.clear();
      _isLoading = false; 
      _shiftSelectionAnchorIndex = null;
    });
    
    _thumbnailService.bulkGenerate(contents);
  }

  Future<bool> _waitUntilFileIsReady(File file) async {
    int lastSize = -1;
    int stableCount = 0;

    while (true) {
      try {
        if (!await file.exists()) {
          return false; // El archivo fue borrado o la descarga se canceló
        }

        int currentSize = await file.length();

        // Verificamos si el tamaño es mayor a 0 y no ha cambiado
        if (currentSize == lastSize && currentSize > 0) {
          stableCount++;
          // AUMENTAMOS LA EXIGENCIA: 6 comprobaciones (3 segundos estables)
          // Esto evita que las pausas de internet engañen a la app.
          if (stableCount >= 6) {
            RandomAccessFile? raf;
            try {
              raf = await file.open(mode: FileMode.append);
              await raf.close();
              return true; // ¡100% listo!
            } catch (e) {
              stableCount = 0; // Aún bloqueado por el navegador
            }
          }
        } else {
          stableCount = 0; // Sigue descargando, reiniciamos el contador
        }
        lastSize = currentSize;
      } catch (e) {
        stableCount = 0;
      }

      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  void _startWatcher(String path) {
    _watcherSubscription?.cancel();
    final watcher = DirectoryWatcher(path);
    
    _watcherSubscription = watcher.events.listen((event) async {
      // Ahora escuchamos tanto creaciones como modificaciones
      if ((event.type == ChangeType.ADD || event.type == ChangeType.MODIFY) && 
          _isSupportedFile(event.path)) {
        
        final filePath = event.path;
        
        // Si ya estamos vigilando este archivo, lo ignoramos para no saturar
        if (_processingFiles.contains(filePath)) return;
        
        final file = File(filePath);
        _processingFiles.add(filePath); // Lo agregamos a la lista de espera
        
        try {
          final isReady = await _waitUntilFileIsReady(file);
          
          if (isReady && mounted) {
            await _absorbImage(file);
          }
        } finally {
          // Una vez absorbido (o fallido), lo quitamos de la lista
          _processingFiles.remove(filePath);
        }
      }
    });
  }

  Future<void> toggleWatcher() async {
    setState(() {
      _isWatcherPaused = !_isWatcherPaused;
    });

    if (_isWatcherPaused) {
      await _watcherSubscription?.cancel();
      _watcherSubscription = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vigilancia del Vórtice pausada.')),
        );
      }
    } else {
      if (_vortexPath != null) {
        await _absorbInitialVortexContents(Directory(_vortexPath!), reloadUI: false);
        _startWatcher(_vortexPath!);
        await _loadVaultContents(quiet: true);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Vigilancia del Vórtice reanudada.')),
          );
        }
      }
    }
  }

  Future<String> _getUniquePath(
      Directory destinationDir, String fileName) async {
    bool isVtx = fileName.toLowerCase().endsWith('.vtx');
    String baseName = p.basenameWithoutExtension(fileName); // Ej: imagen0qoh
    String extension = p.extension(fileName); // Ej: .vtx
    String newPath = p.join(destinationDir.path, fileName);
    int counter = 1;

    while (await File(newPath).exists() || await Directory(newPath).exists()) {
      if (isVtx) {
        // Buscamos dónde empieza la extensión cifrada (el último '0')
        final lastZero = baseName.lastIndexOf('0');
        if (lastZero != -1) {
          final realBase = baseName.substring(0, lastZero); // Ej: imagen
          final cipheredExt = baseName.substring(lastZero); // Ej: 0qoh
          
          // Insertamos el contador justo en medio: imagen (1)0qoh.vtx
          fileName = '$realBase ($counter)$cipheredExt$extension';
        } else {
          // Fallback de seguridad
          fileName = '$baseName ($counter)$extension';
        }
      } else {
        // Comportamiento normal para archivos no cifrados o carpetas
        fileName = '$baseName ($counter)$extension';
      }
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
    
    // 1. Conservamos el nombre original exactamente como viene
    final String originalFileName = p.basename(imageFile.path);
    
    // 2. Solo aplicamos la ofuscación (.vtx)
    String newName = _obfuscateName(originalFileName);
    
    final newPathInVault = await _getUniquePath(_vaultRootDir, newName);

    try {
      await _moveFileRobustly(imageFile, newPathInVault);
      
      // 3. NUEVO: Guardamos la fecha exacta de ingreso en la Base de Datos
      final imageId = p.relative(newPathInVault, from: _vaultRootDir.path);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await _metadataService.setAddedTimestamp(imageId, timestamp);

      // (A partir de aquí, el código de notificaciones _isPaused sigue igual)
      if (_isPaused) {
        _backgroundAbsorbedCount++;
        _notificationTimer?.cancel();
        
        _notificationTimer = Timer(const Duration(seconds: 3), () async {
          final prefs = await SharedPreferences.getInstance();
          final showNotif = prefs.getBool(_showNotificationsKey) ?? true;
          
          if (showNotif && _backgroundAbsorbedCount > 0) {
            final notification = LocalNotification(
              title: "GVortex",
              body: "Se han enviado $_backgroundAbsorbedCount archivo(s) a la bóveda.",
            );
            await notification.show();
            _backgroundAbsorbedCount = 0;
          }
        });
      }
      if (p.equals(_currentVaultDir.path, _vaultRootDir.path)) {
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
    });
    
    await _loadVaultContents(quiet: true);
  }

  void _navegarGrid(int delta) {
    if (_vaultContents.isEmpty) return;

    setState(() {
      if (_focusedIndex == -1 || _selectedItems.isEmpty) {
        _focusedIndex = 0;
      } else {
        _focusedIndex += delta;
      }

      if (_focusedIndex < 0) _focusedIndex = 0;
      if (_focusedIndex >= _vaultContents.length) {
        _focusedIndex = _vaultContents.length - 1;
      }

      final entity = _vaultContents[_focusedIndex];
      _selectedItems = {entity};
      _shiftSelectionAnchorIndex = _focusedIndex;
    });

    _scrollToFocusedItem(); // Usamos la función reparada
  }

  void _abrirSeleccionado() {
    if (_focusedIndex != -1 && _focusedIndex < _vaultContents.length) {
      final entity = _vaultContents[_focusedIndex];
      // Simulamos el doble clic para abrir la carpeta o la imagen a pantalla completa
      _onItemTap(entity, isDoubleClick: true);
    } else if (_selectedItems.length == 1) {
      _onItemTap(_selectedItems.first, isDoubleClick: true);
    }
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
            title: 'Restaurar',
            onTap: _handleRestoreSelected,
            icon: Icons.restore),
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
      if (_vortexPath != null) ...[
        const Divider(height: 1, thickness: 1),
        _ContextMenuItemWidget(
            title: 'Restaurar Todo',
            onTap: () {
              _hideContextMenu();
              _restoreAllAndClear(); 
            },
            icon: Icons.settings_backup_restore,
            isDestructive: true), // Lo marcamos en rojo porque vacía toda la bóveda
      ],
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
              child: ClipRRect(
              borderRadius: BorderRadius.circular(8.0),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15), // Efecto Cristal
                child: Material(
                  elevation: 0,
                  color: const Color(0xFF252525).withOpacity(0.65), // Fondo translúcido
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8.0),
                    side: const BorderSide(color: Colors.white12, width: 0.5), // Borde sutil
                  ),
                  child: IntrinsicWidth(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: items,
                    ),
                  ),
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
    final screenSize = MediaQuery.of(context).size;
    const estimatedMenuWidth = 180.0;
    const estimatedMenuHeight = 250.0;

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

    int? currentRating;
    final selectedFiles = _selectedItems.whereType<File>().toList();
    if (selectedFiles.isNotEmpty) {
      final firstId = p.relative(selectedFiles.first.path, from: _vaultRootDir.path);
      currentRating = _metadataService.getMetadataForImage(firstId).rating;
      for (var file in selectedFiles.skip(1)) {
        final id = p.relative(file.path, from: _vaultRootDir.path);
        if (_metadataService.getMetadataForImage(id).rating != currentRating) {
          currentRating = null; 
          break;
        }
      }
    }
  
    // Generamos las opciones de calificación
    final items = List.generate(6, (index) {
      final isSelected = index == currentRating;
      return InkWell(
        onTap: () {
          _hideContextMenu();
          for (final entity in _selectedItems.whereType<File>()) {
            final imageId = p.relative(entity.path, from: _vaultRootDir.path);
            _metadataService.setRatingForImage(imageId, index);
          }
          setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            children: [
              // Espacio para la marca de verificación
              Icon(isSelected ? Icons.check : null, size: 18, color: Colors.white), 
              const SizedBox(width: 12),
              if (index == 0)
                const Text("Sin calificar", style: TextStyle(color: Colors.white))
              else
                RatingStarsDisplay(rating: index, iconSize: 20),
            ],
          ),
        ),
      );
    });

    // Construimos el menú flotante esmerilado
    _contextMenuOverlay = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _hideContextMenu,
                onSecondaryTap: _hideContextMenu,
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              top: top, bottom: bottom, left: left, right: right,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8.0),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15), // Efecto Cristal
                  child: Material(
                    elevation: 0,
                    color: const Color(0xFF252525).withOpacity(0.65), // Fondo translúcido
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8.0),
                      side: const BorderSide(color: Colors.white12, width: 0.5),
                    ),
                    child: IntrinsicWidth(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: items,
                      ),
                    ),
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

  void _hideContextMenu() {
    if (_contextMenuOverlay != null) {
      _contextMenuOverlay!.remove();
      _contextMenuOverlay = null;
    }
  }
  
  void _showFullScreenViewer(List<File> imageFiles, int initialIndex) async {
    _hideContextMenu();
    
    final tappedFile = imageFiles[initialIndex];
    final initialIndexInVault = _vaultContents.indexWhere((e) => e.path == tappedFile.path);

    if (initialIndexInVault != -1) {
      setState(() {
        _focusedIndex = initialIndexInVault;
        _selectedItems = {tappedFile};
        _shiftSelectionAnchorIndex = initialIndexInVault;
      });

      // Esperamos 350ms a que la animación de entrada (Hero/Ruta) termine 
      // para centrar la cuadrícula de fondo de manera invisible.
      Future.delayed(const Duration(milliseconds: 350), () {
        if (mounted) {
          _scrollToFocusedItem(animate: false);
        }
      });
    }

    // NUEVO: Esperamos a que la pantalla completa se cierre y nos devuelva el índice
    final returnedIndex = await Navigator.push<int>(
      context,
      MaterialPageRoute(
        builder: (context) => FullScreenImageViewer(
          imageFiles: imageFiles,
          initialIndex: initialIndex,
          exportCallback: (file) async => await _handleSingleExport(file),
          onClose: () => Navigator.pop(context), 
          metadataService: _metadataService,
          vaultRootPath: _vaultRootDir.path,
          onPageChangedCallback: (fileIndex) {
            final lastViewedFile = imageFiles[fileIndex];
            final indexInVault = _vaultContents.indexWhere((e) => e.path == lastViewedFile.path);
            
            if (indexInVault != -1) {
              setState(() {
                _focusedIndex = indexInVault;
                _selectedItems = {lastViewedFile};
                _shiftSelectionAnchorIndex = indexInVault;
              });
              // Movemos la cuadrícula oculta sin animación para estar listos
              _scrollToFocusedItem(animate: false);
            }
          },
        ),
      ),
    );

    // NUEVO: Sincronizamos la selección al volver
    if (returnedIndex != null) {
      final lastViewedFile = imageFiles[returnedIndex];
      // Buscamos su posición real en la cuadrícula (ya que la cuadrícula incluye carpetas)
      final indexInVault = _vaultContents.indexWhere((e) => e.path == lastViewedFile.path);
      
      if (indexInVault != -1) {
        setState(() {
          _focusedIndex = indexInVault;
          _selectedItems = {lastViewedFile};
          _shiftSelectionAnchorIndex = indexInVault;
        });
      }
    }

    if (mounted) {
      Future.delayed(const Duration(milliseconds: 50), () {
        _scrollToFocusedItem(animate: true); 
      });
    }
  }

  // NUEVO: Método optimizado de Scroll
  void _scrollToFocusedItem({bool animate = false}) {
    if (_focusedIndex < 0 || _focusedIndex >= _vaultContents.length) return;

    final key = _itemKeys[_focusedIndex];
    
    // CASO 1: El elemento ya está dibujado en memoria (visible o cerca)
    if (key != null && key.currentContext != null) {
      Scrollable.ensureVisible(
        key.currentContext!,
        alignment: 0.5, 
        duration: animate ? const Duration(milliseconds: 300) : Duration.zero,
        curve: Curves.easeInOut,
      );
    } 
    // CASO 2: El elemento está tan lejos que Flutter lo destruyó para ahorrar RAM
    else {
      // 1. Calculamos matemáticamente en qué fila debería estar
      final usableWidth = MediaQuery.of(context).size.width - 48.0; 
      int crossAxisCount = (usableWidth / _thumbnailExtent).ceil();
      if (crossAxisCount < 1) crossAxisCount = 1;

      int row = _focusedIndex ~/ crossAxisCount;
      double estimatedOffset = row * (_thumbnailExtent + 8.0); 
      
      // 2. Calculamos el salto para que quede centrado en la pantalla
      double viewportHeight = _scrollController.position.viewportDimension;
      double targetOffset = estimatedOffset - (viewportHeight / 2) + (_thumbnailExtent / 2);
      targetOffset = targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent);

      // 3. Saltamos/Animamos a esa zona
      if (animate) {
        _scrollController.animateTo(
          targetOffset, 
          duration: const Duration(milliseconds: 300), 
          curve: Curves.easeInOut
        ).then((_) {
          // Una vez cerca, el elemento ya se dibujó. Hacemos el ajuste milimétrico final.
          final newKey = _itemKeys[_focusedIndex];
          if (newKey?.currentContext != null) {
            Scrollable.ensureVisible(newKey!.currentContext!, alignment: 0.5, duration: Duration.zero);
          }
        });
      } else {
        _scrollController.jumpTo(targetOffset);
        // Esperamos 1 frame a que Flutter construya los widgets de esa zona
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final newKey = _itemKeys[_focusedIndex];
          if (newKey?.currentContext != null) {
            Scrollable.ensureVisible(newKey!.currentContext!, alignment: 0.5, duration: Duration.zero);
          }
        });
      }
    }
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
      _focusedIndex = index;
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
          _isWatcherPaused = false;
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
      _isWatcherPaused = false;
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
      barrierColor: Colors.black.withOpacity(0.4), // Fondo oscuro sutil
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent, // Transparente para ver el blur
        elevation: 0,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14.0),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20), // Efecto Cristal
            child: Container(
              width: 350,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF252525).withOpacity(0.65), // Gris translúcido
                border: Border.all(color: Colors.white12, width: 0.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white), textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(content, style: const TextStyle(fontSize: 14, color: Colors.white70), textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: TextButton.styleFrom(foregroundColor: Colors.white70),
                        child: const Text('Cancelar', style: TextStyle(fontWeight: FontWeight.w500)),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFF0A84FF)), // Azul Mac
                        child: const Text('Aceptar', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showCreateFolderDialog() async {
    _folderNameController.clear();
    return showDialog(
        context: context,
        barrierColor: Colors.black.withOpacity(0.4),
        builder: (context) {
          return Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14.0),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  width: 350,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF252525).withOpacity(0.65),
                    border: Border.all(color: Colors.white12, width: 0.5),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Crear Nueva Carpeta', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _folderNameController,
                        autofocus: true,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFF1C1C1E).withOpacity(0.8), // Campo de texto oscuro
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          hintText: "Nombre de la carpeta",
                          hintStyle: const TextStyle(color: Colors.white54),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          TextButton(
                            child: const Text('Cancelar', style: TextStyle(fontWeight: FontWeight.w500)),
                            onPressed: () => Navigator.of(context).pop(),
                            style: TextButton.styleFrom(foregroundColor: Colors.white70),
                          ),
                          TextButton(
                            child: const Text('Crear', style: TextStyle(fontWeight: FontWeight.w600)),
                            style: TextButton.styleFrom(foregroundColor: const Color(0xFF0A84FF)),
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
                      )
                    ],
                  ),
                ),
              ),
            ),
          );
        });
  }

  void _showSortMenu(BuildContext context) {
    if (_sortOverlay != null) {
      _sortOverlay?.remove();
      _sortOverlay = null;
      return;
    }

    final RenderBox? button = _sortButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (button == null) return;
    final position = button.localToGlobal(Offset.zero);

    Widget buildMenuItem(String title, SortCriteria criteria) {
      final isSelected = _currentSortCriteria == criteria;
      return InkWell(
        onTap: () async {
          _sortOverlay?.remove();
          _sortOverlay = null;
          final prefs = await SharedPreferences.getInstance();
          setState(() => _currentSortCriteria = criteria);
          await prefs.setInt(_sortCriteriaKey, criteria.index);
          await _loadVaultContents(quiet: true);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            children: [
              Icon(isSelected ? Icons.check : null, size: 18, color: Colors.white),
              const SizedBox(width: 12),
              Text(title, style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
    }

    _sortOverlay = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  _sortOverlay?.remove();
                  _sortOverlay = null;
                },
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              top: position.dy + button.size.height + 8,
              right: MediaQuery.of(context).size.width - position.dx - button.size.width,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8.0),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                  child: Material(
                    elevation: 0,
                    color: const Color(0xFF252525).withOpacity(0.65),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8.0),
                      side: const BorderSide(color: Colors.white12, width: 0.5),
                    ),
                    child: IntrinsicWidth(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          buildMenuItem('Por fecha de ingreso', SortCriteria.date),
                          buildMenuItem('Por nombre original', SortCriteria.name),
                          buildMenuItem('Por tamaño de archivo', SortCriteria.size),
                          const Divider(height: 1, color: Colors.white12),
                          InkWell(
                            onTap: () async {
                              _sortOverlay?.remove();
                              _sortOverlay = null;
                              final prefs = await SharedPreferences.getInstance();
                              setState(() => _sortAscending = !_sortAscending);
                              await prefs.setBool(_sortAscendingKey, _sortAscending);
                              await _loadVaultContents(quiet: true);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                              child: Row(
                                children: [
                                  Icon(_sortAscending ? Icons.arrow_downward : Icons.arrow_upward, size: 18, color: Colors.white),
                                  const SizedBox(width: 12),
                                  Text(_sortAscending ? 'Orden Ascendente' : 'Orden Descendente', style: const TextStyle(color: Colors.white)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    Overlay.of(context).insert(_sortOverlay!);
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
          if (!_isLoading && _vortexPath != null && widget.currentDirectory == null)
            IconButton(
              icon: Icon(
                _isWatcherPaused ? Icons.play_circle_outline : Icons.pause_circle_outline,
                color: _isWatcherPaused ? Colors.amber : Colors.white,
              ),
              tooltip: _isWatcherPaused ? 'Reanudar vórtice' : 'Pausar vórtice',
              onPressed: toggleWatcher,
            ),
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
            if (!_isLoading && _vortexPath != null)
            if (!_isLoading && _vortexPath != null)
            IconButton(
              key: _sortButtonKey,
              icon: const Icon(Icons.sort),
              tooltip: 'Ordenar elementos',
              onPressed: () => _showSortMenu(context),
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
              elevation: 4, // Sombra más controlada
              backgroundColor: const Color(0xFF2C2C2E), // Gris en lugar de color primario
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10), // Bordes menos redondos
                side: const BorderSide(color: Colors.white12, width: 0.5),
              ),
              onPressed: _selectVortexFolder,
              label: Text(
                _vortexPath == null ? 'Seleccionar Vórtice' : 'Cambiar Vórtice',
                style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
              ),
              icon: const Icon(Icons.all_inclusive, size: 18),
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
            child: Text(pathParts[i], style: const TextStyle(fontSize: 14)),
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
            style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculamos cuántas columnas hay actualmente en pantalla
        // El padding horizontal total es 48.0 (24.0 a cada lado)
        double usableWidth = constraints.maxWidth - 48.0;
        int columns = (usableWidth / (_thumbnailExtent + 8.0)).ceil();
        if (columns < 1) columns = 1;

        return Shortcuts(
          shortcuts: <ShortcutActivator, Intent>{
            const SingleActivator(LogicalKeyboardKey.arrowUp): const GridUpIntent(),
            const SingleActivator(LogicalKeyboardKey.arrowDown): const GridDownIntent(),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): const GridLeftIntent(),
            const SingleActivator(LogicalKeyboardKey.arrowRight): const GridRightIntent(),
            const SingleActivator(LogicalKeyboardKey.enter): const GridEnterIntent(),
            const SingleActivator(LogicalKeyboardKey.numpadEnter): const GridEnterIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              // Las flechas Izquierda/Derecha mueven de 1 en 1
              GridLeftIntent: CallbackAction<GridLeftIntent>(onInvoke: (i) => _navegarGrid(-1)),
              GridRightIntent: CallbackAction<GridRightIntent>(onInvoke: (i) => _navegarGrid(1)),
              // Las flechas Arriba/Abajo saltan una fila entera (suman/restan las columnas)
              GridUpIntent: CallbackAction<GridUpIntent>(onInvoke: (i) => _navegarGrid(-columns)),
              GridDownIntent: CallbackAction<GridDownIntent>(onInvoke: (i) => _navegarGrid(columns)),
              // Enter abre el archivo
              GridEnterIntent: CallbackAction<GridEnterIntent>(onInvoke: (i) => _abrirSeleccionado()),
            },
            child: Focus(
              autofocus: true,
              child: Scrollbar(
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
              ),
            ),
          ),
        );
      },
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
                    style: const TextStyle(color: Colors.white, fontSize: 10),
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
              // Fondo gris translúcido para las carpetas
              color: isHovered
                  ? Colors.white.withOpacity(0.1)
                  : isSelected
                      ? const Color(0xFF0A84FF).withOpacity(0.2) // Azul translúcido
                      : Colors.white.withOpacity(0.04), 
              borderRadius: BorderRadius.circular(8.0),
              border: Border.all(
                color: isHovered || isSelected
                    ? const Color(0xFF0A84FF) // Azul macOS
                    : Colors.transparent,
                width: isSelected ? 2.5 : 1.5, // Ligeramente más grueso al seleccionar
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
              '¿Deseas sacar TODAS las imágenes y carpetas de la bóveda? La app olvidará la carpeta Vórtice después de esto.',
        ) ??
        false;
    if (!confirm || !mounted) return;

    // NUEVO: Pedimos la carpeta de destino donde se vaciará todo
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Seleccionar carpeta destino para vaciar la bóveda',
    );

    if (selectedDirectory == null) return;
    final destinationDir = Directory(selectedDirectory);
    
    setState(() => _isLoading = true);
    
    await _watcherSubscription?.cancel();
    _watcherSubscription = null;

    // Ejecuta la función recursiva que ya tiene la lógica de limpiar nombres
    await _restoreDirectoryContents(_vaultRootDir, destinationDir);
    
    await _clearVortexPathSetting();
    await _loadVaultContents();
    
    setState(() => _isLoading = false);
     if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Todos los archivos han sido restaurados exitosamente.')),
      );
    }
  }

  Future<void> _restoreDirectoryContents(Directory source, Directory destination) async {
    final List<FileSystemEntity> contents = await source.list().toList();

    for (final entity in contents) {
      try {
        final idToDelete = p.relative(entity.path, from: _vaultRootDir.path);

        if (entity is File) {
          // NUEVO: Desciframos el nombre aquí también para los archivos internos
          final cleanName = _getDeobfuscatedName(p.basename(entity.path));
          final newPath = await _getUniquePath(destination, cleanName);
          
          await _metadataService.deleteMetadata(idToDelete);
          await _thumbnailService.clearThumbnail(p.basename(entity.path)); 
          await _moveFileRobustly(entity, newPath);
        } else if (entity is Directory) {
          final newDestDir = Directory(await _getUniquePath(destination, p.basename(entity.path)));
          await newDestDir.create();
          
          await _restoreDirectoryContents(entity, newDestDir);
          await _metadataService.deleteMetadata(idToDelete);
          
          await entity.delete(recursive: true);
        }
      } catch (e) {
        debugPrint("Error restaurando '${entity.path}': $e");
      }
    }
  }


  Future<void> _handleRestoreSelected() async {
    _hideContextMenu();
    if (_selectedItems.isEmpty) return;

    // 1. Abrimos el selector de carpetas
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Seleccionar carpeta para restaurar',
    );

    if (selectedDirectory == null) return;
    final destinationDir = Directory(selectedDirectory);

    final count = _selectedItems.length;
    final itemText = count == 1 ? 'el elemento seleccionado' : 'los $count elementos seleccionados';
    bool confirm = await _showConfirmationDialog(
          title: 'Confirmar Restauración',
          content: '¿Deseas mover $itemText a la carpeta seleccionada y quitarlos de la bóveda?',
        ) ?? false;
        
    if (!confirm) {
      setState(() => _selectedItems.clear());
      return;
    }

    for (final entity in _selectedItems) {
      final idToDelete = p.relative(entity.path, from: _vaultRootDir.path);

      if (entity is File) {
        // NUEVO: Desciframos el nombre para recuperar la extensión original (.mp4, .jpg, etc.)
        final cleanName = _getDeobfuscatedName(p.basename(entity.path));
        final newPath = await _getUniquePath(destinationDir, cleanName);
        
        await _metadataService.deleteMetadata(idToDelete);
        await _thumbnailService.clearThumbnail(p.basename(entity.path));
        await _moveFileRobustly(entity, newPath);
      } else if (entity is Directory) {
        final newDestDir = Directory(await _getUniquePath(destinationDir, p.basename(entity.path)));
        await newDestDir.create();
        
        await _restoreDirectoryContents(entity, newDestDir);
        await _metadataService.deleteMetadata(idToDelete);
        await entity.delete(recursive: true);
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count elemento(s) restaurado(s) con éxito a ${destinationDir.path}.')),
      );
    }
    
    setState(() {
      _selectedItems.clear();
    });
    await _loadVaultContents(quiet: true);
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
        placeholderBuilder: (context, heroSize, child) {
          // Esto obliga a la cuadrícula a seguir mostrando la miniatura 
          // intacta, eliminando el parpadeo negro por completo.
          return child; 
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8.0),
            border: Border.all(
              color: widget.isSelected ? const Color(0xFF0A84FF) : Colors.transparent,
              width: 2.5, // Borde de selección limpio
            ),
            // Sombra sutil para dar relieve a las imágenes
            boxShadow: [
              if (!widget.isSelected)
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                )
            ],
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
  final ValueChanged<int>? onPageChangedCallback;

  const FullScreenImageViewer({
    super.key,
    required this.imageFiles,
    required this.initialIndex,
    required this.exportCallback,
    required this.onClose,
    required this.metadataService,
    required this.vaultRootPath,
    this.onPageChangedCallback,
  });

  @override
  State<FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<FullScreenImageViewer> {
  late PageController _pageController;
  late int _currentIndex;
  final GlobalKey _ratingButtonKey = GlobalKey(); // Para saber dónde dibujar el menú
  OverlayEntry? _ratingOverlay; // Para guardar el menú flotante

  String _getCleanName(String path) {
    String filename = p.basename(path);
    if (filename.toLowerCase().endsWith('.vtx')) {
      String base = p.basenameWithoutExtension(filename); // Quita el .vtx
      int lastZero = base.lastIndexOf('0'); // Busca el inicio del cifrado
      if (lastZero != -1) {
        return base.substring(0, lastZero); // Retorna solo el nombre limpio
      }
      return base;
    }
    return filename;
  }

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
    _ratingOverlay?.remove();
    _pageController.dispose();
    super.dispose();
  }

  void _showFullScreenRatingMenu(BuildContext context, String imageId, int currentRating) {
    if (_ratingOverlay != null) return;
    
    // Encontramos la posición exacta del botón en la barra superior
    final RenderBox? button = _ratingButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (button == null) return;
    final position = button.localToGlobal(Offset.zero);
    
    final items = List.generate(6, (index) {
      final isSelected = index == currentRating;
      return InkWell(
        onTap: () {
          _ratingOverlay?.remove();
          _ratingOverlay = null;
          widget.metadataService.setRatingForImage(imageId, index);
          setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            children: [
              Icon(isSelected ? Icons.check : null, size: 18, color: Colors.white),
              const SizedBox(width: 12),
              if (index == 0)
                const Text("Sin calificar", style: TextStyle(color: Colors.white))
              else
                RatingStarsDisplay(rating: index, iconSize: 20),
            ],
          ),
        ),
      );
    });

    _ratingOverlay = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  _ratingOverlay?.remove();
                  _ratingOverlay = null;
                },
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              // Posicionado justo debajo del botón
              top: position.dy + button.size.height + 8, 
              right: MediaQuery.of(context).size.width - position.dx - button.size.width,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8.0),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                  child: Material(
                    elevation: 0,
                    color: const Color(0xFF252525).withOpacity(0.65),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8.0),
                      side: const BorderSide(color: Colors.white12, width: 0.5),
                    ),
                    child: IntrinsicWidth(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: items,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    Overlay.of(context).insert(_ratingOverlay!);
  }

  // --- MÉTODOS DE NAVEGACIÓN ---
  void _irASiguiente() {
    if (_currentIndex < widget.imageFiles.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _irAAnterior() {
    if (_currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentFile = widget.imageFiles[_currentIndex];
    // Calculamos el ID relativo para poder consultar la base de datos
    final imageId = p.relative(currentFile.path, from: widget.vaultRootPath);
    final currentRating = widget.metadataService.getMetadataForImage(imageId).rating;

    // --- ENVOLVEMOS EL WIDGET PARA ESCUCHAR EL TECLADO ---
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.arrowRight): const SiguienteImagenIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): const AnteriorImagenIntent(),
        const SingleActivator(LogicalKeyboardKey.escape): const CloseViewerIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          SiguienteImagenIntent: CallbackAction<SiguienteImagenIntent>(
            onInvoke: (intent) => _irASiguiente(),
          ),
          AnteriorImagenIntent: CallbackAction<AnteriorImagenIntent>(
            onInvoke: (intent) => _irAAnterior(),
          ),
          CloseViewerIntent: CallbackAction<CloseViewerIntent>(
            onInvoke: (intent) => Navigator.of(context).pop(_currentIndex),
          ),
        },
        child: Focus(
          autofocus: true, // Importante para que detecte el teclado al instante
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              elevation: 0,
              // --- AQUÍ AGREGAMOS EL NOMBRE DEL ARCHIVO ---
              title: Text(
                _getCleanName(currentFile.path),
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              leading: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(_currentIndex),
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
                IconButton(
                  key: _ratingButtonKey,
                  icon: currentRating > 0 
                      ? const Icon(Icons.star, color: Colors.amber)
                      : const Icon(Icons.star_outline, color: Colors.white),
                  tooltip: 'Calificación',
                  onPressed: () => _showFullScreenRatingMenu(context, imageId, currentRating),
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
                    if (widget.onPageChangedCallback != null) {
                      widget.onPageChangedCallback!(index);
                    }
                  },
                  itemBuilder: (context, index) {
                    final imageFile = widget.imageFiles[index];
                    final bool isCurrentPage = index == _currentIndex;
                    
                    final bool isVideo = _isVideo(imageFile.path);
                    if (isVideo) {
                      // Retornamos el video SIN Hero para evitar el congelamiento
                      return CustomVideoPlayer(videoFile: imageFile);
                    }
                    return Hero(
                      tag: isCurrentPage ? imageFile.path : '${imageFile.path}_disabled',
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
                        onPressed: _irAAnterior, // Usamos la función nueva
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
                        onPressed: _irASiguiente, // Usamos la función nueva
                      ),
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
      width: (_pinLength * 57).toDouble(),
      height: 55,
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
  bool _showNotifications = true;
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
    final showNotif = prefs.getBool(_showNotificationsKey) ?? true;

    if (mounted) {
      setState(() {
        _closeAction = CloseAction.values.firstWhere(
          (e) => e.name == closeActionName,
          orElse: () => CloseAction.minimize,
        );
        _startup = startup;
        _showNotifications = showNotif;
        _isLoading = false;
      });
    }
  }

  Future<void> _setShowNotifications(bool value) async {
    setState(() => _showNotifications = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showNotificationsKey, value);
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
        title: const Text('Ajustes', style: TextStyle(fontSize: 16)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                // TÍTULO DE SECCIÓN
                const Padding(
                  padding: EdgeInsets.only(left: 16, bottom: 8),
                  child: Text('COMPORTAMIENTO', style: TextStyle(color: Colors.white54, fontSize: 11)),
                ),
                // CAJA AGRUPADORA 1
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      RadioListTile<CloseAction>(
                        title: const Text('Minimizar a la bandeja', style: TextStyle(fontSize: 13)),
                        value: CloseAction.minimize,
                        groupValue: _closeAction,
                        onChanged: _setCloseAction,
                        activeColor: const Color(0xFF0A84FF), // Azul Mac
                      ),
                      const Divider(height: 1, indent: 16, color: Colors.white12),
                      RadioListTile<CloseAction>(
                        title: const Text('Cerrar la aplicación', style: TextStyle(fontSize: 13)),
                        value: CloseAction.exit,
                        groupValue: _closeAction,
                        onChanged: _setCloseAction,
                        activeColor: const Color(0xFF0A84FF),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // TÍTULO DE SECCIÓN 2
                const Padding(
                  padding: EdgeInsets.only(left: 16, bottom: 8),
                  child: Text('SISTEMA Y NOTIFICACIONES', style: TextStyle(color: Colors.white54, fontSize: 11)),
                ),
                // CAJA AGRUPADORA 2
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile.adaptive( // Adaptive da el estilo redondeado nativo
                        title: const Text('Iniciar con el sistema', style: TextStyle(fontSize: 13)),
                        value: _startup,
                        onChanged: _setStartup,
                        activeColor: const Color(0xFF32D74B), // Verde vibrante de Apple
                      ),
                      const Divider(height: 1, indent: 16, color: Colors.white12),
                      SwitchListTile.adaptive(
                        title: const Text('Avisos en segundo plano', style: TextStyle(fontSize: 13)),
                        value: _showNotifications,
                        onChanged: _setShowNotifications,
                        activeColor: const Color(0xFF32D74B), 
                      ),
                    ],
                  ),
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