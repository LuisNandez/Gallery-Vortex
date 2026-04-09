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
import 'dart:ffi' hide Size;
import 'ui_utils.dart';
import 'package:desktop_scrollbar/desktop_scrollbar.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

// Imports de los nuevos archivos
import 'metadata_service.dart';
import 'tag_editor_dialog.dart';
import 'rating_stars_display.dart';
import 'pin_input_boxes.dart';
import 'thumbnail_service.dart';

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
const String _notificationDelayKey = 'notification_delay';
const String _autoHideTimeoutKey = 'auto_hide_timeout';

final GlobalKey<_VaultExplorerScreenState> _mainVaultKey = GlobalKey<_VaultExplorerScreenState>();
final ValueNotifier<bool> appVisibilityNotifier = ValueNotifier<bool>(true);
final ValueNotifier<int> autoHideNotifier = ValueNotifier<int>(5);
final ValueNotifier<bool> isVideoPlayingNotifier = ValueNotifier<bool>(false);

enum SortCriteria { date, name, size }

enum CloseAction { exit, minimize }

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  const int singleInstancePort = 53427; // Un puerto interno arbitrario
  
  try {
    // Intentamos adueñarnos de este puerto exclusivo para GVortex
    final serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, singleInstancePort);
    
    // Si pasamos a esta línea, somos la instancia principal.
    // Nos quedamos escuchando en segundo plano por si intentan abrir la app otra vez.
    serverSocket.listen((socket) {
      socket.listen((data) async {
        final msg = String.fromCharCodes(data);
        if (msg == 'wake_up') {
          
          // Verificamos si la ventana existe en pantalla (aunque esté minimizada) o si está oculta en la bandeja
          bool isVisible = await windowManager.isVisible();
          
          if (!isVisible) {
            // CASO 1: Está oculta en la bandeja (Cerrada con la 'x' o por inactividad)
            // -> Mostramos la notificación nativa
            final notification = LocalNotification(
              identifier: 'gvortex_wake',
              title: 'GVortex',
              body: 'La aplicación ya está ejecutándose en segundo plano. Haz clic aquí para abrirla.',
            );

            notification.onClick = () {
              appVisibilityNotifier.value = true; // Esto dispara el _handleWakeUpFromNotification
            };

            await notification.show();
          } else {
            // CASO 2: Está en la barra de tareas (Minimizada con el '-') o detrás de otras ventanas
            // -> La restauramos de golpe sin molestar con notificaciones
            if (await windowManager.isMinimized()) {
              await windowManager.restore();
            }
            await windowManager.show();
            await windowManager.focus();
            
            // Aseguramos que la interfaz (carpetas y bóveda) despierte
            appVisibilityNotifier.value = true;
          }
        }
      });
    });
  } catch (e) {
    // Si el 'bind' falla, significa que el puerto está ocupado (la app YA está abierta).
    // Nos conectamos a la app original, le decimos que despierte, y nos cerramos.
    try {
      final clientSocket = await Socket.connect(InternetAddress.loopbackIPv4, singleInstancePort);
      clientSocket.write('wake_up');
      await clientSocket.flush();
      await clientSocket.close();
    } catch (_) {}
    
    exit(0); // Destruimos esta segunda ventana de inmediato
  }
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
    minimumSize: Size(500, 400),
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
      builder: (context, child) {
        return AuthWrapper(
          startHidden: startHidden,
          navigatorChild: child!, // Pasamos la app entera al Wrapper
        );
      },
      home: VaultExplorerScreen(
        key: _mainVaultKey,
        startPaused: startHidden,
        setAuthenticated: (value) {}, // Ya no importa aquí
      ),
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
  final Widget navigatorChild;
  
  const AuthWrapper({
    super.key, 
    this.startHidden = false, 
    required this.navigatorChild
  });

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WindowListener, TrayListener {
  bool _isAuthenticated = false;
  late bool _isWindowVisible;
  Timer? _inactivityTimer;

  @override
  void initState() {
    super.initState();
    _isWindowVisible = !widget.startHidden;
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initTray();
    // Escuchar el teclado a nivel global (Hardware)
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    // Escuchar cambios en los ajustes de inactividad
    autoHideNotifier.addListener(_resetInactivityTimer);
    isVideoPlayingNotifier.addListener(_resetInactivityTimer); 
    _loadInitialSettings();
    appVisibilityNotifier.addListener(_handleWakeUpFromNotification);
  }
  void _handleWakeUpFromNotification() async {
    // Solo actuamos si la orden dice "despierta" y la app estaba dormida
    if (appVisibilityNotifier.value && !_isWindowVisible) {
      setState(() {
        _isAuthenticated = false; // Exigimos el PIN por seguridad
        _isWindowVisible = true;  // Quitamos la pantalla del escudo
      });
      await windowManager.show();
      await windowManager.focus();
    }
  }

  @override
  void dispose() {
    appVisibilityNotifier.removeListener(_handleWakeUpFromNotification);
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    autoHideNotifier.removeListener(_resetInactivityTimer);
    isVideoPlayingNotifier.removeListener(_resetInactivityTimer);
    _inactivityTimer?.cancel();
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _loadInitialSettings() async {
    final prefs = await SharedPreferences.getInstance();
    autoHideNotifier.value = prefs.getInt(_autoHideTimeoutKey) ?? 5; // 5 minutos por defecto
    _resetInactivityTimer();
  }
  // Intercepta cualquier tecla presionada sin bloquearla
  bool _handleKeyEvent(KeyEvent event) {
    _resetInactivityTimer();
    return false; 
  }
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    // Solo activamos la bomba de tiempo si la app es visible, está desbloqueada y el ajuste es mayor a 0
    if (autoHideNotifier.value > 0 && _isWindowVisible && _isAuthenticated && !isVideoPlayingNotifier.value) {
      _inactivityTimer = Timer(Duration(seconds: autoHideNotifier.value), _autoHideApp);
    }
  }
  void _autoHideApp() {
    if (_isWindowVisible) {
      appVisibilityNotifier.value = false; // Duerme las carpetas
      setState(() {
        _isWindowVisible = false;
        _isAuthenticated = false; // Exigir PIN al volver
      });
      windowManager.hide(); // Ocultar a la bandeja
    }
  }

  Future<void> _initTray() async {
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png',
    );
    await trayManager.setToolTip('Galería Vórtice');
  }

  @override
  void onTrayIconMouseDown() {
    appVisibilityNotifier.value = true; // Despierta las carpetas
    setState(() {
      _isAuthenticated = false;
      _isWindowVisible = true;
    });
    windowManager.show();
  }

  @override
  void onTrayIconRightMouseDown() async {
    final isPaused = _mainVaultKey.currentState?.isWatcherPaused ?? false;
    Menu menu = Menu(items: [
      MenuItem(key: 'show_window', label: 'Mostrar Aplicación'),
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
      onTrayIconMouseDown();
    } else if (menuItem.key == 'toggle_watcher') {
      _mainVaultKey.currentState?.toggleWatcher();
    } else if (menuItem.key == 'exit_application') {
      windowManager.destroy();
    }
  }

  @override
  void onWindowMinimize() {
    appVisibilityNotifier.value = false; // Duerme las carpetas
  }

  @override
  void onWindowRestore() {
    appVisibilityNotifier.value = true; // Despierta las carpetas
  }

  @override
  void onWindowClose() async {
    final prefs = await SharedPreferences.getInstance();
    final closeAction = prefs.getString('close_action') ?? 'minimize';

    if (closeAction == 'exit') {
      windowManager.destroy(); 
    } else {
      appVisibilityNotifier.value = false; // Duerme las carpetas
      setState(() {
        _isWindowVisible = false;
        _isAuthenticated = false; 
      });
      windowManager.hide();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 1. APLICACIÓN PRINCIPAL (Congelada si no hay PIN o ventana)
        Offstage(
          offstage: !_isWindowVisible || !_isAuthenticated,
          // NUEVO: Listener captura todo movimiento o clic de ratón/trackpad
          child: ExcludeFocus(
            excluding: !_isWindowVisible || !_isAuthenticated, // Si está bloqueado, ignora el teclado
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _resetInactivityTimer(),
              onPointerMove: (_) => _resetInactivityTimer(),
              onPointerHover: (_) => _resetInactivityTimer(),
              onPointerSignal: (_) => _resetInactivityTimer(), 
              child: widget.navigatorChild, 
            ),
          ),
        ),

        // 2. ESCUDOS
        if (!_isWindowVisible)
          const BackgroundServiceScreen()
        else if (!_isAuthenticated)
          HeroControllerScope.none(
            child: Navigator(
              onGenerateRoute: (settings) => MaterialPageRoute(
                builder: (context) => PinAuthScreen(
                  onAuthenticated: () {
                    setState(() {
                      _isAuthenticated = true;
                    });
                    _resetInactivityTimer();
                    _mainVaultKey.currentState?.restoreFocus();
                  },
                  setAuthenticated: (value) {
                    setState(() {
                      _isAuthenticated = value;
                    });
                    if (value) {
                      _resetInactivityTimer();
                      _mainVaultKey.currentState?.restoreFocus(); 
                    }
                  },
                ),
              ),
            ),
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

  bool _isDraggingExternal = false;

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

  // Variables para el proceso de restauración
  final ValueNotifier<bool> _isRestoringNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<double> _restoreProgressNotifier = ValueNotifier<double>(0.0);
  int _totalRestoreItems = 0;
  int _processedRestoreItems = 0;

  // --- STATE PARA IMPORTACIÓN ---
  final ValueNotifier<bool> _isImportingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<double> _importProgressNotifier = ValueNotifier<double>(0.0);
  int _totalImportItems = 0;
  int _processedImportItems = 0;

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
    appVisibilityNotifier.addListener(_onVisibilityChanged);
  }

  void _forceWindowsToReclaimRAM() {
    if (Platform.isWindows) {
      try {
        final kernel32 = DynamicLibrary.open('kernel32.dll');
        final getCurrentProcess = kernel32.lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
        final setProcessWorkingSetSize = kernel32.lookupFunction<Int32 Function(IntPtr, IntPtr, IntPtr), int Function(int, int, int)>('SetProcessWorkingSetSize');

        final processHandle = getCurrentProcess();
        // Pasar -1 y -1 le ruega a Windows que limpie la memoria asignada al proceso
        setProcessWorkingSetSize(processHandle, -1, -1);
      } catch (e) {
        debugPrint("No se pudo reducir la RAM nativa: $e");
      }
    }
  }

  void pause() {
    print("VaultExplorer pausado. Liberando recursos de UI...");
    setState(() {
      _isPaused = true;
      // Vaciamos las listas grandes para liberar RAM.
      //_vaultContents.clear();
      //_filteredVaultContents.clear();
      //_itemKeys.clear();
      //_selectedItems.clear();
      // Le pedimos al servicio de miniaturas que limpie su caché de memoria RAM.
      _thumbnailService.clearMemoryCache();
      // NO cancelamos el _watcherSubscription, ya que debe seguir funcionando.
    });
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    WidgetsBinding.instance.handleMemoryPressure();

    //// Le damos a Flutter un respiro de 100ms para que termine de destruir 
    // los widgets antes de ordenarle a Windows que nos quite la RAM.
    Future.delayed(const Duration(milliseconds: 100), () {
      _forceWindowsToReclaimRAM();
    });

  }

  void resume() {
    if (!mounted) return; // <-- Agregamos seguridad
    print("VaultExplorer reanudado. Recargando contenido...");
    setState(() {
      _isPaused = false; 
    });
    // Quitamos el "if (_vortexPath != null)" para que siempre recargue la UI
    // sin importar si es la raíz o una subcarpeta.
    _loadVaultContents(quiet: true);
  }

  // --- NUEVO: Método para recuperar el foco tras desbloquear ---
  void restoreFocus() {
    // Le damos 50ms a Flutter para que quite el ExcludeFocus y dibuje la galería
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) {
        if (_isSearchVisible) {
          _searchFocusNode.requestFocus(); // Si estaba buscando, foco al buscador
        } else {
          _gridFocusNode.requestFocus();   // Si no, foco a la cuadrícula
        }
      }
    });
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

    // Leemos los valores más recientes de la configuración
    final sortIndex = prefs.getInt(_sortCriteriaKey) ?? SortCriteria.date.index;
    final sortAscending = prefs.getBool(_sortAscendingKey) ?? true;
    final showRatings = prefs.getBool(_showRatingsKey) ?? true;
    final showTags = prefs.getBool(_showTagsKey) ?? true;

    // NUEVO: Solo leemos el disco si de verdad cambiaste la forma de ordenar
    bool needsReload = false;
    if (_currentSortCriteria.index != sortIndex || _sortAscending != sortAscending) {
      needsReload = true;
    }

    // Actualizamos el estado visual instantáneamente (estrellas, tamaño, etc.)
    setState(() {
      _currentSortCriteria = SortCriteria.values[sortIndex];
      _sortAscending = sortAscending;
      _showRatingsOnThumbnail = showRatings;
      _showTagsCountOnThumbnail = showTags;
    });

    // Si el ordenamiento cambió, entonces sí leemos el disco duro
    if (needsReload) {
      await _loadVaultContents();
    }
  }

  /// Mueve una carpeta entera desde el Vórtice a la bóveda.
  Future<void> _absorbDirectory(Directory sourceDir, [Directory? targetParentDir]) async {
    final destParent = targetParentDir ?? _vaultRootDir;
    final dirName = p.basename(sourceDir.path);
    
    // 1. Creamos la carpeta en la Bóveda
    final newDirPath = await _getUniquePath(destParent, dirName);
    final newDir = Directory(newDirPath);
    await newDir.create();

    final contents = await sourceDir.list().toList();
    
    // 2. Procesamos el contenido individualmente
    for (final entity in contents) {
      if (entity is File) {
        if (_isSupportedFile(entity.path)) {
          // Si es válido, lo mandamos a encriptar y a la base de datos
          await _absorbImage(entity, reloadUI: false, targetDir: newDir);
        } else {
          // Si es un archivo oculto del sistema (basura), lo destruimos
          final name = p.basename(entity.path).toLowerCase();
          if (name == 'desktop.ini' || name == 'thumbs.db' || name == '.ds_store') {
            try { await entity.delete(); } catch (_) {}
          }
        }
      } else if (entity is Directory) {
        // Si hay una carpeta adentro de la carpeta, usamos recursividad
        await _absorbDirectory(entity, newDir);
      }
    }

    // 3. Destruimos la carpeta original
    // Si contiene archivos que el usuario quiere conservar (como PDFs o Word), 
    // el borrado fallará intencionalmente, protegiendo los documentos del usuario.
    try {
      await sourceDir.delete();
    } catch (e) {
      debugPrint("La carpeta original no se borró porque contiene archivos no soportados.");
    }
  }

  /// Revisa recursivamente si una carpeta es válida para ser absorbida.
  Future<bool> _isDirectoryValidForAbsorption(Directory dir) async {
    final List<FileSystemEntity> contents = await dir.list().toList();

    if (contents.isEmpty) return true;// Las carpetas vacías también son válidas

    for (final entity in contents) {
      if (entity is File) {
        // Usamos _isSupportedFile para aceptar también videos
        if (_isSupportedFile(entity.path)) {
          return true; // Encontramos oro, la carpeta es válida
        }
      } else if (entity is Directory) {
        final isSubDirValid = await _isDirectoryValidForAbsorption(entity);
        if (isSubDirValid) return true;
      }
    }
    return false; // Solo se rechaza si está llena de archivos no multimedia (ej. PDFs)
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
    appVisibilityNotifier.removeListener(_onVisibilityChanged);
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
    _isRestoringNotifier.dispose();
    _restoreProgressNotifier.dispose();
    _isImportingNotifier.dispose();
    _importProgressNotifier.dispose();
    super.dispose();
  }

  Future<int> _countItems(Directory dir) async {
    int count = 0;
    await for (final _ in dir.list(recursive: true)) {
      count++;
    }
    return count;
  }

  void _onVisibilityChanged() {
    if (!mounted) return;
    if (appVisibilityNotifier.value) {
      resume();
    } else {
      pause();
    }
  }

  // --- Window and Tray Listener Methods ---
  /*@override
  void onWindowClose() async {
    // <-- Convertir a async
    // --- LÓGICA MODIFICADA ---
    final prefs = await SharedPreferences.getInstance();
    final closeAction =
        prefs.getString(_closeActionKey) ?? CloseAction.minimize.name;

    if (closeAction == CloseAction.exit.name) {
      windowManager.destroy(); // Cierra la app
    } else {
      //pause();
      windowManager.hide(); // Minimiza a la bandeja
    }
    // --- FIN DE LA MODIFICACIÓN ---
  }*/

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
      
      // NUEVO: Verificamos que sea la carpeta PRINCIPAL antes de encender el Watcher
      if (widget.currentDirectory == null) {
        await _absorbInitialVortexContents(Directory(path), reloadUI: false);
        _startWatcher(path);
      }
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

    final Map<String, int> sizeCache = {};
    final Map<String, String> nameCache = {};
    final Map<String, int> timeCache = {};

    if (contents.isNotEmpty) {
      final List<Future<void>> ioTasks = []; // Lista de tareas asíncronas

      for (final entity in contents) {
        if (entity is File) {
          if (_currentSortCriteria == SortCriteria.size) {
            // Usamos length() asíncrono y lo mandamos a la lista de tareas
            ioTasks.add(entity.length().then((size) => sizeCache[entity.path] = size));
          } else if (_currentSortCriteria == SortCriteria.name) {
            nameCache[entity.path] =
                _getDeobfuscatedName(p.basename(entity.path)).toLowerCase();
          } else if (_currentSortCriteria == SortCriteria.date) {
            final id = p.relative(entity.path, from: _vaultRootDir.path);
            int dbTime =
                _metadataService.getMetadataForImage(id).addedTimestamp;

            if (dbTime == 0) {
              // Usamos lastModified() asíncrono
              ioTasks.add(entity.lastModified().then((date) {
                timeCache[entity.path] = date.millisecondsSinceEpoch;
              }).catchError((_) {}));
            } else {
              timeCache[entity.path] = dbTime;
            }
          }
        }
      }
      await Future.wait(ioTasks);
    }

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
      final currentPaths = contents.map((e) => e.path).toSet();
      _itemKeys.removeWhere((key, _) => !currentPaths.contains(key));
      
      _isLoading = false;
      _shiftSelectionAnchorIndex = null;
    });

    _thumbnailService.bulkGenerate(contents);
  }

  Future<bool> _waitUntilFileIsReady(File file) async {
    int lastSize = -1;
    int stableCount = 0;
    
    // NUEVO: Variables para evitar bucles infinitos
    int attempts = 0; 
    // 7200 intentos * 500ms = 1 hora de espera máxima.
    // Si una descarga se pausa por más de 1 hora, la ignoramos.
    const int maxAttempts = 7200; 

    while (attempts < maxAttempts) {
      attempts++;
      try {
        if (!await file.exists()) {
          return false; // El archivo fue borrado o la descarga se canceló
        }

        int currentSize = await file.length();

        // Verificamos si el tamaño es mayor a 0 y no ha cambiado
        if (currentSize == lastSize && currentSize > 0) {
          stableCount++;
          // AUMENTAMOS LA EXIGENCIA: 6 comprobaciones (3 segundos estables)
          if (stableCount >= 6) {
            RandomAccessFile? raf;
            try {
              raf = await file.open(mode: FileMode.append);
              await raf.close();
              return true; // ¡100% listo y liberado por Windows!
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
    
    // NUEVO: Si llega aquí, la descarga se atascó o se pausó demasiado tiempo.
    return false;
  }

  void _startWatcher(String path) {
    _watcherSubscription?.cancel();
    final watcher = DirectoryWatcher(path);

    _watcherSubscription = watcher.events.listen((event) async {
      if ((event.type == ChangeType.ADD || event.type == ChangeType.MODIFY) &&
          _isSupportedFile(event.path)) {
        final pathKey = event.path.toLowerCase();

        // Si ya estamos vigilando este archivo, lo ignoramos para no saturar
        if (_processingFiles.contains(pathKey)) return;

        final file = File(event.path);
        _processingFiles.add(pathKey);

        try {
          final isReady = await _waitUntilFileIsReady(file);

          if (isReady && mounted) {
            // --- NUEVA LÓGICA: DETECTAR Y RECREAR CARPETAS ---
            final relativePath = p.relative(file.path, from: path);
            final dirname = p.dirname(relativePath);
            Directory? targetDir;

            // Si el archivo está dentro de una subcarpeta (ej: "Pruebas Seguras/foto.jpg")
            if (dirname != '.') {
              targetDir = Directory(p.join(_vaultRootDir.path, dirname));
              if (!await targetDir.exists()) {
                await targetDir.create(recursive: true);
              }
            }

            // Pasamos el targetDir para que respete su carpeta destino en la bóveda
            await _absorbImage(file, targetDir: targetDir);

            // --- NUEVA LÓGICA: LIMPIAR LA CARPETA VACÍA EN EL VÓRTICE ---
            if (dirname != '.') {
              final sourceDir = Directory(p.dirname(file.path));
              try {
                if (await sourceDir.exists()) {
                  // Revisamos qué queda dentro de la carpeta
                  final remaining = await sourceDir.list().toList();
                  bool canDelete = true;
                  
                  for (var item in remaining) {
                    if (item is File) {
                      final name = p.basename(item.path).toLowerCase();
                      // Si hay algo que no sea basura del sistema, NO borramos la carpeta
                      if (name != 'desktop.ini' && name != 'thumbs.db' && name != '.ds_store') {
                        canDelete = false; 
                      }
                    } else {
                      canDelete = false; // Hay otra subcarpeta adentro
                    }
                  }
                  
                  // Si solo quedaba basura, destruimos la carpeta entera sin dejar rastro
                  if (canDelete) {
                    await sourceDir.delete(recursive: true);
                  }
                }
              } catch (_) {
                // Ignoramos si Windows la tiene bloqueada momentáneamente
              }
            }
          }
        } finally {
          _processingFiles.remove(pathKey);
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
        showGlassSnackBar(context, 'Vigilancia del Vórtice pausada.', icon: Icons.pause_circle_outline, iconColor: Colors.amber);
      }
    } else {
      if (_vortexPath != null) {
        await _absorbInitialVortexContents(Directory(_vortexPath!),
            reloadUI: false);
        _startWatcher(_vortexPath!);
        await _loadVaultContents(quiet: true);

        if (mounted) {
          showGlassSnackBar(context, 'Vigilancia del Vórtice reanudada.', icon: Icons.play_circle_outline, iconColor: Colors.green);
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
    int retries = 4; // Le damos 4 intentos si algún proceso lo tiene ocupado
    while (retries > 0) {
      try {
        await sourceFile.rename(newPath);
        return; // ¡Éxito a la primera usando el motor nativo del disco!
      } catch (e) {
        try {
          // Fallback manual: Copiar y borrar
          final newFile = await sourceFile.copy(newPath);
          if (await newFile.exists()) {
            
            // --- NUEVO: PRUEBA DE INTEGRIDAD DE BYTES ---
            final sourceSize = await sourceFile.length();
            final newSize = await newFile.length();
            
            if (sourceSize == newSize) {
              // Son clones perfectos, es seguro borrar el original
              await sourceFile.delete();
              return; 
            } else {
              // La copia se interrumpió a medias (ej. falta de espacio en disco)
              await newFile.delete(); // Borramos la copia corrupta
              throw Exception("La copia falló la prueba de integridad (tañamos diferentes).");
            }
          }
        } catch (copyDeleteError) {
          retries--;
          if (retries == 0) {
            // Si falló definitivamente, borramos la copia a medias para no dejar basura
            if (await File(newPath).exists()) await File(newPath).delete();
            throw Exception("El archivo está bloqueado o dañado: $copyDeleteError");
          }
          // Esperamos un cuarto de segundo a que se libere antes de volver a intentar
          await Future.delayed(const Duration(milliseconds: 250));
        }
      }
    }
  }

  Future<void> _absorbImage(File imageFile, {bool reloadUI = true, Directory? targetDir}) async {
    if (!await imageFile.exists()) return;

    // 1. Conservamos el nombre original exactamente como viene
    final String originalFileName = p.basename(imageFile.path);

    // 2. Solo aplicamos la ofuscación (.vtx)
    String newName = _obfuscateName(originalFileName);

    final destinationDir = targetDir ?? _vaultRootDir;
    final newPathInVault = await _getUniquePath(destinationDir, newName);

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

        // 1. Leemos los segundos configurados por el usuario (8 por defecto)
        final prefs = await SharedPreferences.getInstance();
        final delaySeconds = prefs.getInt(_notificationDelayKey) ?? 8;

        // 2. Usamos esa variable dinámica para el Timer
        _notificationTimer = Timer(Duration(seconds: delaySeconds), () async {
          final showNotif = prefs.getBool(_showNotificationsKey) ?? true;

          if (showNotif && _backgroundAbsorbedCount > 0) {
            final String mensaje = "Se han enviado $_backgroundAbsorbedCount archivo(s) a la bóveda.";
            _backgroundAbsorbedCount = 0;

            final notification = LocalNotification(
              identifier: 'gvortex_absorb_notif', 
              title: "GVortex",
              body: mensaje,
            );
            await notification.show();
          }
        });
      } else if (reloadUI) {
        await _loadVaultContents(quiet: true);
      }
    } catch (e) {
      debugPrint("Error al absorber ${imageFile.path}: $e");
    }
  }

  Future<void> _absorbInitialVortexContents(Directory vortexDir,
      {bool reloadUI = true}) async {
    if (!await vortexDir.exists()) return;

    final contents = await vortexDir.list().toList();

    // Encender la barra de progreso
    _totalImportItems = contents.length;
    _processedImportItems = 0;
    if (_totalImportItems > 0) {
      _isImportingNotifier.value = true;
      _importProgressNotifier.value = 0.0;
    }

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
            showGlassSnackBar(context, 'Carpeta "${p.basename(entity.path)}" ignorada: contiene archivos no válidos o está vacía.', icon: Icons.warning_amber_rounded, iconColor: Colors.amber);
          }
        }
      }
      
      // Actualizar progreso visual
      _processedImportItems++;
      if (_totalImportItems > 0) {
        _importProgressNotifier.value = _processedImportItems / _totalImportItems;
      }
      
      // --- LA MAGIA ESTÁ AQUÍ ---
      // Le damos 10 milisegundos de respiro a Flutter para que dibuje el porcentaje en la pantalla.
      await Future.delayed(const Duration(milliseconds: 10));
    }

    // Apagar la barra de progreso al terminar
    _isImportingNotifier.value = false;

    if (reloadUI) {
      await _loadVaultContents();
    }
  }

  Future<void> _moveEntity(FileSystemEntity entity, Directory destination) async {
    try {
      final entityName = p.basename(entity.path);
      final newPath = await _getUniquePath(destination, entityName);

      final oldId = p.relative(entity.path, from: _vaultRootDir.path);
      final newId = p.relative(newPath, from: _vaultRootDir.path);

      if (entity is File) {
        await _thumbnailService.renameThumbnail(entity.path, newPath);
        await _moveFileRobustly(entity, newPath);
      } else {
        bool moved = false;
        for (int i = 0; i < 3; i++) {
          try {
            await entity.rename(newPath);
            moved = true;
            break;
          } catch (e) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }
        if (!moved) throw Exception("La carpeta está en uso.");
      }

      // 3. La base de datos se actualiza (Aquí se salva tu fecha y etiquetas)
      await _metadataService.updateImagePath(oldId, newId);

      // --- NUEVO: Exorcizar al fantasma visual ---
      if (mounted) {
        setState(() {
          // Quitamos la entidad completa, no solo su ruta (path)
          _selectedItems.remove(entity);
        });
        
        // Le pedimos a la app que vuelva a escanear la carpeta actual de inmediato.
        // Al hacerlo, se dará cuenta de que el archivo ya no está y lo borrará de la pantalla.
        await _loadVaultContents(quiet: true);
      }

    } catch (e) {
      debugPrint("Error moving entity: $e");
      if (mounted) {
        showGlassSnackBar(context, 'Error al mover: $e', icon: Icons.error_outline, iconColor: Colors.redAccent);
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
    showGlassSnackBar(context, '${_VaultExplorerScreenState._clipboard.length} elemento(s) cortado(s).', icon: Icons.content_cut, iconColor: Colors.white);
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
      _selectedItems.clear(); // <-- NUEVO: Suelta la selección fantasma
      _shiftSelectionAnchorIndex = null; // <-- NUEVO: Limpia el ancla
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

    // NUEVO: Transición personalizada sin Hero
    final returnedIndex = await Navigator.push<int>(
      context,
      PageRouteBuilder(
        // Duración de la animación (300ms es el estándar fluido)
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        // Color de fondo oscuro mientras hace la transición
        opaque: false, 
        barrierColor: Colors.black, 
        
        pageBuilder: (context, animation, secondaryAnimation) => FullScreenImageViewer(
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
              _scrollToFocusedItem(animate: false);
            }
          },
        ),
        
        // AQUÍ DEFINIMOS LA MAGIA DE LA ANIMACIÓN
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // 1. Efecto de opacidad (Fade in)
          final fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          );

          // 2. Efecto de acercamiento (Zoom in desde 80% al 100%)
          final scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          );

          return FadeTransition(
            opacity: fadeAnimation,
            child: ScaleTransition(
              scale: scaleAnimation,
              child: child,
            ),
          );
        },
      ),
    );

    // LIMPIEZA DE MEMORIA: Al cerrar el visor, forzamos a Flutter a liberar las imágenes que ya no se necesitan.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    WidgetsBinding.instance.handleMemoryPressure();

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
        ).then((_) async {
          await _syncPreferences();
          // La UI ya no se trabará, incluso si esto se ejecuta mientras
          // la animación de la pantalla todavía se está deslizando.
          if (mounted) {
            await _loadVaultContents(quiet: true);
          }
        });
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
    // 1. Obtenemos el tamaño real y exacto del contenedor de la cuadrícula
    final RenderBox? gridBox = _gridDetectorKey.currentContext?.findRenderObject() as RenderBox?;
    
    if (gridBox != null) {
      // 2. El tamaño exacto de tu barra: 12.0 (thickness) + 4.0 (crossAxisMargin) = 16.0
      // Si cambias el grosor de tu barra en el futuro, solo ajustas este valor.
      const double scrollbarRealWidth = 12.0; 
      
      // 3. Verificamos si el clic cayó exactamente dentro de la franja de la barra
      if (details.localPosition.dx > gridBox.size.width - scrollbarRealWidth) {
        _marqueeStart = null;
        return; // Ignoramos el Marquee, la barra gana el clic
      }
    }

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
        showGlassSnackBar(context, 'Error al procesar la carpeta: $e', icon: Icons.error_outline, iconColor: Colors.redAccent);
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
          await _moveFileRobustly(entity, finalUniquePath);
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
          showGlassSnackBar(context, 'Error al renombrar: $e', icon: Icons.error_outline, iconColor: Colors.redAccent);
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
      
      body: DropRegion(
        formats: Formats.standardFormats, // Acepta archivos y URIs
        onDropOver: (DropOverEvent event) {
          // Verifica si lo que están arrastrando son archivos
          if (event.session.items.any((item) => item.canProvide(Formats.fileUri))) {
            if (mounted && !_isDraggingExternal) {
              setState(() => _isDraggingExternal = true);
            }
            return DropOperation.copy;
          }
          return DropOperation.none;
        },
        onDropLeave: (DropEvent event) {
          if (mounted) setState(() => _isDraggingExternal = false);
        },
        onPerformDrop: _handleSuperDrop, // <-- Tu nueva función
        child: Stack(
          children: [
            Column(
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
            
            // Tus barras flotantes originales
            _buildFloatingProgressBar(),
            _buildRestoreProgressBar(),
            _buildImportProgressBar(),

            // --- NUEVO: CAPA VISUAL DE DRAG & DROP ---
            if (_isDraggingExternal)
              Positioned.fill(
                child: ClipRRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      color: const Color(0xFF0A84FF).withOpacity(0.15), // Azul tenue macOS
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
                          decoration: BoxDecoration(
                            color: const Color(0xFF252525).withOpacity(0.85),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFF0A84FF), width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.4),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              )
                            ],
                          ),
                          child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.download_rounded, size: 60, color: Color(0xFF0A84FF)),
                              SizedBox(height: 16),
                              Text(
                                'Suelta para importar a la Bóveda',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
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
    return Center( // <-- Envolvemos todo en un Center
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center, // <-- Asegura el centrado horizontal interno
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
      ),
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
                  return KeyEventResult.handled; 
                }
                return KeyEventResult.ignored;
              },
              // 1. Apagamos la barra duplicada de Flutter
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: DesktopScrollbar( // O RawScrollbar
                  controller: _scrollController,
                  thumbVisibility: true,
                  trackVisibility: true,
                  
                  // --- DISEÑO PÍLDORA PEGADA AL BORDE ---
                  thickness: 10.0, // Define el grosor IGUAL para la barra y el carril
                  radius: const Radius.circular(20.0), // Mantiene las puntas de píldora
                  crossAxisMargin: 0.0, // <-- Cero margen: la pega totalmente al lateral
                  mainAxisMargin: 0.0, // Mantiene el margen arriba y abajo para que no choque con los topes
                  
                  // --- COLORES ---
                  thumbColor: Colors.white.withOpacity(0.4), 
                  trackColor: Colors.white.withOpacity(0.05), 
                  trackBorderColor: Colors.transparent, // Quita el borde del carril para que se vea limpio
                  
                  minThumbLength: 50.0,
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
          )
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
      // ¡CORRECCIÓN AQUÍ!
      // Usamos tu función para leer la extensión real encriptada en el nombre (.vtx)
      final bool isVideo = _isVideo(firstItem.path);

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
      showGlassSnackBar(context, '${_selectedItems.length} elemento(s) exportado(s) con éxito a ${exportRootDir.path}.', icon: Icons.download_done);
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
        showGlassSnackBar(context, 'Archivo exportado con éxito a ${exportRootDir.path}.', icon: Icons.download_done);
      }
    } catch (e) {
      if (mounted) {
        showGlassSnackBar(context, 'Error al exportar: $e', icon: Icons.error_outline, iconColor: Colors.redAccent);
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

    _totalRestoreItems = await _countItems(_vaultRootDir);
    _processedRestoreItems = 0;
    if (_totalRestoreItems > 0) {
      _isRestoringNotifier.value = true;
      _restoreProgressNotifier.value = 0.0;
    }

    setState(() => _isLoading = true);

    await _watcherSubscription?.cancel();
    _watcherSubscription = null;

    // Ejecuta la función recursiva que ya tiene la lógica de limpiar nombres
    await _restoreDirectoryContents(_vaultRootDir, destinationDir);
    _isRestoringNotifier.value = false;

    await _clearVortexPathSetting();
    await _loadVaultContents();

    setState(() => _isLoading = false);
    if (mounted) {
      showGlassSnackBar(context, 'Todos los archivos han sido restaurados exitosamente.', icon: Icons.settings_backup_restore);
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
        _processedRestoreItems++;
        if (_totalRestoreItems > 0) {
          _restoreProgressNotifier.value = _processedRestoreItems / _totalRestoreItems;
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
      showGlassSnackBar(context, '$count elemento(s) restaurado(s) con éxito a ${destinationDir.path}.');
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

  Widget _buildFloatingProgressBar() {
    return ValueListenableBuilder<bool>(
      // 1. Escuchamos si el motor está trabajando
      valueListenable: _thumbnailService.isGeneratingNotifier,
      builder: (context, isGenerating, child) {
        if (!isGenerating) return const SizedBox.shrink(); // Si no trabaja, es invisible

        return Positioned(
          bottom: 80.0, // Flotando justo por encima del control de zoom
          left: 0,
          right: 0,
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20.0),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF252525).withOpacity(0.85),
                    borderRadius: BorderRadius.circular(20.0),
                    border: Border.all(color: Colors.white12, width: 0.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0A84FF)), // Azul Mac
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Text(
                        'Optimizando miniaturas...',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(width: 14),
                      // 2. Escuchamos el porcentaje exacto
                      ValueListenableBuilder<double>(
                        valueListenable: _thumbnailService.progressNotifier,
                        builder: (context, progress, child) {
                          return Text(
                            '${(progress * 100).toInt()}%',
                            style: const TextStyle(
                              color: Color(0xFF0A84FF), 
                              fontSize: 13, 
                              fontWeight: FontWeight.bold
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRestoreProgressBar() {
    return ValueListenableBuilder<bool>(
      valueListenable: _isRestoringNotifier,
      builder: (context, isRestoring, child) {
        if (!isRestoring) return const SizedBox.shrink(); 

        return Positioned(
          bottom: 80.0, 
          left: 0,
          right: 0,
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20.0),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF252525).withOpacity(0.85),
                    borderRadius: BorderRadius.circular(20.0),
                    border: Border.all(color: Colors.white12, width: 0.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.redAccent), // Rojo Mac
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Text(
                        'Restaurando bóveda...',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(width: 14),
                      ValueListenableBuilder<double>(
                        valueListenable: _restoreProgressNotifier,
                        builder: (context, progress, child) {
                          return Text(
                            '${(progress * 100).toInt()}%',
                            style: const TextStyle(
                              color: Colors.redAccent, 
                              fontSize: 13, 
                              fontWeight: FontWeight.bold
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
  Widget _buildImportProgressBar() {
    return ValueListenableBuilder<bool>(
      valueListenable: _isImportingNotifier,
      builder: (context, isImporting, child) {
        if (!isImporting) return const SizedBox.shrink(); 

        return Positioned(
          bottom: 140.0, // <-- Más arriba para no pisar la de miniaturas
          left: 0,
          right: 0,
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20.0),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF252525).withOpacity(0.85),
                    borderRadius: BorderRadius.circular(20.0),
                    border: Border.all(color: Colors.white12, width: 0.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF32D74B)), // Verde Mac
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Text(
                        'Importando al Vórtice...',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(width: 14),
                      ValueListenableBuilder<double>(
                        valueListenable: _importProgressNotifier,
                        builder: (context, progress, child) {
                          return Text(
                            '${(progress * 100).toInt()}%',
                            style: const TextStyle(
                              color: Color(0xFF32D74B), 
                              fontSize: 13, 
                              fontWeight: FontWeight.bold
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // --- NUEVO: MANEJADOR DE DRAG & DROP EXTERNO CON SUPER_DRAG_AND_DROP ---
  Future<void> _handleSuperDrop(PerformDropEvent event) async {
    setState(() => _isDraggingExternal = false);

    final List<String> filePaths = [];

    // 1. Extraemos todas las rutas de los archivos arrastrados de forma asíncrona
    for (final item in event.session.items) {
      if (item.dataReader?.canProvide(Formats.fileUri) == true) {
        final completer = Completer<String?>();
        item.dataReader!.getValue<Uri>(
          Formats.fileUri,
          (uri) => completer.complete(uri?.toFilePath()),
          onError: (error) => completer.complete(null),
        );
        final path = await completer.future;
        if (path != null) {
          filePaths.add(path);
        }
      }
    }

    if (filePaths.isEmpty) return;

    // 2. Encendemos la barra de progreso usando tu lógica existente
    _totalImportItems = filePaths.length;
    _processedImportItems = 0;
    _isImportingNotifier.value = true;
    _importProgressNotifier.value = 0.0;

    // 3. Procesamos las rutas exactamente igual que antes
    for (final path in filePaths) {
      final type = FileSystemEntity.typeSync(path);

      if (type == FileSystemEntityType.file) {
        if (_isSupportedFile(path)) {
          // Si es un archivo soportado, lo absorbemos
          await _absorbImage(File(path), reloadUI: false, targetDir: _currentVaultDir);
        }
      } else if (type == FileSystemEntityType.directory) {
        final dir = Directory(path);
        // Validamos si la carpeta contiene archivos soportados
        if (await _isDirectoryValidForAbsorption(dir)) {
          await _absorbDirectory(dir, _currentVaultDir);
        } else {
          if (mounted) {
            showGlassSnackBar(
              context, 
              'Carpeta "${p.basename(dir.path)}" ignorada: vacía o sin multimedia.', 
              icon: Icons.warning_amber_rounded, 
              iconColor: Colors.amber
            );
          }
        }
      }

      // Actualizar progreso visual
      _processedImportItems++;
      _importProgressNotifier.value = _processedImportItems / _totalImportItems;
      
      // Respiro para Flutter
      await Future.delayed(const Duration(milliseconds: 10));
    }

    // Apagar la barra de progreso al terminar
    _isImportingNotifier.value = false;
    
    // Recargar la interfaz para mostrar los nuevos archivos
    await _loadVaultContents();
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
      // 1. EL HERO YA NO ESTÁ AQUÍ AFUERA
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8.0),
          border: Border.all(
            color: widget.isSelected ? const Color(0xFF0A84FF) : Colors.transparent,
            width: 2.5, 
          ),
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
                    child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.0)),
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
                          child: const Center(child: Icon(Icons.broken_image, color: Colors.white54, size: 40)),
                        );
                      },
                      gaplessPlayback: true,
                    ),

                    // CAPA DEL BOTÓN DE PLAY (Solo si es video)
                    if (isVideo) ...[
                      Container(color: Colors.black26), 
                      const Center(child: Icon(Icons.play_circle_fill, color: Colors.white, size: 48)),
                    ],

                    // Sombreado inferior
                    Positioned(
                      bottom: 0, left: 0, right: 0,
                      height: widget.extent * 0.35,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter, end: Alignment.topCenter,
                            colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                          ),
                        ),
                      ),
                    ),

                    // Estrellas
                    if (widget.showRatings && rating > 0)
                      Positioned(
                        bottom: 4, right: 4,
                        child: RatingStarsDisplay(rating: rating, iconSize: widget.extent / 10),
                      ),

                    // Contador de Etiquetas
                    if (widget.showTagsCount && tagsCount > 0)
                      Positioned(
                        bottom: 4, left: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5.0, vertical: 2.0),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6), 
                            borderRadius: BorderRadius.circular(4.0),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.label_outline, size: widget.extent / 12, color: Colors.white70),
                              const SizedBox(width: 3),
                              Text('$tagsCount', style: TextStyle(color: Colors.white70, fontSize: widget.extent / 12, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                  ],
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
  final GlobalKey _ratingButtonFloatingKey = GlobalKey();
  OverlayEntry? _ratingOverlay; // Para guardar el menú flotante
  bool _isTrueFullScreen = false;
  bool _showNavigation = true;
  final FocusNode _viewerFocusNode = FocusNode();
  Timer? _hideTimer;
  bool _wasMaximized = false;

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
      if (!_wasMaximized) {
        await windowManager.unmaximize();
      }
      
      
      // 3. Devolvemos el foco al teclado
      _viewerFocusNode.requestFocus();
      if (Platform.isWindows || Platform.isMacOS) {
        await windowManager.focus();
      }
    } else {
      _wasMaximized = await windowManager.isMaximized();
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
      if (!_wasMaximized) {
        await windowManager.unmaximize();
      }
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
    // Calculamos un tamaño de precarga dinámico basado en el ancho de la pantalla, con límites para no sobrecargar la memoria
    final double screenWidth = MediaQuery.of(context).size.width;
    final int lowResWidth = (screenWidth / 1.5).clamp(400.0, 1200.0).toInt();
    // Precargar la imagen SIGUIENTE
    if (index + 1 < widget.imageFiles.length) {
      final nextFile = widget.imageFiles[index + 1];
      if (!_isVideo(nextFile.path)) {
        precacheImage(ResizeImage(FileImage(nextFile), width: lowResWidth), context);
      }
    }
    
    // Precargar la imagen ANTERIOR
    if (index - 1 >= 0) {
      final prevFile = widget.imageFiles[index - 1];
      if (!_isVideo(prevFile.path)) {
        precacheImage(ResizeImage(FileImage(prevFile), width: lowResWidth), context);
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
      BuildContext context, String imageId, int currentRating, GlobalKey anchorKey) {
    if (_ratingOverlay != null) return;

    // NUEVO: Usamos el anchorKey en lugar de _ratingButtonKey
    final RenderBox? button =
        anchorKey.currentContext?.findRenderObject() as RenderBox?;
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
                      barrierColor: Colors.transparent,
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
                  // NUEVO: Le pasamos su llave aquí al final
                  onPressed: () => _showFullScreenRatingMenu(
                      context, imageId, currentRating, _ratingButtonKey),
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
                    final bool isCurrentPage = index == _currentIndex;

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
                        onPlayingStateChanged: (isPlaying) {
                          isVideoPlayingNotifier.value = isPlaying;
                        },
                      );
                    }
                    // Para imágenes, aplicamos la lógica de precarga y el sistema de ocultar/mostrar la UI
                    final double screenWidth = MediaQuery.of(context).size.width;
                    final int lowResWidth = (screenWidth / 1.5).clamp(400.0, 1200.0).toInt();
                    return _InteractiveImageItem(
                      imageFile: imageFile,
                      isCurrentPage: isCurrentPage,
                      lowResWidth: lowResWidth,
                      onTap: () => _wakeUpUI(toggle: true),
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
                  if (_isTrueFullScreen)
                  Positioned(
                    top: 20,
                    right: 20,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 300),
                      opacity: _showNavigation ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !_showNavigation,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Botón de Etiquetas Flotante
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.5),
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                icon: const Icon(Icons.label_outline, color: Colors.white),
                                tooltip: 'Etiquetas',
                                onPressed: () {
                                  showDialog(
                                    context: context,
                                    barrierColor: Colors.transparent,
                                    builder: (context) => TagEditorDialog(
                                      imageIds: [imageId],
                                      metadataService: widget.metadataService,
                                    ),
                                  ).then((_) => setState(() {})); 
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Botón de Estrellas Flotante
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.5),
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                key: _ratingButtonFloatingKey, // Usamos la llave nueva
                                icon: currentRating > 0
                                    ? const Icon(Icons.star, color: Colors.amber)
                                    : const Icon(Icons.star_outline, color: Colors.white),
                                tooltip: 'Calificación',
                                onPressed: () => _showFullScreenRatingMenu(
                                    context, imageId, currentRating, _ratingButtonFloatingKey),
                              ),
                            ),
                          ],
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
  final FocusNode _pinFocusNode = FocusNode();
  String _tempPin = '';
  String? _errorMessage;
  int _pinLength = 0;
  Timer? _focusTimer;

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
    final prefs = await SharedPreferences.getInstance();
    final closeAction =
        prefs.getString(_closeActionKey) ?? CloseAction.minimize.name;

    if (closeAction == CloseAction.exit.name) {
      windowManager.destroy();
    } else {
      windowManager.hide();
      widget.setAuthenticated(
          true);
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _pinController.dispose();
    _pinFocusNode.dispose();
    _focusTimer?.cancel();
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
        _pinFocusNode.requestFocus();
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
          _pinFocusNode.requestFocus();
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
          _pinFocusNode.requestFocus();
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
            focusNode: _pinFocusNode,
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
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => _pinFocusNode.requestFocus(),
        child: Center(
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
                  const SizedBox(height: 55)
                else if (useBoxesUI)
                  _buildPinInputArea()
                else
                  SizedBox(
                    width: 200,
                    child: TextField(
                      controller: _pinController,
                      focusNode: _pinFocusNode,
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
  int _notificationDelay = 8;
  int _autoHideSeconds = 300;
  bool _isLoading = true;
  bool _showRatings = true;
  bool _showTags = true;

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
    final notifDelay = prefs.getInt(_notificationDelayKey) ?? 8;
    final autoHide = prefs.getInt(_autoHideTimeoutKey) ?? 300;

    if (mounted) {
      setState(() {
        _closeAction = CloseAction.values.firstWhere(
          (e) => e.name == closeActionName,
          orElse: () => CloseAction.minimize,
        );
        _startup = startup;
        _showNotifications = showNotif;
        _notificationDelay = notifDelay;
        _autoHideSeconds = autoHide;
        autoHideNotifier.value = autoHide;
        _showRatings = prefs.getBool(_showRatingsKey) ?? true;
        _showTags = prefs.getBool(_showTagsKey) ?? true;
        _isLoading = false;
      });
    }
  }

  Future<void> _setNotificationDelay(double value) async {
    setState(() => _notificationDelay = value.toInt());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_notificationDelayKey, value.toInt());
  }

  Future<void> _setAutoHide(int? value) async {
    if (value == null) return;
    setState(() => _autoHideSeconds = value);
    autoHideNotifier.value = value; // Sincroniza al instante con el AuthWrapper
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_autoHideTimeoutKey, value);
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
        showGlassSnackBar(
          context, 
          value ? 'Inicio automático activado.' : 'Inicio automático desactivado.', 
          icon: value ? Icons.toggle_on : Icons.toggle_off
        );
      }
    } catch (e) {
      // Si algo falla (ej. permisos), revertimos el switch
      if (mounted) {
        setState(() => _startup = !value);
        showGlassSnackBar(context, 'Error al cambiar el inicio automático: $e', icon: Icons.error_outline, iconColor: Colors.redAccent);
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
                  padding: EdgeInsets.only(left: 16, bottom: 8, top: 8),
                  child: Text('SEGURIDAD', style: TextStyle(color: Colors.white54, fontSize: 11)),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.lock_clock, color: Color(0xFF0A84FF)),
                    title: const Text('Bloqueo por inactividad', style: TextStyle(fontSize: 13)),
                    subtitle: const Text('Ocultar en la bandeja si no hay interacción', style: TextStyle(fontSize: 11, color: Colors.white54)),
                    trailing: DropdownButton<int>(
                      value: _autoHideSeconds, // <-- NUEVA VARIABLE
                      dropdownColor: const Color(0xFF2C2C2E),
                      underline: const SizedBox(),
                      style: const TextStyle(color: Color(0xFF0A84FF), fontSize: 13, fontWeight: FontWeight.w500),
                      icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF0A84FF)),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('Desactivado')),
                        DropdownMenuItem(value: 30, child: Text('30 segundos')),
                        DropdownMenuItem(value: 60, child: Text('1 minuto')),
                        DropdownMenuItem(value: 120, child: Text('2 minutos')),
                        DropdownMenuItem(value: 180, child: Text('3 minutos')),
                        DropdownMenuItem(value: 300, child: Text('5 minutos')),
                        DropdownMenuItem(value: 600, child: Text('10 minutos')),
                        DropdownMenuItem(value: 1800, child: Text('30 minutos')),
                        DropdownMenuItem(value: 3600, child: Text('1 hora')),
                      ],
                      onChanged: _setAutoHide,
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // TÍTULO DE SECCIÓN 3
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
                      if (_showNotifications) ...[
                        const Divider(height: 1, indent: 16, color: Colors.white12),
                        Padding(
                          padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 4.0, bottom: 12.0),
                          child: Row(
                            children: [
                              const Text('Agrupar notificaciones:', style: TextStyle(fontSize: 13)),
                              Expanded(
                                child: Slider(
                                  value: _notificationDelay.toDouble(),
                                  min: 1,
                                  max: 30, // Máximo 30 segundos
                                  divisions: 29,
                                  label: '$_notificationDelay seg',
                                  activeColor: const Color(0xFF0A84FF), // Azul estilo Mac
                                  inactiveColor: Colors.white24,
                                  onChanged: _setNotificationDelay,
                                ),
                              ),
                              SizedBox(
                                width: 35,
                                child: Text('$_notificationDelay s', 
                                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
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

class _InteractiveImageItem extends StatefulWidget {
  final File imageFile;
  final bool isCurrentPage;
  final int lowResWidth;
  final VoidCallback onTap;

  const _InteractiveImageItem({
    required this.imageFile,
    required this.isCurrentPage,
    required this.lowResWidth,
    required this.onTap,
  });

  @override
  State<_InteractiveImageItem> createState() => _InteractiveImageItemState();
}

class _InteractiveImageItemState extends State<_InteractiveImageItem> {
  // El controlador que maneja la matriz matemática del zoom
  final TransformationController _transformationController = TransformationController();
  Size? _lastScreenSize;

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder nos avisa cada vez que la ventana cambia de dimensiones
    return LayoutBuilder(
      builder: (context, constraints) {
        final currentSize = constraints.biggest;
        
        // Si la pantalla cambió de tamaño (ej. de normal a pantalla completa)
        if (_lastScreenSize != null && _lastScreenSize != currentSize) {
          
          // Calculamos cuánto creció o se encogió la ventana en CADA eje
          final widthRatio = currentSize.width / _lastScreenSize!.width;
          final heightRatio = currentSize.height / _lastScreenSize!.height;

          // Clonamos la posición actual del zoom
          final matrix = _transformationController.value.clone();
          
          // Multiplicamos X por el crecimiento horizontal y Y por el crecimiento vertical
          matrix[12] *= widthRatio; 
          matrix[13] *= heightRatio;

          // Le pedimos a Flutter que aplique la corrección suavemente
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _transformationController.value = matrix;
            }
          });
        }
        
        _lastScreenSize = currentSize;

        return GestureDetector(
          onTap: widget.onTap,
          child: InteractiveViewer(
            transformationController: _transformationController,
            panEnabled: widget.isCurrentPage,
            minScale: 1.0,
            maxScale: 4.0,
            child: widget.isCurrentPage
                ? Image.file(
                    widget.imageFile,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  )
                : Image.file(
                    widget.imageFile,
                    fit: BoxFit.contain,
                    cacheWidth: widget.lowResWidth,
                    gaplessPlayback: true,
                  ),
          ),
        );
      },
    );
  }
}