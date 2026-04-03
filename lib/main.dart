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
const String _showRatingsKey = 'show_ratings_thumbnail';
const String _showTagsKey = 'show_tags_thumbnail';

enum SortCriteria { date, name, size }

enum CloseAction { exit, minimize }

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 1024 * 1024 * 50; // 50 MB para la caché de miniaturas
  MediaKit.ensureInitialized();
  bool startHidden = args.contains('--minimized');

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  await windowManager.ensureInitialized();
  await localNotifier.setup(
    appName: 'GVortex',
    shortcutPolicy:
        ShortcutPolicy.requireCreate, // <-- ESTA ES LA MAGIA PARA WINDOWS
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

class SiguienteImagenIntent extends Intent {
  const SiguienteImagenIntent();
}

class AnteriorImagenIntent extends Intent {
  const AnteriorImagenIntent();
}

class GridUpIntent extends Intent {
  const GridUpIntent();
}

class GridDownIntent extends Intent {
  const GridDownIntent();
}

class GridLeftIntent extends Intent {
  const GridLeftIntent();
}

class GridRightIntent extends Intent {
  const GridRightIntent();
}

class GridEnterIntent extends Intent {
  const GridEnterIntent();
}

class CloseViewerIntent extends Intent {
  const CloseViewerIntent();
}

class ToggleFullScreenIntent extends Intent {
  const ToggleFullScreenIntent();
}

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
        fontFamily:
            Platform.isMacOS || Platform.isIOS ? '.SF Pro Text' : 'Segoe UI',

        // AppBars planos y translúcidos
        appBarTheme: const AppBarThemeData(
          backgroundColor:
              Color(0xE61C1C1E), // Gris muy oscuro con ligera transparencia
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
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12))),
          elevation: 10,
        ),

        // Menús emergentes (Dropdowns) estilo panel flotante
        popupMenuTheme: PopupMenuThemeData(
          color: const Color(0xFF2C2C2E),
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(
                color: Colors.white12, width: 0.5), // Borde finísimo
          ),
        ),

        dividerTheme:
            const DividerThemeData(color: Colors.white12, thickness: 0.5),
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

class _AuthWrapperState extends State<AuthWrapper>
    with WindowListener, TrayListener {
  bool _isAuthenticated = false;
  late bool _isWindowVisible;

  final GlobalKey<_VaultExplorerScreenState> _vaultExplorerKey =
      GlobalKey<_VaultExplorerScreenState>();

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

  void _requirePinAndGoHome() {
    if (!mounted) return;

    // 1. Cierra cualquier subcarpeta, visor de imágenes o ajustes abiertos
    Navigator.of(context).popUntil((route) => route.isFirst);

    // 2. Bloquea la app exigiendo el PIN nuevamente
    setState(() {
      _isAuthenticated = false;
    });
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
    _requirePinAndGoHome();
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
          label: isPaused ? '▶ Reanudar Vórtice' : '⏸ Pausar Vórtice'),
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
      _requirePinAndGoHome();
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
    _requirePinAndGoHome();
    setState(() {
      _isWindowVisible = false;
      // Le decimos a VaultExplorer que libere sus recursos de UI.
      _vaultExplorerKey.currentState?.pause();
    });
  }

  void onWindowShow() {
    _requirePinAndGoHome();
    setState(() {
      _isWindowVisible = true;
      _isAuthenticated = false; // Forzar re-autenticación por seguridad.
      // Le decimos a VaultExplorer que se prepare para ser mostrado.
      _vaultExplorerKey.currentState?.resume();
    });
  }

  @override
  void onWindowMinimize() {
    //_requirePinAndGoHome();
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
    with WindowListener {
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
  final Map<String, GlobalKey> _itemKeys = {};

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

  // --- STATE PARA BÚSQUEDA ---
  bool _isSearchVisible = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // NUEVO: FocusNode para la cuadrícula
  final FocusNode _gridFocusNode = FocusNode();

  // State para visualización de miniaturas
  bool _showRatingsOnThumbnail = true;
  bool _showTagsCountOnThumbnail = true;

  // NUEVAS VARIABLES PARA EL MENÚ DE FILTRO ESTILO MAC
  final GlobalKey _sortButtonKey = GlobalKey();
  OverlayEntry? _sortOverlay;

  bool _isSupportedFile(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    return _isImageFile(filePath) ||
        ['.mp4', '.mov', '.avi', '.mkv'].contains(ext);
  }

  List<FileSystemEntity> _filteredVaultContents = [];

  void _refreshUIPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _showRatingsOnThumbnail = prefs.getBool(_showRatingsKey) ?? true;
      _showTagsCountOnThumbnail = prefs.getBool(_showTagsKey) ?? true;
    });
  }

  void _applySearchFilter() {
    if (_searchQuery.isEmpty) {
      _filteredVaultContents = List.from(_vaultContents);
      return;
    }

    final query = _searchQuery.toLowerCase();
    _filteredVaultContents = _vaultContents.where((entity) {
      if (entity is Directory) {
        return p.basename(entity.path).toLowerCase().contains(query);
      } else if (entity is File) {
        // Buscar por nombre limpio
        final cleanName =
            _getDeobfuscatedName(p.basename(entity.path)).toLowerCase();
        if (cleanName.contains(query)) return true;

        // Buscar por etiquetas
        final imageId = p.relative(entity.path, from: _vaultRootDir.path);
        final tags = _metadataService.getMetadataForImage(imageId).tags;
        if (tags.any((tag) => tag.toLowerCase().contains(query))) return true;

        return false;
      }
      return false;
    }).toList();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0.0);
    }
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
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
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

  Future<void> _syncPreferences() async {
    final prefs = await SharedPreferences.getInstance();

    // Leemos los valores más recientes de la base de datos local
    final sortIndex = prefs.getInt(_sortCriteriaKey) ?? SortCriteria.date.index;
    final sortAscending = prefs.getBool(_sortAscendingKey) ?? true;
    final showRatings = prefs.getBool(_showRatingsKey) ?? true;
    final showTags = prefs.getBool(_showTagsKey) ?? true;

    // Actualizamos el estado de esta pantalla específica
    setState(() {
      _currentSortCriteria = SortCriteria.values[sortIndex];
      _sortAscending = sortAscending;
      _showRatingsOnThumbnail = showRatings;
      _showTagsCountOnThumbnail = showTags;
    });

    // Recargamos el contenido para que se aplique el nuevo ordenamiento
    await _loadVaultContents();
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
    _searchController.dispose();
    _searchFocusNode.dispose();
    _gridFocusNode.dispose();
    super.dispose();
  }

  // --- Window and Tray Listener Methods ---
  @override
  void onWindowClose() async {
    // <-- Convertir a async
    // --- LÓGICA MODIFICADA ---
    final prefs = await SharedPreferences.getInstance();
    final closeAction =
        prefs.getString(_closeActionKey) ?? CloseAction.minimize.name;

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
    final showRatings = prefs.getBool(_showRatingsKey) ?? true;
    final showTags = prefs.getBool(_showTagsKey) ?? true;

    setState(() {
      _thumbnailExtent = savedSize;
      _currentSortCriteria = SortCriteria.values[sortIndex];
      _sortAscending = sortAscending;
      _showRatingsOnThumbnail = showRatings;
      _showTagsCountOnThumbnail = showTags;
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
            sizeCache[entity.path] =
                entity.lengthSync(); // Solo 1 lectura al disco duro por archivo
          } else if (_currentSortCriteria == SortCriteria.name) {
            nameCache[entity.path] =
                _getDeobfuscatedName(p.basename(entity.path)).toLowerCase();
          } else if (_currentSortCriteria == SortCriteria.date) {
            final id = p.relative(entity.path, from: _vaultRootDir.path);
            int dbTime =
                _metadataService.getMetadataForImage(id).addedTimestamp;

            // --- PARCHE ANTISALTOS ---
            // Si la imagen es antigua y tiene fecha 0 en la BD, usamos la fecha
            // de modificación real del archivo físico en tu disco duro.
            if (dbTime == 0) {
              try {
                dbTime = entity.lastModifiedSync().millisecondsSinceEpoch;
              } catch (_) {}
            }

            timeCache[entity.path] = dbTime;
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
        comparison = p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase());
      }

      return _sortAscending ? comparison : -comparison;
    });

    _vaultContents = contents;
    _applySearchFilter(); // Aplicamos el filtro antes de refrescar la UI

    setState(() {
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
        await _absorbInitialVortexContents(Directory(_vortexPath!),
            reloadUI: false);
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
      await Future.delayed(const Duration(milliseconds: 1));
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
              body:
                  "Se han enviado $_backgroundAbsorbedCount archivo(s) a la bóveda.",
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

  Future<void> _absorbInitialVortexContents(Directory vortexDir,
      {bool reloadUI = true}) async {
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
              SnackBar(
                  content: Text(
                      'Carpeta "${p.basename(entity.path)}" ignorada: contiene archivos no válidos o está vacía.')),
            );
          }
        }
      }
    }

    if (reloadUI) {
      await _loadVaultContents();
    }
  }

  Future<void> _moveEntity(
      FileSystemEntity entity, Directory destination) async {
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
    if (_filteredVaultContents.isEmpty) return;

    setState(() {
      if (_focusedIndex == -1 || _selectedItems.isEmpty) {
        _focusedIndex = 0;
      } else {
        _focusedIndex += delta;
      }

      if (_focusedIndex < 0) _focusedIndex = 0;
      if (_focusedIndex >= _filteredVaultContents.length) {
        _focusedIndex = _filteredVaultContents.length - 1;
      }

      final entity = _filteredVaultContents[_focusedIndex];
      _selectedItems = {entity};
      _shiftSelectionAnchorIndex = _focusedIndex;
    });

    _scrollToFocusedItem(); // Usamos la función reparada
  }

  void _abrirSeleccionado() {
    if (_focusedIndex != -1 && _focusedIndex < _filteredVaultContents.length) {
      final entity = _filteredVaultContents[_focusedIndex];
      // Simulamos el doble clic para abrir la carpeta o la imagen a pantalla completa
      _onItemTap(entity, isDoubleClick: true);
    } else if (_selectedItems.length == 1) {
      _onItemTap(_selectedItems.first, isDoubleClick: true);
    }
  }

  void _showContextMenu(BuildContext context, Offset position) {
    _hideContextMenu();
    final screenSize = MediaQuery.of(context).size;

    // 1. LÓGICA DINÁMICA DE POSICIONAMIENTO
    // Determinamos en qué mitad de la pantalla hizo clic el usuario
    final isBottomHalf = position.dy > screenSize.height / 2;
    final isRightHalf = position.dx > screenSize.width / 2;

    // Asignamos las anclas. Si está abajo, lo anclamos al bottom para que crezca hacia arriba.
    final top = isBottomHalf ? null : position.dy;
    final bottom = isBottomHalf ? screenSize.height - position.dy : null;
    final left = isRightHalf ? null : position.dx;
    final right = isRightHalf ? screenSize.width - position.dx : null;

    // Calculamos el espacio máximo disponible para evitar que se salga de la pantalla
    // Le restamos 16 pixeles como margen de seguridad con el borde
    final maxAvailableHeight = isBottomHalf
        ? position.dy - 16.0
        : screenSize.height - position.dy - 16.0;

    final hasImageSelected = _selectedItems.any((item) => item is File);

    final items = <Widget>[
      if (_selectedItems.isNotEmpty)
        _ContextMenuItemWidget(
            title: 'Mover',
            onTap: _handleCut,
            icon: Icons.drive_file_move_outline),
      if (_VaultExplorerScreenState._clipboard.isNotEmpty)
        _ContextMenuItemWidget(
            title: 'Pegar', onTap: _handlePaste, icon: Icons.content_paste_go),
      if (_selectedItems.isEmpty && _vortexPath != null)
        _ContextMenuItemWidget(
          title: 'Crear carpeta',
          onTap: () {
            _hideContextMenu();
            _showCreateFolderDialog();
          },
          icon: Icons.create_new_folder_outlined,
        ),
      if (_selectedItems.length == 1)
        _ContextMenuItemWidget(
          title: 'Renombrar',
          onTap: () {
            _hideContextMenu();
            _showRenameDialog(_selectedItems.first);
          },
          icon: Icons.drive_file_rename_outline,
        ),
      if (hasImageSelected)
        _ContextMenuItemWidget(
          title: 'Etiquetas',
          onTap: () {
            _hideContextMenu();
            final selectedImageIds = _selectedItems
                .whereType<File>()
                .map((f) => p.relative(f.path, from: _vaultRootDir.path))
                .toList();

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
      if (_selectedItems.length ==
          1) // Solo mostramos propiedades si hay 1 solo elemento seleccionado
        _ContextMenuItemWidget(
          title: 'Propiedades',
          onTap: () {
            _hideContextMenu();
            _showPropertiesDialog(_selectedItems.first);
          },
          icon: Icons.info_outline,
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
      /*if (_vortexPath != null) ...[
        const Divider(height: 1, thickness: 1),
        _ContextMenuItemWidget(
            title: 'Restaurar Todo',
            onTap: () {
              _hideContextMenu();
              _restoreAllAndClear(); 
            },
            icon: Icons.settings_backup_restore,
            isDestructive: true),
      ],*/
    ];

    if (items.whereType<_ContextMenuItemWidget>().isEmpty &&
        _VaultExplorerScreenState._clipboard.isEmpty &&
        !hasImageSelected) return;

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
              // 2. RESTRICCIÓN DE ALTURA
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: maxAvailableHeight,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8.0),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Material(
                      elevation: 0,
                      color: const Color(0xFF252525).withOpacity(0.65),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8.0),
                        side:
                            const BorderSide(color: Colors.white12, width: 0.5),
                      ),
                      child: IntrinsicWidth(
                        // 3. SCROLL INTEGRADO
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: items,
                          ),
                        ),
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

    // Lógica dinámica
    final isBottomHalf = position.dy > screenSize.height / 2;
    final isRightHalf = position.dx > screenSize.width / 2;

    final top = isBottomHalf ? null : position.dy;
    final bottom = isBottomHalf ? screenSize.height - position.dy : null;
    final left = isRightHalf ? null : position.dx;
    final right = isRightHalf ? screenSize.width - position.dx : null;

    final maxAvailableHeight = isBottomHalf
        ? position.dy - 16.0
        : screenSize.height - position.dy - 16.0;

    int? currentRating;
    final selectedFiles = _selectedItems.whereType<File>().toList();
    if (selectedFiles.isNotEmpty) {
      final firstId =
          p.relative(selectedFiles.first.path, from: _vaultRootDir.path);
      currentRating = _metadataService.getMetadataForImage(firstId).rating;
      for (var file in selectedFiles.skip(1)) {
        final id = p.relative(file.path, from: _vaultRootDir.path);
        if (_metadataService.getMetadataForImage(id).rating != currentRating) {
          currentRating = null;
          break;
        }
      }
    }

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
              Icon(isSelected ? Icons.check : null,
                  size: 18, color: Colors.white),
              const SizedBox(width: 12),
              if (index == 0)
                const Text("Sin calificar",
                    style: TextStyle(color: Colors.white))
              else
                RatingStarsDisplay(rating: index, iconSize: 20),
            ],
          ),
        ),
      );
    });

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
              top: top,
              bottom: bottom,
              left: left,
              right: right,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxAvailableHeight),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8.0),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Material(
                      elevation: 0,
                      color: const Color(0xFF252525).withOpacity(0.65),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8.0),
                        side:
                            const BorderSide(color: Colors.white12, width: 0.5),
                      ),
                      child: IntrinsicWidth(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: items,
                          ),
                        ),
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
    final initialIndexInVault =
        _filteredVaultContents.indexWhere((e) => e.path == tappedFile.path);

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
            final indexInVault = _filteredVaultContents
                .indexWhere((e) => e.path == lastViewedFile.path);

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
      final indexInVault = _filteredVaultContents
          .indexWhere((e) => e.path == lastViewedFile.path);

      if (indexInVault != -1) {
        setState(() {
          _focusedIndex = indexInVault;
          _selectedItems = {lastViewedFile};
          _shiftSelectionAnchorIndex = indexInVault;
        });
      }
    }

    if (mounted) {
      _gridFocusNode.requestFocus();
      Future.delayed(const Duration(milliseconds: 50), () {
        _scrollToFocusedItem(animate: true);
      });
    }
  }

  // NUEVO: Método optimizado de Scroll
  void _scrollToFocusedItem({bool animate = false}) {
    // CAMBIO 1: Usar _filteredVaultContents
    if (_focusedIndex < 0 || _focusedIndex >= _filteredVaultContents.length)
      return;

    // CAMBIO 2: Obtener la entidad y buscar por su ruta
    final entity = _filteredVaultContents[_focusedIndex];
    final key = _itemKeys[entity.path];

    // ... mantén el resto de la lógica igual, pero asegúrate de usar la llave correcta abajo:

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
      double targetOffset =
          estimatedOffset - (viewportHeight / 2) + (_thumbnailExtent / 2);
      targetOffset =
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent);

      // 3. Saltamos/Animamos a esa zona
      if (animate) {
        _scrollController
            .animateTo(targetOffset,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut)
            .then((_) {
          // CAMBIO 3: Volver a buscar la llave por ruta
          final newKey = _itemKeys[entity.path];
          if (newKey?.currentContext != null) {
            Scrollable.ensureVisible(newKey!.currentContext!,
                alignment: 0.5, duration: Duration.zero);
          }
        });
      } else {
        _scrollController.jumpTo(targetOffset);
        // Esperamos 1 frame a que Flutter construya los widgets de esa zona
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // CAMBIO 4: Volver a buscar la llave por ruta
          final newKey = _itemKeys[entity.path];
          if (newKey?.currentContext != null) {
            Scrollable.ensureVisible(newKey!.currentContext!,
                alignment: 0.5, duration: Duration.zero);
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
        ).then((_) => _syncPreferences());
      } else if (entity is File) {
        final imageFiles = _filteredVaultContents.whereType<File>().toList();
        int initialIndex =
            imageFiles.indexWhere((f) => p.equals(f.path, entity.path));
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
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.shiftRight);

    final isCtrlPressed = RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlLeft) ||
        RawKeyboard.instance.keysPressed
            .contains(LogicalKeyboardKey.controlRight) ||
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
          final start = index < _shiftSelectionAnchorIndex!
              ? index
              : _shiftSelectionAnchorIndex!;
          final end = index > _shiftSelectionAnchorIndex!
              ? index
              : _shiftSelectionAnchorIndex!;
          _selectedItems =
              _filteredVaultContents.sublist(start, end + 1).toSet();
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

      for (int i = 0; i < _filteredVaultContents.length; i++) {
        final entity = _filteredVaultContents[i];
        final key = _itemKeys[entity.path];
        if (key?.currentContext != null) {
          final itemBox = key!.currentContext!.findRenderObject() as RenderBox;

          final topLeftGlobal = itemBox.localToGlobal(Offset.zero);
          final topLeftLocal = gridDetectorBox.globalToLocal(topLeftGlobal);

          final itemRect = Rect.fromLTWH(topLeftLocal.dx, topLeftLocal.dy,
              itemBox.size.width, itemBox.size.height);

          if (_marqueeRect!.overlaps(itemRect)) {
            tempSelection.add(_filteredVaultContents[i]);
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
                color: const Color(0xFF252525)
                    .withOpacity(0.65), // Gris translúcido
                border: Border.all(color: Colors.white12, width: 0.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(content,
                      style:
                          const TextStyle(fontSize: 14, color: Colors.white70),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.white70),
                        child: const Text('Cancelar',
                            style: TextStyle(fontWeight: FontWeight.w500)),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        style: TextButton.styleFrom(
                            foregroundColor:
                                const Color(0xFF0A84FF)), // Azul Mac
                        child: const Text('Aceptar',
                            style: TextStyle(fontWeight: FontWeight.w600)),
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
          // 1. Extraemos la lógica a una función local para reusarla
          Future<void> handleCreate() async {
            if (_folderNameController.text.isNotEmpty) {
              final newDir = Directory(
                  p.join(_currentVaultDir.path, _folderNameController.text));
              if (!await newDir.exists()) {
                await newDir.create();
                if (mounted) Navigator.of(context).pop();
                await _loadVaultContents(quiet: true);
              }
            }
          }

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
                      const Text('Crear Nueva Carpeta',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _folderNameController,
                        autofocus: true,
                        style: const TextStyle(color: Colors.white),
                        // 2. Agregamos onSubmitted para escuchar la tecla ENTER
                        onSubmitted: (_) => handleCreate(),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFF1C1C1E)
                              .withOpacity(0.8), // Campo de texto oscuro
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
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
                            onPressed: () => Navigator.of(context).pop(),
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.white70),
                            child: const Text('Cancelar',
                                style: TextStyle(fontWeight: FontWeight.w500)),
                          ),
                          TextButton(
                            onPressed:
                                handleCreate, // 3. Reusamos la función aquí
                            style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF0A84FF)),
                            child: const Text('Crear',
                                style: TextStyle(fontWeight: FontWeight.w600)),
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

  Future<void> _showRenameDialog(FileSystemEntity entity) async {
    final isFile = entity is File;
    String currentName = p.basename(entity.path);

    // Si es archivo, extraemos el nombre limpio sin extensiones para el TextField
    if (isFile) {
      currentName = _getDeobfuscatedName(currentName);
      currentName = p.basenameWithoutExtension(currentName);
    }

    final TextEditingController renameController =
        TextEditingController(text: currentName);

    // Seleccionamos todo el texto por defecto para editar más rápido
    renameController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: currentName.length,
    );

    final bool? confirm = await showDialog<bool>(
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
                    const Text('Renombrar',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                    const SizedBox(height: 16),
                    TextField(
                      controller: renameController,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white),
                      onSubmitted: (_) => Navigator.of(context).pop(true),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFF1C1C1E).withOpacity(0.8),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          style: TextButton.styleFrom(
                              foregroundColor: Colors.white70),
                          child: const Text('Cancelar',
                              style: TextStyle(fontWeight: FontWeight.w500)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF0A84FF)),
                          child: const Text('Guardar',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ],
                    )
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (confirm == true &&
        renameController.text.isNotEmpty &&
        renameController.text.trim() != currentName) {
      final newNameInput = renameController.text.trim();
      String finalNewName;

      if (isFile) {
        // Recuperamos la extensión real oculta (.png, .mp4, etc.)
        final realExt = _getRealExtension(entity.path);
        // Ensamblamos el nombre como si no estuviera cifrado (ej. "MiFoto.png")
        final nameWithExt = '$newNameInput$realExt';
        // Lo pasamos por tu ofuscador para que le devuelva el formato .vtx (ej. "MiFoto0qoh.vtx")
        finalNewName = _obfuscateName(nameWithExt);
      } else {
        // Si es carpeta, se queda el nombre normal
        finalNewName = newNameInput;
      }

      final destinationDir = Directory(p.dirname(entity.path));
      // Nos aseguramos de que el nombre no exista ya (le añade (1), (2) si es necesario)
      final finalUniquePath =
          await _getUniquePath(destinationDir, finalNewName);

      try {
        final oldId = p.relative(entity.path, from: _vaultRootDir.path);
        final newId = p.relative(finalUniquePath, from: _vaultRootDir.path);

        if (isFile) {
          // ¡NUEVO! Renombramos la miniatura existente en lugar de borrarla
          await _thumbnailService.renameThumbnail(entity.path, finalUniquePath);
          await _moveFileRobustly(entity as File, finalUniquePath);
        } else {
          await entity.rename(finalUniquePath);
        }

        // ¡MAGIA! Actualizamos la Base de Datos para que las etiquetas y estrellas migren a la nueva ruta
        await _metadataService.updateImagePath(oldId, newId);

        setState(() {
          _selectedItems.clear(); // Limpiamos la selección
        });

        // Recargamos la interfaz
        await _loadVaultContents(quiet: true);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error al renombrar: $e')),
          );
        }
      }
    }
  }

  void _showSortMenu(BuildContext context) {
    if (_sortOverlay != null) {
      _sortOverlay?.remove();
      _sortOverlay = null;
      return;
    }

    final RenderBox? button =
        _sortButtonKey.currentContext?.findRenderObject() as RenderBox?;
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
              Icon(isSelected ? Icons.check : null,
                  size: 18, color: Colors.white),
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
              right: MediaQuery.of(context).size.width -
                  position.dx -
                  button.size.width,
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
                          buildMenuItem(
                              'Por fecha de ingreso', SortCriteria.date),
                          buildMenuItem(
                              'Por nombre original', SortCriteria.name),
                          buildMenuItem(
                              'Por tamaño de archivo', SortCriteria.size),
                          const Divider(height: 1, color: Colors.white12),
                          InkWell(
                            onTap: () async {
                              _sortOverlay?.remove();
                              _sortOverlay = null;
                              final prefs =
                                  await SharedPreferences.getInstance();
                              setState(() => _sortAscending = !_sortAscending);
                              await prefs.setBool(
                                  _sortAscendingKey, _sortAscending);
                              await _loadVaultContents(quiet: true);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16.0, vertical: 12.0),
                              child: Row(
                                children: [
                                  Icon(
                                      _sortAscending
                                          ? Icons.arrow_downward
                                          : Icons.arrow_upward,
                                      size: 18,
                                      color: Colors.white),
                                  const SizedBox(width: 12),
                                  Text(
                                      _sortAscending
                                          ? 'Orden Ascendente'
                                          : 'Orden Descendente',
                                      style:
                                          const TextStyle(color: Colors.white)),
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
          if (!_isLoading && _vortexPath != null)
            IconButton(
              icon: Icon(
                _isSearchVisible ? Icons.search_off : Icons.search,
                color:
                    _isSearchVisible ? const Color(0xFF0A84FF) : Colors.white,
              ),
              tooltip: 'Buscar (Nombre o Etiqueta)',
              onPressed: () {
                setState(() {
                  _isSearchVisible = !_isSearchVisible;
                  if (!_isSearchVisible) {
                    _searchQuery = '';
                    _searchController.clear();
                    _applySearchFilter();
                  }
                });
                if (_isSearchVisible) {
                  _searchFocusNode.requestFocus();
                } else {
                  _gridFocusNode.requestFocus();
                }
              },
            ),
          if (!_isLoading &&
              _vortexPath != null &&
              widget.currentDirectory == null)
            IconButton(
              icon: Icon(
                _isWatcherPaused
                    ? Icons.play_circle_outline
                    : Icons.pause_circle_outline,
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
          /*if (!_isLoading &&
              _vortexPath != null &&
              widget.currentDirectory == null)
            IconButton(
              icon: const Icon(Icons.restore_from_trash),
              tooltip: 'Restaurar todo y olvidar carpeta',
              onPressed: _restoreAllAndClear,
            ),*/
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
              backgroundColor:
                  const Color(0xFF2C2C2E), // Gris en lugar de color primario
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(10), // Bordes menos redondos
                side: const BorderSide(color: Colors.white12, width: 0.5),
              ),
              onPressed: _selectVortexFolder,
              label: Text(
                _vortexPath == null ? 'Seleccionar Vórtice' : 'Cambiar Vórtice',
                style:
                    const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
              ),
              icon: const Icon(Icons.all_inclusive, size: 18),
            )
          : null,
    );
  }

  Widget _buildThumbnailSlider() {
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
    return _filteredVaultContents.isEmpty && _searchQuery.isEmpty
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
                      border:
                          Border.all(color: Colors.deepPurpleAccent, width: 1),
                      color: Colors.deepPurpleAccent.withOpacity(0.2),
                    ),
                  ),
                ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _isSearchVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !_isSearchVisible,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12.0),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                          child: Container(
                            width: 350,
                            decoration: BoxDecoration(
                                color:
                                    const Color(0xFF252525).withOpacity(0.65),
                                border: Border.all(
                                    color: Colors.white12, width: 0.5),
                                boxShadow: [
                                  BoxShadow(
                                      color: Colors.black.withOpacity(0.2),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4))
                                ]),
                            child: CallbackShortcuts(
                              bindings: {
                                const SingleActivator(
                                    LogicalKeyboardKey.escape): () {
                                  // Cuando se presiona Esc, limpiamos, ocultamos y quitamos el foco
                                  setState(() {
                                    _isSearchVisible = false;
                                    _searchQuery = '';
                                    _searchController.clear();
                                    _applySearchFilter();
                                  });
                                  _gridFocusNode.requestFocus();
                                }
                              },
                              child: TextField(
                                controller: _searchController,
                                focusNode: _searchFocusNode,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14),
                                onChanged: (value) {
                                  setState(() {
                                    _searchQuery = value;
                                    _applySearchFilter();
                                  });
                                },
                                decoration: InputDecoration(
                                  hintText: 'Buscar nombre o etiqueta...',
                                  hintStyle:
                                      const TextStyle(color: Colors.white54),
                                  prefixIcon: const Icon(Icons.search,
                                      color: Colors.white54, size: 20),
                                  suffixIcon: _searchQuery.isNotEmpty
                                      ? IconButton(
                                          icon: const Icon(Icons.cancel,
                                              color: Colors.white54, size: 16),
                                          onPressed: () {
                                            _searchController.clear();
                                            setState(() {
                                              _searchQuery = '';
                                              _applySearchFilter();
                                            });
                                          },
                                        )
                                      : null,
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 14),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
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
            const SingleActivator(LogicalKeyboardKey.arrowUp):
                const GridUpIntent(),
            const SingleActivator(LogicalKeyboardKey.arrowDown):
                const GridDownIntent(),
            const SingleActivator(LogicalKeyboardKey.arrowLeft):
                const GridLeftIntent(),
            const SingleActivator(LogicalKeyboardKey.arrowRight):
                const GridRightIntent(),
            const SingleActivator(LogicalKeyboardKey.enter):
                const GridEnterIntent(),
            const SingleActivator(LogicalKeyboardKey.numpadEnter):
                const GridEnterIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              // Las flechas Izquierda/Derecha mueven de 1 en 1
              GridLeftIntent: CallbackAction<GridLeftIntent>(
                  onInvoke: (i) => _navegarGrid(-1)),
              GridRightIntent: CallbackAction<GridRightIntent>(
                  onInvoke: (i) => _navegarGrid(1)),
              // Las flechas Arriba/Abajo saltan una fila entera (suman/restan las columnas)
              GridUpIntent: CallbackAction<GridUpIntent>(
                  onInvoke: (i) => _navegarGrid(-columns)),
              GridDownIntent: CallbackAction<GridDownIntent>(
                  onInvoke: (i) => _navegarGrid(columns)),
              // Enter abre el archivo
              GridEnterIntent: CallbackAction<GridEnterIntent>(
                  onInvoke: (i) => _abrirSeleccionado()),
            },
            child: Focus(
              focusNode: _gridFocusNode,
              autofocus: true,
              onKeyEvent: (FocusNode node, KeyEvent event) {
                if (event.logicalKey == LogicalKeyboardKey.tab) {
                  // Le decimos a Flutter "Ya me encargué de esta tecla, no hagas nada más"
                  return KeyEventResult.handled; 
                }
                // Para cualquier otra tecla, dejamos que Flutter haga su trabajo normal
                return KeyEventResult.ignored;
              },
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(
                    begin: 8.0, // Valor inicial por defecto
                    end: _isSearchVisible
                        ? 70.0
                        : 8.0, // Hacia dónde debe animarse
                  ),
                  duration: const Duration(
                      milliseconds: 200), // La misma duración que la barra
                  curve:
                      Curves.easeInOut, // Animación suave al inicio y al final
                  builder: (context, animatedTopPadding, child) {
                    return GridView.builder(
                      key: _gridDetectorKey,
                      controller: _scrollController,
                      // USAMOS EL PADDING ANIMADO AQUÍ:
                      padding: EdgeInsets.only(
                        left: 24.0,
                        right: 24.0,
                        top: animatedTopPadding,
                        bottom: 8.0,
                      ),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: _thumbnailExtent,
                        mainAxisSpacing: 8.0,
                        crossAxisSpacing: 8.0,
                      ),
                      itemCount: _filteredVaultContents.length,
                      itemBuilder: (context, index) {
                        final entity = _filteredVaultContents[index];
                        _itemKeys.putIfAbsent(entity.path, () => GlobalKey());
                        return KeyedSubtree(
                          key: ValueKey(
                              '${entity.path}_${_showRatingsOnThumbnail}_${_showTagsCountOnThumbnail}'),
                          child: Container(
                            key: _itemKeys[entity.path],
                            child: _buildDraggableItem(entity, index),
                          ),
                        );
                      },
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
            child: Icon(Icons.movie_creation_outlined,
                size: 50, color: Colors.white70),
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
                      ? const Color(0xFF0A84FF)
                          .withOpacity(0.2) // Azul translúcido
                      : Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(8.0),
              border: Border.all(
                color: isHovered || isSelected
                    ? const Color(0xFF0A84FF) // Azul macOS
                    : Colors.transparent,
                width: isSelected
                    ? 2.5
                    : 1.5, // Ligeramente más grueso al seleccionar
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder,
                    size: _thumbnailExtent * 0.4, color: Colors.amber),
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
      imageId: imageId,
      isSelected: isSelected,
      extent: _thumbnailExtent,
      metadataService: _metadataService,
      thumbnailService: _thumbnailService,
      showRatings: _showRatingsOnThumbnail,
      showTagsCount: _showTagsCountOnThumbnail,
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
    final itemText = count == 1
        ? 'el elemento seleccionado'
        : 'los $count elementos seleccionados';
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
        final newDirPath =
            await _getUniquePath(exportRootDir, p.basename(entity.path));
        await _copyDirectory(entity, Directory(newDirPath));
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${_selectedItems.length} elemento(s) exportado(s) con éxito a ${exportRootDir.path}.')));
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
            content:
                Text('Archivo exportado con éxito a ${exportRootDir.path}.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error al exportar: $e')));
      }
    }
  }

  Future<void> _restoreAllAndClear({VoidCallback? onStart}) async {
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
    if (onStart != null) onStart();

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
        const SnackBar(
            content:
                Text('Todos los archivos han sido restaurados exitosamente.')),
      );
    }
  }

  Future<void> _restoreDirectoryContents(
      Directory source, Directory destination) async {
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
          final newDestDir = Directory(
              await _getUniquePath(destination, p.basename(entity.path)));
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
    final itemText = count == 1
        ? 'el elemento seleccionado'
        : 'los $count elementos seleccionados';
    bool confirm = await _showConfirmationDialog(
          title: 'Confirmar Restauración',
          content:
              '¿Deseas mover $itemText a la carpeta seleccionada y quitarlos de la bóveda?',
        ) ??
        false;

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
        final newDestDir = Directory(
            await _getUniquePath(destinationDir, p.basename(entity.path)));
        await newDestDir.create();

        await _restoreDirectoryContents(entity, newDestDir);
        await _metadataService.deleteMetadata(idToDelete);
        await entity.delete(recursive: true);
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '$count elemento(s) restaurado(s) con éxito a ${destinationDir.path}.')),
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

  void _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          metadataService: _metadataService, // <--- PASAR SERVICIO
          onChanged: _refreshUIPreferences,
          onRestoreAll: (_vortexPath != null && widget.currentDirectory == null)
              ? () => _restoreAllAndClear(
                    onStart: () {
                      if (Navigator.canPop(context)) Navigator.pop(context);
                    },
                  )
              : null,
        ),
      ),
    );
    //_syncPreferences();
    _refreshUIPreferences();
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _showRatingsOnThumbnail = prefs.getBool(_showRatingsKey) ?? true;
      _showTagsCountOnThumbnail = prefs.getBool(_showTagsKey) ?? true;
    });
  }

  Future<void> _showPropertiesDialog(FileSystemEntity entity) async {
    final isFile = entity is File;
    String name = p.basename(entity.path);
    String type = isFile ? 'Archivo' : 'Carpeta';
    String sizeStr = '--';
    String dateStr = 'Desconocido';
    
    String addedDateStr = '--';
    int rating = 0;
    List<String> tags = [];

    try {
      // 1. Extraemos datos del sistema operativo
      final stat = await entity.stat();
      dateStr = "${stat.modified.day.toString().padLeft(2, '0')}/${stat.modified.month.toString().padLeft(2, '0')}/${stat.modified.year} ${stat.modified.hour.toString().padLeft(2, '0')}:${stat.modified.minute.toString().padLeft(2, '0')}";
      
      if (isFile) {
        // Limpiamos el nombre usando tus utilidades existentes
        name = _getDeobfuscatedName(name);
        final realExt = _getRealExtension(entity.path).replaceAll('.', '').toUpperCase();
        type = _isVideo(entity.path) ? '$realExt (Video)' : '$realExt (Imagen)';
        
        // Calculamos el peso
        int bytes = stat.size;
        if (bytes < 1024) sizeStr = '$bytes B';
        else if (bytes < 1024 * 1024) sizeStr = '${(bytes / 1024).toStringAsFixed(2)} KB';
        else if (bytes < 1024 * 1024 * 1024) sizeStr = '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
        else sizeStr = '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';

        // 2. Extraemos datos de tu base de datos SQLite (Vórtice)
        final imageId = p.relative(entity.path, from: _vaultRootDir.path);
        final metadata = _metadataService.getMetadataForImage(imageId);
        rating = metadata.rating;
        tags = metadata.tags;
        
        if (metadata.addedTimestamp > 0) {
          final addedDate = DateTime.fromMillisecondsSinceEpoch(metadata.addedTimestamp);
          addedDateStr = "${addedDate.day.toString().padLeft(2, '0')}/${addedDate.month.toString().padLeft(2, '0')}/${addedDate.year} ${addedDate.hour.toString().padLeft(2, '0')}:${addedDate.minute.toString().padLeft(2, '0')}";
        } else {
           // Fallback por si era una imagen vieja sin timestamp
           addedDateStr = dateStr;
        }
      }
    } catch(e) {
      debugPrint("Error leyendo propiedades: $e");
    }

    // 3. Dibujamos el Dialog con diseño macOS, Scroll y expansor de etiquetas
    if (mounted) {
      showDialog(
        context: context,
        barrierColor: Colors.black.withOpacity(0.4),
        builder: (context) {
          bool isTagsExpanded = false; // Estado local para este diálogo

          return StatefulBuilder(
            builder: (context, setState) {
              return Dialog(
                backgroundColor: Colors.transparent,
                elevation: 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14.0),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(
                      width: 350,
                      // Limitamos la altura al 80% de la pantalla para forzar el scroll si es necesario
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.8,
                      ),
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF252525).withOpacity(0.65),
                        border: Border.all(color: Colors.white12, width: 0.5),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Center(
                            child: Text('Propiedades', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white))
                          ),
                          const SizedBox(height: 20),
                          
                          // Flexible + SingleChildScrollView habilitan el scroll interno
                          Flexible(
                            child: SingleChildScrollView(
                              physics: const BouncingScrollPhysics(), // Scroll suave estilo Mac
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildPropertyRow('Nombre:', name),
                                  _buildPropertyRow('Tipo:', type),
                                  if (isFile) _buildPropertyRow('Tamaño:', sizeStr),
                                  _buildPropertyRow('Modificado:', dateStr),
                                  
                                  if (isFile) ...[
                                    const Divider(color: Colors.white12, height: 24, thickness: 1),
                                    const Text('Metadatos del Vórtice', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF0A84FF), fontSize: 13)),
                                    const SizedBox(height: 12),
                                    _buildPropertyRow('Añadido:', addedDateStr),
                                    _buildPropertyRow('Estrellas:', rating > 0 ? '$rating' : 'Sin calificar'),
                                    
                                    // Nuevo row inteligente para las etiquetas
                                    _buildTagsPropertyRow('Etiquetas:', tags, isTagsExpanded, () {
                                      setState(() {
                                        isTagsExpanded = !isTagsExpanded;
                                      });
                                    }),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          
                          const SizedBox(height: 24),
                          Center(
                            child: TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              style: TextButton.styleFrom(foregroundColor: const Color(0xFF0A84FF)),
                              child: const Text('Aceptar', style: TextStyle(fontWeight: FontWeight.w600)),
                            ),
                          )
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }
          );
        },
      );
    }
  }

  // Widget auxiliar estándar
  Widget _buildPropertyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 85, 
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white54, fontSize: 13))
          ),
          Expanded(
            child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 13))
          ),
        ],
      ),
    );
  }

  // NUEVO: Widget auxiliar específico para etiquetas expansibles
  Widget _buildTagsPropertyRow(String label, List<String> tags, bool isExpanded, VoidCallback onToggle) {
    if (tags.isEmpty) {
      return _buildPropertyRow(label, 'Ninguna');
    }

    final displayTags = isExpanded ? tags : tags.take(3).toList();
    final hiddenCount = tags.length - 3;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 85,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white54, fontSize: 13))
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayTags.join(', '), style: const TextStyle(color: Colors.white, fontSize: 13)),
                
                // Botón "Ver más"
                if (!isExpanded && hiddenCount > 0)
                  InkWell(
                    onTap: onToggle,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(
                        'Ver $hiddenCount más...',
                        style: const TextStyle(color: Color(0xFF0A84FF), fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                
                // Botón "Ocultar"
                if (isExpanded && tags.length > 3)
                  InkWell(
                    onTap: onToggle,
                    child: const Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(
                        'Ocultar',
                        style: TextStyle(color: Color(0xFF0A84FF), fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
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
  final bool showRatings;
  final bool showTagsCount;

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
    this.showRatings = true,
    this.showTagsCount = true,
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

  @override
  void didUpdateWidget(ImageItemWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si Flutter nos recicla y nos pasa un archivo distinto al que teníamos...
    if (oldWidget.imageFile.path != widget.imageFile.path) {
      setState(() {
        _thumbFile = null; // Borramos la miniatura vieja (mostrará el cargando)
      });
      _loadThumbnail(); // Cargamos la miniatura correcta
    }
  }

  Future<void> _loadThumbnail() async {
    // Obtenemos la miniatura y actualizamos el estado de ESTE widget
    final thumb = await widget.thumbnailService.getThumbnail(widget.imageFile);
    if (mounted) {
      // Nos aseguramos que el widget todavía existe
      setState(() {
        _thumbFile = thumb;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 1. Obtenemos toda la metadata de una vez para extraer tanto el rating como las etiquetas
    final metadata = widget.metadataService.getMetadataForImage(widget.imageId);
    final rating = metadata.rating;
    final tagsCount =
        metadata.tags.length; // <-- Extraemos la cantidad de etiquetas

    // Usamos la función que descifra el .vtx para saber si es video
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
              color: widget.isSelected
                  ? const Color(0xFF0A84FF)
                  : Colors.transparent,
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
                              child: Icon(Icons.broken_image,
                                  color: Colors.white54, size: 40),
                            ),
                          );
                        },
                        gaplessPlayback: true,
                      ),

                      // 2. CAPA DEL BOTÓN DE PLAY (Solo si es video)
                      if (isVideo) ...[
                        Container(
                            color: Colors
                                .black26), // Oscurece un poco la miniatura
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

                      // 4. Estrellas (Lado derecho)
                      if (widget.showRatings && rating > 0)
                        Positioned(
                          bottom: 4,
                          right: 4,
                          child: RatingStarsDisplay(
                            rating: rating,
                            iconSize: widget.extent / 10,
                          ),
                        ),

                      // 5. NUEVO: Contador de Etiquetas (Lado izquierdo)
                      if (widget.showTagsCount && tagsCount > 0)
                        Positioned(
                          bottom: 4,
                          left: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5.0, vertical: 2.0),
                            decoration: BoxDecoration(
                              color: Colors.black
                                  .withOpacity(0.6), // Fondo oscuro sutil
                              borderRadius: BorderRadius.circular(4.0),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.label_outline,
                                    size: widget.extent / 12,
                                    color: Colors.white70),
                                const SizedBox(width: 3),
                                Text(
                                  '$tagsCount',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: widget.extent / 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
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
  bool _isTrueFullScreen = false;
  bool _showNavigation = true;
  final FocusNode _viewerFocusNode = FocusNode();
  Timer? _hideTimer;

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
    //windowManager.addListener(this);
    //_initWindowState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _startHideTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Precargamos los vecinos de la imagen con la que se abrió el visor
    _precacheAdjacentImages(_currentIndex);
  }

  Future<void> _exportCurrentImage() async {
    final currentFile = widget.imageFiles[_currentIndex];
    await widget.exportCallback(currentFile);
    widget.onClose();
  }

  Future<void> _toggleTrueFullScreen() async {
    if (_isTrueFullScreen) {
      // 1. Actualizamos la interfaz
      if (mounted) setState(() => _isTrueFullScreen = false);
      
      // 2. Restauramos la barra de título normal y des-maximizamos
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.unmaximize();
      
      // 3. Devolvemos el foco al teclado
      _viewerFocusNode.requestFocus();
      if (Platform.isWindows || Platform.isMacOS) {
        await windowManager.focus();
      }
    } else {
      // 1. Actualizamos la interfaz
      if (mounted) setState(() => _isTrueFullScreen = true);
      
      // 2. Ocultamos la barra de título (Borderless) y maximizamos
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.maximize();
    }
  }

  Future<void> _cerrarVisor() async {
    // Si está en pantalla completa, debemos restaurar la ventana normal ANTES de cerrar
    if (_isTrueFullScreen) {
      if (mounted) setState(() => _isTrueFullScreen = false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.unmaximize();
      // Pequeño respiro para que el sistema operativo acomode la ventana antes de destruir la vista
      await Future.delayed(const Duration(milliseconds: 50));
    }
    
    if (mounted) {
      Navigator.of(context).pop(_currentIndex);
    }
  }

  void _handleEscape() {
    if (_isTrueFullScreen) {
      // Si estamos en pantalla completa, solo salimos de ella
      _toggleTrueFullScreen();
    } else {
      // Si ya estamos en ventana normal, cerramos el visor
      _cerrarVisor();
    }
  }

  // NUEVA FUNCIÓN: Despierta o alterna la interfaz
  void _wakeUpUI({bool toggle = false}) {
    final currentFile = widget.imageFiles[_currentIndex];
    final isVideo = _isVideo(currentFile.path);

    if (toggle) {
      setState(() => _showNavigation = !_showNavigation);
    } else {
      // Si la UI está oculta, la mostramos al mover el mouse
      if (!_showNavigation) {
        setState(() => _showNavigation = true);
      }
    }
    
    // IMPORTANTE: El temporizador de 'main.dart' SOLO debe correr para imágenes.
    // Para videos, dejamos que el CustomVideoPlayer controle el tiempo.
    if (_showNavigation && !isVideo) {
      _startHideTimer();
    } else if (!isVideo) {
      _hideTimer?.cancel();
    }
  }

  // NUEVA FUNCIÓN: Inicia la cuenta regresiva
  void _startHideTimer() {
    final currentFile = widget.imageFiles[_currentIndex];
    if (_isVideo(currentFile.path)) return; 

    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _showNavigation = false);
      }
    });
  }

  void _precacheAdjacentImages(int index) {
    if (!mounted) return;
    
    // Precargar la imagen SIGUIENTE
    if (index + 1 < widget.imageFiles.length) {
      final nextFile = widget.imageFiles[index + 1];
      if (!_isVideo(nextFile.path)) {
        precacheImage(FileImage(nextFile), context);
      }
    }
    
    // Precargar la imagen ANTERIOR
    if (index - 1 >= 0) {
      final prevFile = widget.imageFiles[index - 1];
      if (!_isVideo(prevFile.path)) {
        precacheImage(FileImage(prevFile), context);
      }
    }
  }

  @override
  void dispose() {
    //windowManager.removeListener(this);
    _hideTimer?.cancel();
    _viewerFocusNode.dispose();
    _ratingOverlay?.remove();
    _pageController.dispose();
    super.dispose();
  }

  void _showFullScreenRatingMenu(
      BuildContext context, String imageId, int currentRating) {
    if (_ratingOverlay != null) return;

    // Encontramos la posición exacta del botón en la barra superior
    final RenderBox? button =
        _ratingButtonKey.currentContext?.findRenderObject() as RenderBox?;
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
              Icon(isSelected ? Icons.check : null,
                  size: 18, color: Colors.white),
              const SizedBox(width: 12),
              if (index == 0)
                const Text("Sin calificar",
                    style: TextStyle(color: Colors.white))
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
              right: MediaQuery.of(context).size.width -
                  position.dx -
                  button.size.width,
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
    final currentRating =
        widget.metadataService.getMetadataForImage(imageId).rating;

    // --- ENVOLVEMOS EL WIDGET PARA ESCUCHAR EL TECLADO ---
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const SiguienteImagenIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const AnteriorImagenIntent(),
        const SingleActivator(LogicalKeyboardKey.escape):
            const CloseViewerIntent(),
        const SingleActivator(LogicalKeyboardKey.keyF):
            const ToggleFullScreenIntent(),
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
            onInvoke: (intent) => _handleEscape(), // Usamos la nueva función aquí
          ),
          ToggleFullScreenIntent: CallbackAction<ToggleFullScreenIntent>(
            onInvoke: (intent) => _toggleTrueFullScreen(),
          ),
        },
        child: Focus(
          focusNode: _viewerFocusNode,
          autofocus: true, // Importante para que detecte el teclado al instante
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: _isTrueFullScreen ? null : AppBar(
              backgroundColor: Colors.black,
              elevation: 0,
              // --- AQUÍ AGREGAMOS EL NOMBRE DEL ARCHIVO ---
              title: Text(
                _getCleanName(currentFile.path),
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              leading: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: _cerrarVisor,
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
                    ).then((_) => setState(
                        () {})); // Refresca la vista si cambian las etiquetas
                  },
                ),

                // 2. Menú de Calificación (Estrellas)
                IconButton(
                  key: _ratingButtonKey,
                  icon: currentRating > 0
                      ? const Icon(Icons.star, color: Colors.amber)
                      : const Icon(Icons.star_outline, color: Colors.white),
                  tooltip: 'Calificación',
                  onPressed: () => _showFullScreenRatingMenu(
                      context, imageId, currentRating),
                ),

                // 3. Botón de Exportar
                IconButton(
                  icon: const Icon(Icons.download_for_offline_outlined,
                      color: Colors.white),
                  tooltip: 'Exportar',
                  onPressed: _exportCurrentImage,
                ),
              ],
            ),
            body: MouseRegion(
              cursor: _showNavigation ? SystemMouseCursors.basic : SystemMouseCursors.none,
              onHover: (_) => _wakeUpUI(),
              child: Stack(
                alignment: Alignment.center,
                children: [
                PageView.builder(
                  controller: _pageController,
                  itemCount: widget.imageFiles.length,
                  onPageChanged: (index) {
                    _hideTimer?.cancel(); // Matar cualquier contador de la imagen anterior
                    setState(() {
                      _currentIndex = index;
                      if (!_isTrueFullScreen) {
                        _showNavigation = true; 
                      }
                    });
                    _precacheAdjacentImages(index);
                    
                    if (!_isVideo(widget.imageFiles[index].path) && _showNavigation) {
                      _startHideTimer();
                    }
                    widget.onPageChangedCallback?.call(index);
                  },
                  itemBuilder: (context, index) {
                    final imageFile = widget.imageFiles[index];
                    //final bool isCurrentPage = index == _currentIndex;

                    final bool isVideo = _isVideo(imageFile.path);
                    if (isVideo) {
                      return CustomVideoPlayer(
                        videoFile: imageFile,
                        isFullScreen: _isTrueFullScreen, // Pasamos el estado
                        startControlsVisible: _showNavigation,
                        onToggleFullscreen: _toggleTrueFullScreen, // Pasamos la función
                        onControlsVisibilityChanged: (visible) {
                          setState(() => _showNavigation = visible);
                        },
                      );
                    }
                    return GestureDetector(
                        onTap: () => _wakeUpUI(toggle: true),
                        child: Hero(
                          tag: imageFile.path,
                          child: InteractiveViewer(
                            panEnabled: false,
                            minScale: 1.0,
                            maxScale: 4.0,
                            child: Image.file(imageFile, fit: BoxFit.contain),
                          ),
                        ),
                      );
                      
                  },
                ),
                if (_currentIndex > 0)
                  Positioned(
                    left: 10,
                    // Envolvemos el Container, NO el Positioned
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      opacity: _showNavigation ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !_showNavigation, // Evita clics fantasma cuando es invisible
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.5),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                            onPressed: _irAAnterior, 
                          ),
                        ),
                      ),
                    ),
                  ),

                // --- FLECHA DERECHA ---
                if (_currentIndex < widget.imageFiles.length - 1)
                  Positioned(
                    right: 10,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      opacity: _showNavigation ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !_showNavigation,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.5),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            icon: const Icon(Icons.arrow_forward_ios, color: Colors.white),
                            onPressed: _irASiguiente, 
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!_isVideo(currentFile.path)) 
                  Positioned(
                    bottom: 20,
                    right: 20,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      opacity: _showNavigation ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !_showNavigation, // Desactiva el botón cuando no se ve
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.5),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            icon: Icon(
                              _isTrueFullScreen 
                                  ? Icons.fullscreen_exit_rounded 
                                  : Icons.fullscreen_rounded,
                              color: Colors.white,
                            ),
                            tooltip: _isTrueFullScreen 
                                ? 'Salir de pantalla completa' 
                                : 'Pantalla completa',
                            onPressed: _toggleTrueFullScreen,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
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
  void onWindowClose() async {
    // <-- Convertir a async
    // --- LÓGICA MODIFICADA ---
    final prefs = await SharedPreferences.getInstance();
    final closeAction =
        prefs.getString(_closeActionKey) ?? CloseAction.minimize.name;

    if (closeAction == CloseAction.exit.name) {
      windowManager.destroy(); // Cierra la app
    } else {
      windowManager.hide(); // Minimiza a la bandeja
      widget.setAuthenticated(
          true); // Mantiene el comportamiento original de saltar el auth si se minimiza
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

    if (_currentState == _AuthState.setup &&
        (enteredPin.length < 4 || enteredPin.length > 8)) {
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
    bool useBoxesUI = _currentState == _AuthState.login ||
        _currentState == _AuthState.setupConfirm;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.security, size: 60),
              const SizedBox(height: 20),
              Text(_getTitle(),
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 20),
              if (_currentState == _AuthState.checking)
                const SizedBox(
                    height:
                        55) // Mantiene el espacio visual vacío mientras carga
              else if (useBoxesUI)
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
                    decoration: const InputDecoration(
                      labelText: 'PIN (4-8 dígitos)',
                      border: OutlineInputBorder(),
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
  final VoidCallback? onRestoreAll;
  final MetadataService? metadataService;
  final VoidCallback? onChanged;

  const SettingsScreen(
      {super.key, this.onRestoreAll, this.metadataService, this.onChanged});

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

  bool _showRatings = true;
  bool _showTags = true;

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final closeActionName =
        prefs.getString(_closeActionKey) ?? CloseAction.minimize.name;
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
        _showRatings = prefs.getBool(_showRatingsKey) ?? true;
        _showTags = prefs.getBool(_showTagsKey) ?? true;
        _isLoading = false;
      });
    }
  }

  Future<void> _setShowRatings(bool value) async {
    setState(() => _showRatings = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showRatingsKey, value);
    widget.onChanged?.call();
  }

  Future<void> _setShowTags(bool value) async {
    setState(() => _showTags = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showTagsKey, value);
    widget.onChanged?.call();
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
            content: Text(value
                ? 'Inicio automático activado.'
                : 'Inicio automático desactivado.'),
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
                  child: Text('COMPORTAMIENTO',
                      style: TextStyle(color: Colors.white54, fontSize: 11)),
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
                        title: const Text('Minimizar a la bandeja',
                            style: TextStyle(fontSize: 13)),
                        value: CloseAction.minimize,
                        groupValue: _closeAction,
                        onChanged: _setCloseAction,
                        activeColor: const Color(0xFF0A84FF), // Azul Mac
                      ),
                      const Divider(
                          height: 1, indent: 16, color: Colors.white12),
                      RadioListTile<CloseAction>(
                        title: const Text('Cerrar la aplicación',
                            style: TextStyle(fontSize: 13)),
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
                  child: Text('SISTEMA Y NOTIFICACIONES',
                      style: TextStyle(color: Colors.white54, fontSize: 11)),
                ),
                // CAJA AGRUPADORA 2
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile.adaptive(
                        // Adaptive da el estilo redondeado nativo
                        title: const Text('Iniciar con el sistema',
                            style: TextStyle(fontSize: 13)),
                        value: _startup,
                        onChanged: _setStartup,
                        activeColor:
                            const Color(0xFF32D74B), // Verde vibrante de Apple
                      ),
                      const Divider(
                          height: 1, indent: 16, color: Colors.white12),
                      SwitchListTile.adaptive(
                        title: const Text('Avisos en segundo plano',
                            style: TextStyle(fontSize: 13)),
                        value: _showNotifications,
                        onChanged: _setShowNotifications,
                        activeColor: const Color(0xFF32D74B),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                const Padding(
                  padding: EdgeInsets.only(left: 16, bottom: 8),
                  child: Text('VISTA DE MINIATURAS',
                      style: TextStyle(color: Colors.white54, fontSize: 11)),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      SwitchListTile.adaptive(
                        title: const Text('Mostrar calificación (estrellas)',
                            style: TextStyle(fontSize: 13)),
                        value: _showRatings,
                        onChanged: _setShowRatings,
                        activeColor: const Color(0xFF32D74B),
                      ),
                      const Divider(
                          height: 1, indent: 16, color: Colors.white12),
                      SwitchListTile.adaptive(
                        title: const Text('Mostrar contador de etiquetas',
                            style: TextStyle(fontSize: 13)),
                        value: _showTags,
                        onChanged: _setShowTags,
                        activeColor: const Color(0xFF32D74B),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                const Padding(
                  padding: EdgeInsets.only(left: 16, bottom: 8),
                  child: Text('CONTENIDO',
                      style: TextStyle(color: Colors.white54, fontSize: 11)),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.label_outline,
                        color: Color(0xFF0A84FF)),
                    title: const Text('Gestionar Etiquetas',
                        style: TextStyle(fontSize: 13)),
                    trailing: const Icon(Icons.chevron_right,
                        size: 20, color: Colors.white24),
                    onTap: () {
                      if (widget.metadataService != null) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => TagManagementScreen(
                                metadataService: widget.metadataService!),
                          ),
                        );
                      }
                    },
                  ),
                ),

                const SizedBox(height: 24),

                // NUEVA SECCIÓN: ACCIONES DE BÓVEDA
                if (widget.onRestoreAll != null) ...[
                  const Padding(
                    padding: EdgeInsets.only(left: 16, bottom: 8),
                    child: Text('RESTAURAR BÓVEDA',
                        style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: Colors.redAccent.withOpacity(0.2)),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.settings_backup_restore,
                          color: Colors.redAccent),
                      title: const Text('Restaurar toda la bóveda',
                          style:
                              TextStyle(fontSize: 13, color: Colors.redAccent)),
                      subtitle: const Text(
                          'Mueve todos los archivos fuera y olvida la carpeta actual.',
                          style:
                              TextStyle(fontSize: 11, color: Colors.white54)),
                      onTap: () {
                        widget.onRestoreAll!();
                      },
                    ),
                  ),
                ],
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

class TagManagementScreen extends StatefulWidget {
  final MetadataService metadataService;
  const TagManagementScreen({super.key, required this.metadataService});

  @override
  State<TagManagementScreen> createState() => _TagManagementScreenState();
}

class _TagManagementScreenState extends State<TagManagementScreen> {
  late List<String> _allTags; // Guardará TODAS las etiquetas
  late List<String>
      _filteredTags; // Guardará solo las que coincidan con la búsqueda

  final TextEditingController _editController = TextEditingController();
  final TextEditingController _searchController =
      TextEditingController(); // Controlador del buscador

  @override
  void initState() {
    super.initState();
    _allTags = widget.metadataService.getAllTags()..sort();
    _filteredTags = List.from(_allTags); // Al inicio, mostramos todas

    // Escuchamos cada vez que el usuario escribe algo para filtrar en tiempo real
    _searchController.addListener(_filterTags);
  }

  @override
  void dispose() {
    _editController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // Lógica para filtrar la lista
  void _filterTags() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredTags = List.from(_allTags);
      } else {
        _filteredTags =
            _allTags.where((tag) => tag.toLowerCase().contains(query)).toList();
      }
    });
  }

  void _refresh() {
    setState(() {
      _allTags = widget.metadataService.getAllTags()..sort();
      _filterTags(); // Volvemos a aplicar el filtro actual
    });
  }

  Future<void> _showEditDialog(String oldTag) async {
    _editController.text = oldTag;
    return showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14.0),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              width: 320,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E).withOpacity(0.8),
                border: Border.all(color: Colors.white12, width: 0.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Renombrar Etiqueta',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _editController,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1C1C1E).withOpacity(0.8),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      hintText: "Nuevo nombre",
                      hintStyle: const TextStyle(color: Colors.white54),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.white70),
                        child: const Text('Cancelar',
                            style: TextStyle(fontWeight: FontWeight.w500)),
                      ),
                      TextButton(
                        onPressed: () async {
                          await widget.metadataService
                              .renameTagGlobal(oldTag, _editController.text);
                          if (mounted) Navigator.pop(context);
                          _refresh();
                        },
                        style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF0A84FF)),
                        child: const Text('Guardar',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- MÉTODO PARA CONFIRMAR ELIMINACIÓN (Con Efecto Cristal de Mac) ---
  Future<void> _confirmDelete(String tag) async {
    final int count = widget.metadataService.countImagesWithTag(tag);
    final String nounText = count == 1 ? ' imagen' : ' imágenes';

    final bool confirm = await showDialog<bool>(
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
                    width: 320,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2E).withOpacity(0.8),
                      border: Border.all(color: Colors.white12, width: 0.5),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Eliminar Etiqueta',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.white),
                        ),
                        const SizedBox(height: 16),
                        RichText(
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                fontFamily: 'Segoe UI'),
                            children: [
                              TextSpan(
                                  text:
                                      '¿Estás seguro de que deseas eliminar permanentemente la etiqueta "$tag"?\n\nActualmente está siendo usada por '),
                              TextSpan(
                                text: count.toString(),
                                style: const TextStyle(
                                  color: Color(0xFF0A84FF),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              TextSpan(text: '$nounText.'),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              style: TextButton.styleFrom(
                                  foregroundColor: Colors.white70),
                              child: const Text('Cancelar',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w500)),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              style: TextButton.styleFrom(
                                  foregroundColor: Colors.redAccent),
                              child: const Text('Eliminar',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ) ??
        false;

    if (confirm) {
      await widget.metadataService.deleteTagGlobal(tag);
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            const Text('Gestionar Etiquetas', style: TextStyle(fontSize: 15)),
      ),
      body: Column(
        children: [
          // --- BARRA DE BÚSQUEDA MAC STYLE ---
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF1C1C1E),
                prefixIcon:
                    const Icon(Icons.search, color: Colors.white54, size: 20),
                // Botón para limpiar la búsqueda rápidamente
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.cancel,
                            color: Colors.white54, size: 16),
                        onPressed: () {
                          _searchController.clear();
                          FocusScope.of(context)
                              .unfocus(); // Oculta el teclado si está en móvil/tablet
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                hintText: 'Buscar etiqueta...',
                hintStyle: const TextStyle(color: Colors.white54),
              ),
            ),
          ),

          // --- LISTA DE ETIQUETAS FILTRADA ---
          Expanded(
            child: _allTags.isEmpty
                ? const Center(
                    child: Text('No hay etiquetas guardadas.',
                        style: TextStyle(color: Colors.white54)))
                : _filteredTags.isEmpty
                    ? const Center(
                        child: Text('No se encontraron coincidencias.',
                            style: TextStyle(color: Colors.white54)))
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _filteredTags
                            .length, // <-- Usamos la lista filtrada
                        separatorBuilder: (_, __) => const Divider(
                            height: 1, indent: 40, color: Colors.white12),
                        itemBuilder: (context, index) {
                          final tag = _filteredTags[
                              index]; // <-- Usamos la lista filtrada
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.tag,
                                size: 18, color: Colors.white54),
                            title:
                                Text(tag, style: const TextStyle(fontSize: 14)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined,
                                      size: 18, color: Colors.white54),
                                  onPressed: () => _showEditDialog(tag),
                                  tooltip: 'Renombrar',
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 18, color: Colors.redAccent),
                                  onPressed: () => _confirmDelete(tag),
                                  tooltip: 'Eliminar',
                                ),
                              ],
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
