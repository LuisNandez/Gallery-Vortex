// wd14_tagger_service.dart
//
// Servicio singleton que gestiona todo el ciclo de vida del WD14 Tagger:
// instalación / desinstalación del entorno Python (vía el script de
// PowerShell embebido más abajo), arranque/parada del servidor local,
// y el proceso de etiquetado automático de la bóveda (con progreso y
// posibilidad de reanudar donde se quedó).
//
// No requiere dependencias nuevas: usa http, path, path_provider y
// shared_preferences, que tu proyecto ya trae (los mismos que usan
// profile_editor_dialog.dart y main.dart).
//
// Solo funciona en Windows (el instalador es un script .ps1). En otras
// plataformas `isSupportedPlatform` es false y el diálogo lo muestra
// deshabilitado con un aviso, sin romper nada.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'metadata_service.dart';
import 'thumbnail_service.dart';

enum Wd14InstallState {
  unknown,
  notInstalled,
  installing,
  installed,
  uninstalling,
  error,
}

enum Wd14ServerState { stopped, starting, running, stopping, error }

@immutable
class Wd14TaggingProgress {
  final int total;
  final int done;
  final int errors;
  final String? currentFile;
  final bool isRunning;
  /// true mientras se recorre el disco buscando imágenes (antes de conocer
  /// el total real). La UI debe mostrar un indicador indeterminado en vez
  /// de "0 / 0", que parece congelado.
  final bool isScanning;

  const Wd14TaggingProgress({
    this.total = 0,
    this.done = 0,
    this.errors = 0,
    this.currentFile,
    this.isRunning = false,
    this.isScanning = false,
  });

  double get fraction => total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
}

/// Error legible pensado para mostrarse tal cual en la UI (sin el ruido de
/// "Exception: ..." que añade el toString() por defecto).
class Wd14Exception implements Exception {
  final String message;
  const Wd14Exception(this.message);
  @override
  String toString() => message;
}

/// Sustantivo en español usado al componer traducciones tipo
/// "{adjetivo}_{sustantivo}" (ver [Wd14TaggerService._translateSuffixTag]).
class _Wd14SpanishNoun {
  final String es;
  final bool feminine;
  final bool plural;
  const _Wd14SpanishNoun(this.es, {this.feminine = false, this.plural = false});
}

/// Las 4 formas gramaticales de un adjetivo en español (masculino/femenino
/// x singular/plural), precalculadas a mano en vez de derivadas con una
/// regla heurística, para evitar concordancias incorrectas.
class _Wd14SpanishAdj {
  final String mascSingular;
  final String femSingular;
  final String mascPlural;
  final String femPlural;
  const _Wd14SpanishAdj(
      this.mascSingular, this.femSingular, this.mascPlural, this.femPlural);
}

/// Una imagen pendiente de etiquetar automáticamente tras ser absorbida.
class _AutoTagJob {
  final MetadataService metadataService;
  final String vaultRootPath;
  final String imageId;
  const _AutoTagJob(this.metadataService, this.vaultRootPath, this.imageId);
}

class Wd14TaggerService {
  Wd14TaggerService._internal();
  static final Wd14TaggerService instance = Wd14TaggerService._internal();

  static const String _kPortKey = 'wd14_port';
  static const String _kGeneralThKey = 'wd14_general_threshold';
  static const String _kCharThKey = 'wd14_character_threshold';
  static const String _kOnlyUntaggedKey = 'wd14_only_untagged';
  static const String _kMaxTagsKey = 'wd14_max_tags';
  static const String _kTranslateKey = 'wd14_translate_es';
  static const String _kAutoOnAbsorbKey = 'wd14_auto_on_absorb';
  static const String _kIdleUnloadKey = 'wd14_idle_unload_min';

  // Valores por defecto de las "opciones avanzadas", públicos para que el
  // botón "Restaurar valores por defecto" del diálogo no tenga que
  // adivinarlos ni duplicarlos.
  static const double kDefaultGeneralThreshold = 0.35;
  static const double kDefaultCharacterThreshold = 0.85;
  static const int kDefaultMaxTags = 25;
  static const bool kDefaultOnlyUntagged = true;
  static const bool kDefaultTranslateToSpanish = true;
  static const bool kDefaultAutoTagOnAbsorb = false;
  /// Minutos sin usar el servidor tras los cuales el modelo se descarga de la
  /// RAM (0 = nunca). Con 5 min el proceso baja de ~500 MB a unas decenas de MB.
  static const int kDefaultIdleUnloadMinutes = 5;
  static const List<int> kIdleUnloadChoices = [0, 2, 5, 10, 30];

  /// Versión del servidor que genera el instalador de esta app. Debe coincidir
  /// con `version` del script (más abajo); si el instalado es distinto, la UI
  /// avisa de que hay una actualización.
  static const String kCurrentServerVersion = '2.5.0';

  int _port = 5010;
  double _generalThreshold = 0.35;
  double _characterThreshold = 0.85;
  bool _onlyUntagged = true;
  /// Traduce las etiquetas generadas por la IA (que vienen en inglés,
  /// tal como las nombra el dataset de Danbooru) al español antes de
  /// guardarlas. Es una traducción por diccionario/reglas fijas: la misma
  /// etiqueta de origen siempre produce la misma traducción, así que no
  /// aparecen variantes distintas para una misma etiqueta ni se mezclan
  /// versiones en inglés y en español de lo mismo.
  bool _translateToSpanish = true;
  /// Diccionario "aprendido + manual": entra aquí cualquier traducción que
  /// el compositor genérico logre construir por primera vez, y cualquier
  /// traducción que el usuario añada o corrija a mano desde Ajustes. Se
  /// consulta con más prioridad que el diccionario curado interno (para
  /// que una corrección manual del usuario siempre gane), y se persiste en
  /// disco para no tener que recalcularlo ni perder ediciones manuales.
  Map<String, String> _userDictionary = {};
  bool _dictionaryLoaded = false;
  bool _dictionaryDirty = false;
  /// Máximo de etiquetas a conservar por imagen, quedándonos con las de
  /// mejor confianza (el servidor ya las devuelve ordenadas y recortadas,
  /// esto es además una segunda red de seguridad del lado del cliente).
  int _maxTags = 25;
  bool _preferencesLoaded = false;

  int get port => _port;
  double get generalThreshold => _generalThreshold;
  double get characterThreshold => _characterThreshold;
  bool get onlyUntagged => _onlyUntagged;
  bool get translateToSpanish => _translateToSpanish;
  int get maxTags => _maxTags;

  Process? _serverProcess;
  Map<String, dynamic>? _manifestCache;

  final ValueNotifier<Wd14InstallState> installState =
      ValueNotifier(Wd14InstallState.unknown);
  final ValueNotifier<Wd14ServerState> serverState =
      ValueNotifier(Wd14ServerState.stopped);
  final ValueNotifier<double> installProgress = ValueNotifier(0.0);
  final ValueNotifier<String> installStepLabel = ValueNotifier('');
  final ValueNotifier<Wd14TaggingProgress> taggingProgress =
      ValueNotifier(const Wd14TaggingProgress());
  final ValueNotifier<String?> lastError = ValueNotifier(null);
  /// true si el servidor instalado es de una versión anterior a la de esta app.
  final ValueNotifier<bool> serverOutdated = ValueNotifier(false);
  int _idleUnloadMinutes = kDefaultIdleUnloadMinutes;
  int get idleUnloadMinutes => _idleUnloadMinutes;
  /// Mensajes informativos (no errores) sobre el resultado del último
  /// etiquetado, p. ej. "ya estaba todo etiquetado". Se muestran en la UI
  /// con un estilo neutro, a diferencia de lastError (rojo).
  final ValueNotifier<String?> lastInfo = ValueNotifier(null);

  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  Stream<String> get logStream => _logController.stream;

  bool _cancelTaggingRequested = false;
  bool _isTagging = false;
  bool get isTagging => _isTagging;

  bool get isSupportedPlatform => Platform.isWindows;

  // ------------------------------------------- etiquetado al absorber ---

  /// Espera antes de volver a intentar arrancar el servidor tras un fallo
  /// (así una imagen absorbida cada segundo no lanza 45 s de intentos cada vez).
  static const Duration _kAutoBackoff = Duration(minutes: 5);

  bool _autoTagOnAbsorb = kDefaultAutoTagOnAbsorb;
  bool get autoTagOnAbsorb => _autoTagOnAbsorb;

  final List<_AutoTagJob> _autoQueue = [];
  /// Cuántas imágenes esperan turno para el etiquetado automático (la UI
  /// puede mostrarlo).
  final ValueNotifier<int> autoQueueLength = ValueNotifier(0);
  bool _autoWorkerRunning = false;
  DateTime? _autoBackoffUntil;
  /// true cuando la app se está cerrando: no se aceptan más trabajos.
  bool _exiting = false;

  // ---------------------------------------------------------------- init ---

  /// Carga preferencias guardadas y detecta si ya está instalado.
  /// Llamar una vez al abrir el diálogo (es barato e idempotente).
  Future<void> initialize() async {
    await _loadPreferences();
    await refreshInstallState();
  }

  Future<void> _loadPreferences() async {
    if (_preferencesLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    _port = prefs.getInt(_kPortKey) ?? 5010;
    _generalThreshold = prefs.getDouble(_kGeneralThKey) ?? 0.35;
    _characterThreshold = prefs.getDouble(_kCharThKey) ?? 0.85;
    _onlyUntagged = prefs.getBool(_kOnlyUntaggedKey) ?? true;
    _translateToSpanish = prefs.getBool(_kTranslateKey) ?? true;
    _maxTags = prefs.getInt(_kMaxTagsKey) ?? 25;
    _autoTagOnAbsorb = prefs.getBool(_kAutoOnAbsorbKey) ?? kDefaultAutoTagOnAbsorb;
    _idleUnloadMinutes = prefs.getInt(_kIdleUnloadKey) ?? kDefaultIdleUnloadMinutes;
    _preferencesLoaded = true;
  }

  /// IMPORTANTE: los campos se actualizan ANTES del `await`. Como esta
  /// función es `async`, todo lo que va antes del primer `await` se ejecuta
  /// de forma síncrona en cuanto se llama; si el campo se actualizara
  /// DESPUÉS de `await SharedPreferences.getInstance()` (como estaba antes),
  /// un `setState(() => service.setThresholds(...))` en la UI dispararía el
  /// repintado con el valor VIEJO (porque el campo aún no se había
  /// actualizado), y el slider solo se veía correcto tras un repintado
  /// posterior por otro motivo (p. ej. contraer/expandir el panel). Esto es
  /// justo el bug de "el slider no se mueve en tiempo real".
  Future<void> setThresholds({double? general, double? character}) async {
    if (general != null) _generalThreshold = general;
    if (character != null) _characterThreshold = character;
    final prefs = await SharedPreferences.getInstance();
    if (general != null) await prefs.setDouble(_kGeneralThKey, general);
    if (character != null) await prefs.setDouble(_kCharThKey, character);
  }

  Future<void> setOnlyUntagged(bool value) async {
    _onlyUntagged = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOnlyUntaggedKey, value);
  }

  /// Cambia tras cuántos minutos sin uso se descarga el modelo de la RAM
  /// (0 = nunca). Si el servidor está corriendo se aplica en caliente.
  Future<void> setIdleUnloadMinutes(int minutes) async {
    _idleUnloadMinutes = minutes < 0 ? 0 : minutes;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kIdleUnloadKey, _idleUnloadMinutes);
    await _pushIdleConfigToServer();
  }

  Future<void> _pushIdleConfigToServer() async {
    if (serverState.value != Wd14ServerState.running) return;
    try {
      await http
          .post(Uri.parse('$baseUrl/config').replace(queryParameters: {
            'idle_unload_seconds': (_idleUnloadMinutes * 60).toString(),
          }))
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // Un servidor instalado con una versión vieja no tiene /config: el ajuste
      // se aplicará igualmente en el próximo inicio (y tras "Actualizar").
    }
  }

  /// Activa/desactiva el etiquetado automático de cada imagen absorbida.
  /// Al desactivarlo se vacía la cola pendiente.
  Future<void> setAutoTagOnAbsorb(bool value) async {
    _autoTagOnAbsorb = value;
    _autoBackoffUntil = null;
    if (!value) {
      _autoQueue.clear();
      autoQueueLength.value = 0;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoOnAbsorbKey, value);
  }

  Future<void> setTranslateToSpanish(bool value) async {
    _translateToSpanish = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTranslateKey, value);
  }

  Future<void> setMaxTags(int value) async {
    _maxTags = value.clamp(1, 200);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kMaxTagsKey, _maxTags);
  }

  /// Restaura las 5 "opciones avanzadas" a sus valores por defecto, tanto en
  /// memoria como en disco. La UI (el botón "Restaurar valores por
  /// defecto") además actualiza su propio estado local para reflejarlo al
  /// instante; ver el comentario en `_Wd14TaggerDialogState` sobre por qué
  /// se mantiene un espejo local en vez de leer siempre de aquí.
  Future<void> resetAdvancedOptionsToDefaults() async {
    _generalThreshold = kDefaultGeneralThreshold;
    _characterThreshold = kDefaultCharacterThreshold;
    _maxTags = kDefaultMaxTags;
    _onlyUntagged = kDefaultOnlyUntagged;
    _translateToSpanish = kDefaultTranslateToSpanish;
    _idleUnloadMinutes = kDefaultIdleUnloadMinutes;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kIdleUnloadKey, _idleUnloadMinutes);
    unawaited(_pushIdleConfigToServer());
    await prefs.setDouble(_kGeneralThKey, _generalThreshold);
    await prefs.setDouble(_kCharThKey, _characterThreshold);
    await prefs.setInt(_kMaxTagsKey, _maxTags);
    await prefs.setBool(_kOnlyUntaggedKey, _onlyUntagged);
    await prefs.setBool(_kTranslateKey, _translateToSpanish);
  }

  void _log(String line) {
    debugPrint('[WD14] $line');
    if (!_logController.isClosed) _logController.add(line);
  }

  // ------------------------------------------------------------- rutas ---

  Future<String> get _installDir async {
    final supportDir = await getApplicationSupportDirectory();
    return p.join(supportDir.path, 'wd14-tagger-server');
  }

  Future<String> get _manifestPath async =>
      p.join(await _installDir, 'install_manifest.json');

  Future<String> get _stateFilePath async => p.join(
      (await getApplicationSupportDirectory()).path, 'wd14_tagging_state.json');

  Future<String> get _scriptTempPath async =>
      p.join((await getTemporaryDirectory()).path, 'install_wd14_tagger.ps1');

  // --------------------------------------------------------- instalacion ---

  Future<void> refreshInstallState() async {
    if (!isSupportedPlatform) {
      installState.value = Wd14InstallState.error;
      lastError.value = 'El etiquetado automático WD14 solo está disponible en Windows.';
      return;
    }
    try {
      final manifestFile = File(await _manifestPath);
      if (!await manifestFile.exists()) {
        installState.value = Wd14InstallState.notInstalled;
        return;
      }
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final pythonExe = File(manifest['pythonExe'] as String);
      final serverScript = File(manifest['serverScript'] as String);
      if (await pythonExe.exists() && await serverScript.exists()) {
        _manifestCache = manifest;
        _port = manifest['port'] as int? ?? _port;
        serverOutdated.value = (manifest['version'] as String?) != kCurrentServerVersion;
        installState.value = Wd14InstallState.installed;
      } else {
        // El manifest existe pero faltan archivos (instalación corrupta
        // o borrada a mano): lo tratamos como no instalado.
        _manifestCache = null;
        installState.value = Wd14InstallState.notInstalled;
      }
    } catch (_) {
      installState.value = Wd14InstallState.notInstalled;
    }
  }

  Future<bool> install({bool force = false}) async {
    if (!isSupportedPlatform) return false;
    installState.value = Wd14InstallState.installing;
    installProgress.value = 0.0;
    installStepLabel.value = 'Preparando instalador...';
    lastError.value = null;

    try {
      final scriptPath = await _writeInstallerScript();
      final installDir = await _installDir;

      final args = [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', scriptPath,
        '-InstallDir', installDir,
        '-Port', _port.toString(),
        if (force) '-Force',
      ];

      final ok = await _runPowershell(args, onProgress: (step, total, label) {
        installProgress.value = total == 0 ? 0.0 : step / total;
        installStepLabel.value = label;
      });

      if (ok) {
        await refreshInstallState();
        if (installState.value == Wd14InstallState.installed) return true;
      }
      installState.value = Wd14InstallState.error;
      lastError.value ??= 'La instalación no terminó correctamente. Revisa el registro de abajo.';
      return false;
    } catch (e) {
      installState.value = Wd14InstallState.error;
      lastError.value = 'Error instalando: $e';
      return false;
    }
  }

  Future<bool> uninstall() async {
    if (!isSupportedPlatform) return false;
    await stopServer();
    installState.value = Wd14InstallState.uninstalling;
    lastError.value = null;
    try {
      final scriptPath = await _writeInstallerScript();
      final installDir = await _installDir;
      final ok = await _runPowershell(
        [
          '-NoProfile',
          '-ExecutionPolicy', 'Bypass',
          '-File', scriptPath,
          '-InstallDir', installDir,
          '-Uninstall',
        ],
        onProgress: (step, total, label) {
          installProgress.value = total == 0 ? 0.0 : step / total;
          installStepLabel.value = label;
        },
      );
      _manifestCache = null;
      await _clearTaggingState();
      installState.value = Wd14InstallState.notInstalled;
      return ok;
    } catch (e) {
      installState.value = Wd14InstallState.error;
      lastError.value = 'Error desinstalando: $e';
      return false;
    }
  }

  Future<bool> _runPowershell(
    List<String> args, {
    required void Function(int step, int total, String label) onProgress,
  }) async {
    final Process process;
    try {
      process = await Process.start('powershell.exe', args, runInShell: false);
    } catch (e) {
      lastError.value = 'No se pudo iniciar PowerShell: $e';
      return false;
    }

    bool sawDone = false;
    final progressRegex = RegExp(r'^##WD14PROGRESS##\s+(\d+)/(\d+)\s+(.*)$');

    void handleLine(String line) {
      _log(line);
      final m = progressRegex.firstMatch(line);
      if (m != null) {
        final step = int.tryParse(m.group(1) ?? '') ?? 0;
        final total = int.tryParse(m.group(2) ?? '') ?? 0;
        onProgress(step, total, m.group(3) ?? '');
      } else if (line.contains('##WD14DONE##')) {
        sawDone = true;
      } else if (line.contains('##WD14ERROR##')) {
        lastError.value = line.split('##WD14ERROR##').last.trim();
      }
    }

    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handleLine);
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_log);

    final exitCode = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();

    if (lastError.value != null) return false;
    return exitCode == 0 && sawDone;
  }

  Future<String> _writeInstallerScript() async {
    final path = await _scriptTempPath;
    final file = File(path);
    await file.writeAsString(_installerScript, flush: true);
    return path;
  }

  // ------------------------------------------------------------ servidor ---

  String get baseUrl => 'http://127.0.0.1:$_port';

  Future<bool> isServerReachable({Duration timeout = const Duration(seconds: 2)}) async {
    try {
      final res = await http.get(Uri.parse('$baseUrl/health')).timeout(timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> startServer() async {
    if (!isSupportedPlatform) return false;

    if (installState.value != Wd14InstallState.installed || _manifestCache == null) {
      await refreshInstallState();
      if (installState.value != Wd14InstallState.installed || _manifestCache == null) {
        lastError.value = 'Instala el servidor antes de iniciarlo.';
        return false;
      }
    }
    if (serverState.value == Wd14ServerState.running) return true;
    await _loadPreferences();

    serverState.value = Wd14ServerState.starting;
    lastError.value = null;

    // Si ya hay un servidor escuchando en el puerto (p. ej. quedó huérfano
    // de una sesión anterior tras un cierre brusco de la app), lo adoptamos
    // en vez de lanzar un segundo proceso.
    if (await isServerReachable()) {
      serverState.value = Wd14ServerState.running;
      return true;
    }

    try {
      final pythonExe = _manifestCache!['pythonExe'] as String;
      final serverScript = _manifestCache!['serverScript'] as String;
      final workingDir = p.dirname(serverScript);

      _serverProcess = await Process.start(
        pythonExe,
        [serverScript],
        workingDirectory: workingDir,
        // El servidor descarga el modelo de la RAM tras este tiempo sin uso.
        environment: {
          'WD14_IDLE_UNLOAD_SECONDS': (_idleUnloadMinutes * 60).toString(),
        },
      );
      _serverProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_log);
      _serverProcess!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_log);

      unawaited(_serverProcess!.exitCode.then((code) {
        if (serverState.value != Wd14ServerState.stopping) {
          _log('El servidor terminó inesperadamente (código $code).');
          lastError.value = 'El servidor se cerró inesperadamente.';
        }
        _serverProcess = null;
        serverState.value = Wd14ServerState.stopped;
      }));

      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline) &&
          serverState.value == Wd14ServerState.starting) {
        if (await isServerReachable(timeout: const Duration(milliseconds: 800))) {
          serverState.value = Wd14ServerState.running;
          return true;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Si alguien lo detuvo mientras arrancaba (p. ej. el cierre de la app)
      // o el proceso murió, no seguimos esperando ni lo tratamos como timeout.
      if (serverState.value != Wd14ServerState.starting) return false;

      lastError.value = 'El servidor no respondió a tiempo al iniciar.';
      await stopServer();
      return false;
    } catch (e) {
      lastError.value = 'Error iniciando el servidor: $e';
      serverState.value = Wd14ServerState.error;
      return false;
    }
  }

  Future<void> stopServer() async {
    if (serverState.value == Wd14ServerState.stopped && _serverProcess == null) {
      return;
    }
    serverState.value = Wd14ServerState.stopping;
    cancelAutoTagging();

    // 1. Apagado ordenado a través del propio servidor: funciona incluso
    //    si este proceso de Flutter no fue quien lo lanzó (servidor adoptado).
    try {
      await http
          .post(Uri.parse('$baseUrl/shutdown'))
          .timeout(const Duration(seconds: 2));
      await Future.delayed(const Duration(milliseconds: 600));
    } catch (_) {}

    // 2. Si seguía vivo (o el proceso que lanzamos todavía existe, p. ej. si aún
    //    estaba cargando el modelo y no respondía), lo forzamos.
    if (_serverProcess != null ||
        await isServerReachable(timeout: const Duration(seconds: 1))) {
      await _killServerProcessTree();
      await Future.delayed(const Duration(milliseconds: 300));
    }

    _serverProcess = null;
    serverState.value = Wd14ServerState.stopped;
  }

  /// Mata el servidor Y sus procesos hijos. En Windows el `python.exe` del venv
  /// es solo un lanzador que crea el proceso real (el que tiene el modelo en
  /// RAM) como hijo; `Process.kill()` mata únicamente al lanzador y deja al
  /// hijo huérfano ocupando ~500 MB. `taskkill /T` mata todo el árbol.
  Future<void> _killServerProcessTree() async {
    final proc = _serverProcess;
    if (proc == null) return;
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '${proc.pid}', '/T', '/F']);
      } else {
        proc.kill();
      }
    } catch (_) {
      try {
        proc.kill();
      } catch (_) {}
    }
  }

  // ------------------------------------------------------ etiquetado auto ---

  static const List<String> _imageExtensions = [
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp',
    '.avif', // se convierte a JPEG con ThumbnailService antes de enviarlo
  ];

  // Tu app guarda los archivos con la extensión real oculta y cifrada, y
  // todos quedan con extensión física ".vtx" en disco: el punto se codifica
  // como '0', las letras se desplazan +1 (z -> a), los números se dejan
  // igual (ver `_cipherExtension` / `_decipherExtension` en main.dart).
  // Replicamos el mismo descifrado aquí (son funciones privadas del otro
  // archivo, no se pueden reutilizar directamente) para saber qué archivos
  // son imágenes de verdad antes de mandarlos a etiquetar.
  String _decipherExtension(String ciphered) {
    final buffer = StringBuffer();
    for (int i = 0; i < ciphered.length; i++) {
      final char = ciphered[i].toLowerCase();
      if (char == '0') {
        buffer.write('.');
      } else if (RegExp(r'[a-z]').hasMatch(char)) {
        final code = char.codeUnitAt(0);
        final prev = code == 97 ? 122 : code - 1; // a -> z
        buffer.writeCharCode(prev);
      } else {
        buffer.write(char); // los números se dejan igual
      }
    }
    return buffer.toString();
  }

  /// Extensión real de un archivo, descifrando ".vtx" si hace falta.
  String _realExtensionOf(String filePath) {
    if (filePath.toLowerCase().endsWith('.vtx')) {
      final base = p.basenameWithoutExtension(filePath);
      final lastZero = base.lastIndexOf('0');
      if (lastZero != -1) {
        return _decipherExtension(base.substring(lastZero));
      }
      return '';
    }
    return p.extension(filePath).toLowerCase();
  }

  bool _isTaggableImage(String path) {
    return _imageExtensions.contains(_realExtensionOf(path));
  }

  void cancelAutoTagging() {
    _cancelTaggingRequested = true;
  }

  // ------------------------------------- etiquetado automático al absorber ---

  /// Encola una imagen recién absorbida para etiquetarla con la IA. No hace
  /// nada si la opción está desactivada, si no es una imagen etiquetable
  /// (los videos se omiten) o si la app se está cerrando. Es seguro llamarla
  /// sin `await`: nunca lanza y no bloquea al que absorbe.
  Future<void> enqueueAutoTag({
    required MetadataService metadataService,
    required String vaultRootPath,
    required String imageId,
  }) async {
    try {
      if (!isSupportedPlatform || _exiting) return;
      await _loadPreferences();
      if (!_autoTagOnAbsorb || _exiting) return;
      if (!_isTaggableImage(imageId)) return;

      final backoff = _autoBackoffUntil;
      if (backoff != null && DateTime.now().isBefore(backoff)) return;

      _autoQueue.add(_AutoTagJob(metadataService, vaultRootPath, imageId));
      autoQueueLength.value = _autoQueue.length;
      unawaited(_runAutoQueue());
    } catch (e) {
      _log('No se pudo encolar "$imageId" para etiquetado automático: $e');
    }
  }

  void _abortAutoQueue(String reason, {bool backoff = true}) {
    _log('Etiquetado automático detenido: $reason.');
    _autoQueue.clear();
    autoQueueLength.value = 0;
    if (backoff) _autoBackoffUntil = DateTime.now().add(_kAutoBackoff);
  }

  /// Procesa la cola de una en una. Un solo "trabajador" a la vez.
  Future<void> _runAutoQueue() async {
    if (_autoWorkerRunning) return;
    _autoWorkerRunning = true;
    try {
      // 1) Asegurar que el servidor está en marcha (se inicia solo si hace falta).
      while (serverState.value == Wd14ServerState.starting ||
          serverState.value == Wd14ServerState.stopping) {
        if (_exiting) return;
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (_exiting) return;

      if (serverState.value != Wd14ServerState.running) {
        if (installState.value != Wd14InstallState.installed) {
          await refreshInstallState();
        }
        if (installState.value != Wd14InstallState.installed) {
          _abortAutoQueue('el servidor de etiquetas no está instalado');
          return;
        }
        final started = await startServer();
        if (!started) {
          if (!_exiting) _abortAutoQueue('no se pudo iniciar el servidor');
          return;
        }
      }

      // 2) Etiquetar la cola.
      while (_autoQueue.isNotEmpty && !_exiting) {
        // Si hay un etiquetado masivo en curso, le cedemos el turno.
        if (_isTagging) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        if (serverState.value != Wd14ServerState.running) {
          // Sin backoff: la próxima imagen absorbida volverá a intentarlo.
          _abortAutoQueue('el servidor se detuvo', backoff: false);
          return;
        }

        final job = _autoQueue.removeAt(0);
        autoQueueLength.value = _autoQueue.length;

        try {
          final file = File(p.join(job.vaultRootPath, job.imageId));
          if (!await file.exists()) continue;
          // Respeta lo que el usuario (o el etiquetado masivo) haya puesto
          // mientras la imagen esperaba en la cola.
          if (job.metadataService.getMetadataForImage(job.imageId).tags.isNotEmpty) {
            continue;
          }
          final tags = await _tagFile(file);
          if (tags.isNotEmpty) {
            await job.metadataService.addTagsToImage(job.imageId, tags);
          }
        } catch (e) {
          _log('Etiquetado automático falló para "${job.imageId}": $e');
        }
      }
    } finally {
      _autoWorkerRunning = false;
      // Por si llegó algo justo mientras el trabajador terminaba.
      if (_autoQueue.isNotEmpty && !_exiting) unawaited(_runAutoQueue());
    }
  }

  /// Prepara el cierre de la app: deja de aceptar imágenes nuevas, vacía la
  /// cola, cancela el etiquetado masivo y espera (máx. [timeout]) a que
  /// termine la imagen que estuviera en curso. NO detiene el servidor; eso
  /// lo hace [stopServer].
  Future<void> stopBackgroundTagging({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    _exiting = true;
    _autoQueue.clear();
    autoQueueLength.value = 0;
    cancelAutoTagging();

    final deadline = DateTime.now().add(timeout);
    while ((_autoWorkerRunning || _isTagging) &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<Map<String, dynamic>?> _loadTaggingState(String vaultRootPath) async {
    try {
      final file = File(await _stateFilePath);
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (data['vaultRootPath'] != vaultRootPath) return null;
      return data;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveTaggingState(
    String vaultRootPath,
    List<String> pending,
    List<String> done,
    int errors,
  ) async {
    try {
      final file = File(await _stateFilePath);
      await file.writeAsString(jsonEncode({
        'vaultRootPath': vaultRootPath,
        'pending': pending,
        'done': done,
        'errors': errors,
        'updatedAt': DateTime.now().toIso8601String(),
      }));
    } catch (_) {}
  }

  Future<void> _clearTaggingState() async {
    try {
      final file = File(await _stateFilePath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Cuántas imágenes quedaron pendientes de una sesión de etiquetado
  /// anterior para este mismo vault (null si no hay ninguna sesión previa
  /// interrumpida). Úsalo para ofrecer "Reanudar (N restantes)" en la UI.
  Future<int?> pendingResumeCount(String vaultRootPath) async {
    final state = await _loadTaggingState(vaultRootPath);
    if (state == null) return null;
    final pending = (state['pending'] as List).cast<String>();
    return pending.isEmpty ? null : pending.length;
  }

  /// Lanza el etiquetado automático de todo el vault (o reanuda uno anterior
  /// si `resume` es true y hay una sesión pendiente para el mismo vault).
  /// Actualiza `taggingProgress` mientras corre; usa `cancelAutoTagging()`
  /// para detenerlo dejando el punto exacto guardado para la próxima vez.
  Future<void> startAutoTagging({
    required MetadataService metadataService,
    required String vaultRootPath,
    bool resume = false,
  }) async {
    if (_isTagging) return;
    if (serverState.value != Wd14ServerState.running) {
      lastError.value = 'El servidor debe estar en ejecución para etiquetar.';
      return;
    }

    _isTagging = true;
    _cancelTaggingRequested = false;
    lastError.value = null;
    lastInfo.value = null;

    // Feedback INMEDIATO: con bóvedas grandes (miles de imágenes), recorrer
    // el disco para armar la cola puede tardar varios segundos, y si no
    // avisamos nada aquí la UI parece congelada mientras tanto.
    taggingProgress.value = const Wd14TaggingProgress(isRunning: true, isScanning: true);

    List<String> pending;
    List<String> done;
    int errors;

    final previousState = resume ? await _loadTaggingState(vaultRootPath) : null;

    if (previousState != null) {
      pending = (previousState['pending'] as List).cast<String>();
      done = (previousState['done'] as List).cast<String>();
      errors = previousState['errors'] as int? ?? 0;
    } else {
      if (vaultRootPath.trim().isEmpty) {
        _isTagging = false;
        lastError.value = 'No se indicó la ruta de la bóveda (vaultRootPath está vacío).';
        taggingProgress.value = const Wd14TaggingProgress(isRunning: false);
        return;
      }

      final vaultDir = Directory(vaultRootPath);
      if (!await vaultDir.exists()) {
        _isTagging = false;
        lastError.value = 'La carpeta de la bóveda no existe: "$vaultRootPath". '
            'Revisa que se esté pasando la ruta correcta al abrir este diálogo.';
        taggingProgress.value = const Wd14TaggingProgress(isRunning: false);
        return;
      }

      final allImageIds = <String>[];
      await for (final entity in vaultDir.list(recursive: true, followLinks: false)) {
        if (entity is File && _isTaggableImage(entity.path)) {
          allImageIds.add(p.relative(entity.path, from: vaultRootPath));
        }
        // Con bóvedas de miles de imágenes el escaneo puede tardar; damos
        // una señal de vida periódica para que la UI muestre cuántos
        // archivos llevamos encontrados hasta ahora.
        if (allImageIds.length % 250 == 0) {
          taggingProgress.value = Wd14TaggingProgress(
            total: allImageIds.length,
            isRunning: true,
            isScanning: true,
          );
        }
      }
      allImageIds.sort();

      if (allImageIds.isEmpty) {
        _isTagging = false;
        lastError.value = 'No se encontró ninguna imagen en "$vaultRootPath".';
        taggingProgress.value = const Wd14TaggingProgress(isRunning: false);
        return;
      }

      pending = _onlyUntagged
          ? allImageIds
              .where((id) => metadataService.getMetadataForImage(id).tags.isEmpty)
              .toList()
          : List.of(allImageIds);
      done = _onlyUntagged
          ? allImageIds.where((id) => !pending.contains(id)).toList()
          : [];
      errors = 0;
      await _saveTaggingState(vaultRootPath, pending, done, errors);
    }

    final total = pending.length + done.length;

    if (pending.isEmpty) {
      _isTagging = false;
      taggingProgress.value = Wd14TaggingProgress(
        total: total, done: done.length, errors: errors, isRunning: false, isScanning: false,
      );
      lastInfo.value = total > 0
          ? 'Las $total imágenes de la bóveda ya tenían etiquetas. No había nada pendiente.'
          : 'No se encontraron imágenes que etiquetar.';
      await _clearTaggingState();
      return;
    }

    taggingProgress.value = Wd14TaggingProgress(
      total: total, done: done.length, errors: errors, isRunning: true, isScanning: false,
    );

    // Copiamos la cola: vamos quitando de 'pending' (la lista persistida)
    // a medida que avanzamos, así el archivo de estado en disco siempre
    // refleja exactamente por dónde íbamos si el proceso se cancela o crashea.
    final queue = List<String>.from(pending);

    for (final imageId in queue) {
      if (_cancelTaggingRequested) break;
      if (serverState.value != Wd14ServerState.running) {
        lastError.value = 'El servidor se detuvo durante el etiquetado.';
        break;
      }

      taggingProgress.value = Wd14TaggingProgress(
        total: total, done: done.length, errors: errors, currentFile: imageId, isRunning: true,
      );

      final file = File(p.join(vaultRootPath, imageId));
      bool success = false;

      if (await file.exists()) {
        try {
          final tags = await _tagFile(file);
          if (tags.isNotEmpty) {
            await metadataService.addTagsToImage(imageId, tags);
          }
          success = true;
        } catch (e) {
          _log('Error etiquetando "$imageId": $e');
        }
      } else {
        _log('Archivo no encontrado, se omite: "$imageId"');
      }

      pending.remove(imageId);
      if (success) {
        done.add(imageId);
      } else {
        errors++;
      }

      await _saveTaggingState(vaultRootPath, pending, done, errors);
      taggingProgress.value =
          Wd14TaggingProgress(total: total, done: done.length, errors: errors, isRunning: true);
    }

    _isTagging = false;
    final wasCancelled = _cancelTaggingRequested;
    _cancelTaggingRequested = false;

    taggingProgress.value =
        Wd14TaggingProgress(total: total, done: done.length, errors: errors, isRunning: false);

    if (!wasCancelled && pending.isEmpty) {
      await _clearTaggingState();
    }
    // Si se canceló o se interrumpió, el estado queda guardado en disco:
    // la próxima llamada con resume:true continúa justo donde se quedó.
  }

  /// Etiqueta UNA sola imagen al instante (para el botón "Etiquetar con IA"
  /// del panel de etiquetas por archivo). Arranca el servidor solo si hace
  /// falta y no toca la cola/; progreso del etiquetado masivo.
  /// Lanza [Wd14Exception] con un mensaje listo para mostrar si algo falla.
  Future<List<String>> tagImageNow({
    required String imageId,
    required String vaultRootPath,
  }) async {
    if (!isSupportedPlatform) {
      throw const Wd14Exception('El etiquetado con IA solo está disponible en Windows.');
    }

    if (installState.value != Wd14InstallState.installed) {
      await refreshInstallState();
      if (installState.value != Wd14InstallState.installed) {
        throw const Wd14Exception(
            'Instala el servidor WD14 primero (Ajustes → Etiquetado automático WD14).');
      }
    }

    if (serverState.value != Wd14ServerState.running) {
      final started = await startServer();
      if (!started) {
        throw Wd14Exception(lastError.value ?? 'No se pudo iniciar el servidor WD14.');
      }
    }

    final file = File(p.join(vaultRootPath, imageId));
    if (!await file.exists()) {
      throw const Wd14Exception('El archivo ya no existe en disco.');
    }

    try {
      return await _tagFile(file);
    } catch (e) {
      throw Wd14Exception('Error etiquetando la imagen: $e');
    }
  }

  /// Etiquetas "kaomoji" del vocabulario WD14 (WaifuDiffusion) cuyo guion
  /// bajo es parte del emoticono, no un separador de palabras: a
  /// diferencia del resto de tags (donde "_" sí debe verse como espacio,
  /// p. ej. "blue_eyes" -> "blue eyes"), estas deben conservarse tal cual.
  /// Misma lista que usa la demo oficial de SmilingWolf/wd-tagger.
  static const Set<String> _kaomojiTags = {
    '0_0', '(o)_(o)', '+_+', '+_-', '._.', '<o>_<o>', '<|>_<|>', '=_=',
    '>_<', '3_3', '6_9', '>_o', '@_@', '^_^', 'o_o', 'u_u', 'x_x', '|_|',
    '||_||',
  };

  // -------------------------------------------------- traducción a ES ---
  //
  // Traducción por diccionario + reglas fijas, NO por un servicio externo:
  // así funciona sin internet (el etiquetado ya es 100% local) y, sobre
  // todo, la MISMA etiqueta de origen siempre da la MISMA traducción, sin
  // depender de un modelo de traducción que podría redactar la frase de
  // formas distintas cada vez. Si una etiqueta no está cubierta por el
  // diccionario ni por las reglas de composición, se deja en inglés (con
  // "_" -> " ") en vez de arriesgar una traducción inventada o incoherente.

  /// Traducciones exactas para las etiquetas de propósito general más
  /// frecuentes (cantidad de personajes, pose, composición, escenario,
  /// ropa/objetos comunes, contenido explícito...). No es un diccionario
  /// completo del vocabulario WD14 (tiene miles de etiquetas), sino el
  /// conjunto que en la práctica aparece en la inmensa mayoría de imágenes.
  static const Map<String, String> _kExactTranslations = {
    '1girl': '1 chica', '2girls': '2 chicas', '3girls': '3 chicas',
    '4girls': '4 chicas', '5girls': '5 chicas', '6+girls': '6+ chicas',
    'multiple_girls': 'varias chicas',
    '1boy': '1 chico', '2boys': '2 chicos', '3boys': '3 chicos',
    'multiple_boys': 'varios chicos',
    '1other': '1 otro personaje', 'solo': 'solo un personaje',
    'solo_focus': 'foco en un solo personaje', 'no_humans': 'sin humanos',
    'looking_at_viewer': 'mirando al espectador',
    'looking_away': 'mirando hacia otro lado',
    'looking_back': 'mirando hacia atrás',
    'looking_down': 'mirando hacia abajo', 'looking_up': 'mirando hacia arriba',
    'closed_eyes': 'ojos cerrados', 'closed_mouth': 'boca cerrada',
    'open_mouth': 'boca abierta', 'one_eye_closed': 'un ojo cerrado',
    'smile': 'sonriendo', 'smiling': 'sonriendo', 'laughing': 'riendo',
    'blush': 'sonrojo', 'expressionless': 'sin expresión', 'serious': 'seria',
    'sad': 'triste', 'angry': 'enojada', 'crying': 'llorando',
    'tears': 'lágrimas', 'embarrassed': 'avergonzada',
    'portrait': 'retrato', 'upper_body': 'medio cuerpo',
    'lower_body': 'parte inferior del cuerpo', 'full_body': 'cuerpo completo',
    'cowboy_shot': 'plano americano', 'close-up': 'primer plano',
    'from_side': 'de perfil', 'from_behind': 'desde atrás',
    'from_above': 'desde arriba', 'from_below': 'desde abajo',
    'profile': 'de perfil', 'realistic': 'realista',
    'photorealistic': 'fotorrealista', '3d': '3d',
    'monochrome': 'monocromo', 'greyscale': 'escala de grises',
    'grayscale': 'escala de grises', 'sketch': 'boceto',
    'lineart': 'dibujo lineal', 'traditional_media': 'medio tradicional',
    'blurry': 'borroso', 'blurry_background': 'fondo borroso',
    'blurry_foreground': 'primer plano borroso',
    'depth_of_field': 'profundidad de campo', 'motion_blur': 'desenfoque de movimiento',
    'simple_background': 'fondo simple', 'white_background': 'fondo blanco',
    'black_background': 'fondo negro', 'gradient_background': 'fondo degradado',
    'outdoors': 'exteriores', 'indoors': 'interiores', 'sky': 'cielo',
    'cloud': 'nube', 'clouds': 'nubes', 'day': 'día', 'night': 'noche',
    'sunset': 'atardecer', 'sunlight': 'luz solar', 'rain': 'lluvia',
    'snow': 'nieve', 'water': 'agua', 'ocean': 'océano', 'beach': 'playa',
    'forest': 'bosque', 'city': 'ciudad', 'street': 'calle',
    'building': 'edificio', 'window': 'ventana', 'flower': 'flor',
    'flowers': 'flores', 'tree': 'árbol', 'grass': 'césped',
    'nude': 'desnuda', 'naked': 'desnuda', 'nipples': 'pezones',
    'pussy': 'vulva', 'penis': 'pene', 'sex': 'sexo',
    'breasts': 'pechos', 'large_breasts': 'pechos grandes',
    'small_breasts': 'pechos pequeños', 'medium_breasts': 'pechos medianos',
    'huge_breasts': 'pechos enormes', 'flat_chest': 'pecho plano',
    'navel': 'ombligo', 'thighs': 'muslos', 'thigh_gap': 'espacio entre muslos',
    'ass': 'trasero', 'armpits': 'axilas', 'collarbone': 'clavícula',
    'jewelry': 'joyería', 'earrings': 'aretes', 'necklace': 'collar',
    'ring': 'anillo', 'choker': 'gargantilla', 'glasses': 'gafas',
    'sunglasses': 'gafas de sol', 'hat': 'sombrero', 'cap': 'gorra',
    'crown': 'corona', 'hair_ornament': 'adorno de cabello',
    'hairband': 'diadema', 'hair_ribbon': 'lazo en el pelo',
    'hair_bow': 'moño en el pelo', 'bow': 'lazo', 'ribbon': 'cinta',
    'gloves': 'guantes', 'fingerless_gloves': 'guantes sin dedos',
    'elbow_gloves': 'guantes largos', 'socks': 'calcetines',
    'thighhighs': 'medias', 'pantyhose': 'pantimedias', 'shoes': 'zapatos',
    'boots': 'botas', 'sandals': 'sandalias', 'barefoot': 'descalza',
    'skirt': 'falda', 'miniskirt': 'minifalda', 'dress': 'vestido',
    'shirt': 'camisa', 't-shirt': 'camiseta', 'sweater': 'suéter',
    'jacket': 'chaqueta', 'coat': 'abrigo', 'uniform': 'uniforme',
    'school_uniform': 'uniforme escolar', 'swimsuit': 'traje de baño',
    'bikini': 'bikini', 'underwear': 'ropa interior', 'bra': 'sostén',
    'panties': 'bragas', 'topless': 'sin camisa', 'see-through': 'transparente',
    'wet': 'mojada', 'sweat': 'sudor', 'weapon': 'arma', 'sword': 'espada',
    'gun': 'arma de fuego', 'holding_weapon': 'sosteniendo un arma',
    'holding': 'sosteniendo', 'standing': 'de pie', 'sitting': 'sentada',
    'lying': 'acostada', 'kneeling': 'arrodillada', 'squatting': 'en cuclillas',
    'walking': 'caminando', 'running': 'corriendo', 'jumping': 'saltando',
    'dancing': 'bailando', 'flying': 'volando', 'floating': 'flotando',
    'spread_legs': 'piernas abiertas', 'crossed_legs': 'piernas cruzadas',
    'arms_up': 'brazos arriba', 'hand_on_hip': 'mano en la cadera',
    'tail': 'cola', 'wings': 'alas', 'horns': 'cuernos',
    'animal_ears': 'orejas de animal', 'cat_ears': 'orejas de gato',
    'fox_ears': 'orejas de zorro', 'halo': 'halo', 'chibi': 'chibi',
    'text': 'texto', 'watermark': 'marca de agua', 'signature': 'firma',
    'artist_name': 'nombre del artista', 'english_text': 'texto en inglés',
    'speech_bubble': 'globo de diálogo', 'comic': 'cómic',
    'multiple_views': 'varias vistas', 'twintails': 'coletas gemelas',
    'ponytail': 'cola de caballo', 'braid': 'trenza', 'twin_braids': 'dos trenzas',
    'bangs': 'flequillo', 'hair_between_eyes': 'pelo entre los ojos',
    'ahoge': 'mechón rebelde', 'bare_shoulders': 'hombros descubiertos',
    'bare_arms': 'brazos descubiertos', 'bare_legs': 'piernas descubiertas',
  };

  /// Nombre en español y género/número gramatical del sustantivo al que
  /// se aplican los adjetivos de [_kColorAdjectives] (ver [_translateSuffixTag]).
  static const Map<String, _Wd14SpanishNoun> _kSuffixNouns = {
    'hair': _Wd14SpanishNoun('pelo'),
    'eyes': _Wd14SpanishNoun('ojos', plural: true),
    'background': _Wd14SpanishNoun('fondo'),
    'skirt': _Wd14SpanishNoun('falda', feminine: true),
    'dress': _Wd14SpanishNoun('vestido'),
    'shirt': _Wd14SpanishNoun('camisa', feminine: true),
    'gloves': _Wd14SpanishNoun('guantes', plural: true),
    'thighhighs': _Wd14SpanishNoun('medias', feminine: true, plural: true),
    'shoes': _Wd14SpanishNoun('zapatos', plural: true),
    'hat': _Wd14SpanishNoun('sombrero'),
    'ribbon': _Wd14SpanishNoun('cinta', feminine: true),
    'bow': _Wd14SpanishNoun('lazo'),
    'panties': _Wd14SpanishNoun('bragas', feminine: true, plural: true),
    'sleeves': _Wd14SpanishNoun('mangas', feminine: true, plural: true),
    'skin': _Wd14SpanishNoun('piel', feminine: true),
    'eyeshadow': _Wd14SpanishNoun('sombra de ojos', feminine: true),
  };

  /// Adjetivos (colores, longitudes, texturas) que se combinan con los
  /// sustantivos de [_kSuffixNouns] para etiquetas tipo "blonde_hair",
  /// "long_hair", "blue_eyes"... Se guardan las 4 formas (masculino/
  /// femenino, singular/plural) para que la concordancia sea correcta en
  /// vez de aplicar una regla heurística que podría fallar.
  static const Map<String, _Wd14SpanishAdj> _kColorAdjectives = {
    'blonde': _Wd14SpanishAdj('rubio', 'rubia', 'rubios', 'rubias'),
    'blond': _Wd14SpanishAdj('rubio', 'rubia', 'rubios', 'rubias'),
    'black': _Wd14SpanishAdj('negro', 'negra', 'negros', 'negras'),
    'brown': _Wd14SpanishAdj('castaño', 'castaña', 'castaños', 'castañas'),
    'red': _Wd14SpanishAdj('rojo', 'roja', 'rojos', 'rojas'),
    'pink': _Wd14SpanishAdj('rosa', 'rosa', 'rosas', 'rosas'),
    'blue': _Wd14SpanishAdj('azul', 'azul', 'azules', 'azules'),
    'light_blue': _Wd14SpanishAdj('azul claro', 'azul claro', 'azules claros', 'azules claros'),
    'dark_blue': _Wd14SpanishAdj('azul oscuro', 'azul oscuro', 'azules oscuros', 'azules oscuros'),
    'aqua': _Wd14SpanishAdj('turquesa', 'turquesa', 'turquesas', 'turquesas'),
    'green': _Wd14SpanishAdj('verde', 'verde', 'verdes', 'verdes'),
    'dark_green': _Wd14SpanishAdj('verde oscuro', 'verde oscuro', 'verdes oscuros', 'verdes oscuros'),
    'purple': _Wd14SpanishAdj('morado', 'morada', 'morados', 'moradas'),
    'silver': _Wd14SpanishAdj('plateado', 'plateada', 'plateados', 'plateadas'),
    'grey': _Wd14SpanishAdj('gris', 'gris', 'grises', 'grises'),
    'gray': _Wd14SpanishAdj('gris', 'gris', 'grises', 'grises'),
    'white': _Wd14SpanishAdj('blanco', 'blanca', 'blancos', 'blancas'),
    'orange': _Wd14SpanishAdj('naranja', 'naranja', 'naranjas', 'naranjas'),
    'multicolored': _Wd14SpanishAdj('multicolor', 'multicolor', 'multicolor', 'multicolor'),
    'gradient': _Wd14SpanishAdj('degradado', 'degradada', 'degradados', 'degradadas'),
    'two-tone': _Wd14SpanishAdj('de dos tonos', 'de dos tonos', 'de dos tonos', 'de dos tonos'),
    'streaked': _Wd14SpanishAdj('con mechas', 'con mechas', 'con mechas', 'con mechas'),
    'long': _Wd14SpanishAdj('largo', 'larga', 'largos', 'largas'),
    'short': _Wd14SpanishAdj('corto', 'corta', 'cortos', 'cortas'),
    'medium': _Wd14SpanishAdj('mediano', 'mediana', 'medianos', 'medianas'),
    'very_long': _Wd14SpanishAdj('muy largo', 'muy larga', 'muy largos', 'muy largas'),
    'straight': _Wd14SpanishAdj('liso', 'lisa', 'lisos', 'lisas'),
    'wavy': _Wd14SpanishAdj('ondulado', 'ondulada', 'ondulados', 'onduladas'),
    'curly': _Wd14SpanishAdj('rizado', 'rizada', 'rizados', 'rizadas'),
    'messy': _Wd14SpanishAdj('despeinado', 'despeinada', 'despeinados', 'despeinadas'),
  };

  /// Sustantivos adicionales (partes del cuerpo, ropa, objetos...) para el
  /// compositor GENÉRICO de abajo, que cubre muchas más combinaciones que
  /// [_translateSuffixTag] a cambio de una concordancia algo más simple
  /// (adjetivo en forma base + regla de género/número, en vez de las 4
  /// formas verificadas a mano de [_kColorAdjectives]).
  static const Map<String, _Wd14SpanishNoun> _kGenericNouns = {
    'hair': _Wd14SpanishNoun('pelo'),
    'eyes': _Wd14SpanishNoun('ojos', plural: true),
    'eye': _Wd14SpanishNoun('ojo'),
    'background': _Wd14SpanishNoun('fondo'),
    'skirt': _Wd14SpanishNoun('falda', feminine: true),
    'dress': _Wd14SpanishNoun('vestido'),
    'shirt': _Wd14SpanishNoun('camisa', feminine: true),
    'gloves': _Wd14SpanishNoun('guantes', plural: true),
    'glove': _Wd14SpanishNoun('guante'),
    'thighhighs': _Wd14SpanishNoun('medias', feminine: true, plural: true),
    'shoes': _Wd14SpanishNoun('zapatos', plural: true),
    'shoe': _Wd14SpanishNoun('zapato'),
    'hat': _Wd14SpanishNoun('sombrero'),
    'ribbon': _Wd14SpanishNoun('cinta', feminine: true),
    'bow': _Wd14SpanishNoun('lazo'),
    'panties': _Wd14SpanishNoun('bragas', feminine: true, plural: true),
    'sleeves': _Wd14SpanishNoun('mangas', feminine: true, plural: true),
    'sleeve': _Wd14SpanishNoun('manga', feminine: true),
    'skin': _Wd14SpanishNoun('piel', feminine: true),
    'eyeshadow': _Wd14SpanishNoun('sombra de ojos', feminine: true),
    'socks': _Wd14SpanishNoun('calcetines', plural: true),
    'sock': _Wd14SpanishNoun('calcetín'),
    'boots': _Wd14SpanishNoun('botas', feminine: true, plural: true),
    'boot': _Wd14SpanishNoun('bota', feminine: true),
    'pants': _Wd14SpanishNoun('pantalones', plural: true),
    'shorts': _Wd14SpanishNoun('pantalones cortos', plural: true),
    'swimsuit': _Wd14SpanishNoun('traje de baño'),
    'bikini': _Wd14SpanishNoun('bikini'),
    'legs': _Wd14SpanishNoun('piernas', feminine: true, plural: true),
    'leg': _Wd14SpanishNoun('pierna', feminine: true),
    'arms': _Wd14SpanishNoun('brazos', plural: true),
    'arm': _Wd14SpanishNoun('brazo'),
    'ears': _Wd14SpanishNoun('orejas', feminine: true, plural: true),
    'ear': _Wd14SpanishNoun('oreja', feminine: true),
    'tail': _Wd14SpanishNoun('cola', feminine: true),
    'wings': _Wd14SpanishNoun('alas', feminine: true, plural: true),
    'wing': _Wd14SpanishNoun('ala', feminine: true),
    'lips': _Wd14SpanishNoun('labios', plural: true),
    'lip': _Wd14SpanishNoun('labio'),
    'nails': _Wd14SpanishNoun('uñas', feminine: true, plural: true),
    'collar': _Wd14SpanishNoun('collar'),
    'flower': _Wd14SpanishNoun('flor', feminine: true),
    'flowers': _Wd14SpanishNoun('flores', feminine: true, plural: true),
    'eyebrows': _Wd14SpanishNoun('cejas', feminine: true, plural: true),
    'cheeks': _Wd14SpanishNoun('mejillas', feminine: true, plural: true),
    'teeth': _Wd14SpanishNoun('dientes', plural: true),
    'tongue': _Wd14SpanishNoun('lengua', feminine: true),
    'fingers': _Wd14SpanishNoun('dedos', plural: true),
    'finger': _Wd14SpanishNoun('dedo'),
    'hand': _Wd14SpanishNoun('mano', feminine: true),
    'hands': _Wd14SpanishNoun('manos', feminine: true, plural: true),
    'hips': _Wd14SpanishNoun('caderas', feminine: true, plural: true),
    'waist': _Wd14SpanishNoun('cintura', feminine: true),
    'neck': _Wd14SpanishNoun('cuello'),
    'shoulders': _Wd14SpanishNoun('hombros', plural: true),
    'shoulder': _Wd14SpanishNoun('hombro'),
    'chest': _Wd14SpanishNoun('pecho'),
    'stomach': _Wd14SpanishNoun('estómago'),
    'back': _Wd14SpanishNoun('espalda', feminine: true),
    'feet': _Wd14SpanishNoun('pies', plural: true),
    'foot': _Wd14SpanishNoun('pie'),
    'jacket': _Wd14SpanishNoun('chaqueta', feminine: true),
    'coat': _Wd14SpanishNoun('abrigo'),
    'sweater': _Wd14SpanishNoun('suéter'),
    'apron': _Wd14SpanishNoun('delantal'),
    'cloak': _Wd14SpanishNoun('capa', feminine: true),
    'cape': _Wd14SpanishNoun('capa', feminine: true),
    'scarf': _Wd14SpanishNoun('bufanda', feminine: true),
    'belt': _Wd14SpanishNoun('cinturón'),
    'pocket': _Wd14SpanishNoun('bolsillo'),
    'pockets': _Wd14SpanishNoun('bolsillos', plural: true),
    'umbrella': _Wd14SpanishNoun('paraguas'),
    'bag': _Wd14SpanishNoun('bolso'),
    'backpack': _Wd14SpanishNoun('mochila', feminine: true),
    'sword': _Wd14SpanishNoun('espada', feminine: true),
    'shield': _Wd14SpanishNoun('escudo'),
    'crown': _Wd14SpanishNoun('corona', feminine: true),
    'mask': _Wd14SpanishNoun('máscara', feminine: true),
    'veil': _Wd14SpanishNoun('velo'),
    'bracelet': _Wd14SpanishNoun('brazalete'),
    'necklace': _Wd14SpanishNoun('collar'),
    'ring': _Wd14SpanishNoun('anillo'),
    'freckles': _Wd14SpanishNoun('pecas', feminine: true, plural: true),
    'mole': _Wd14SpanishNoun('lunar'),
    'scar': _Wd14SpanishNoun('cicatriz', feminine: true),
    'petals': _Wd14SpanishNoun('pétalos', plural: true),
    'leaf': _Wd14SpanishNoun('hoja', feminine: true),
    'leaves': _Wd14SpanishNoun('hojas', feminine: true, plural: true),
    'smoke': _Wd14SpanishNoun('humo'),
    'fire': _Wd14SpanishNoun('fuego'),
  };

  /// Adjetivos en forma base (masculino singular) para el compositor
  /// genérico. La concordancia de género/número se deriva con
  /// [_agreeWord] en vez de precomputarse a mano (por eso el diccionario
  /// puede ser mucho más grande que [_kColorAdjectives]).
  static const Map<String, String> _kGenericAdjectives = {
    'blonde': 'rubio', 'blond': 'rubio', 'black': 'negro', 'brown': 'castaño',
    'red': 'rojo', 'pink': 'rosa', 'blue': 'azul', 'aqua': 'turquesa',
    'green': 'verde', 'purple': 'morado', 'silver': 'plateado', 'grey': 'gris',
    'gray': 'gris', 'white': 'blanco', 'orange': 'naranja', 'gold': 'dorado',
    'golden': 'dorado', 'multicolored': 'multicolor', 'gradient': 'degradado',
    'dark': 'oscuro', 'light': 'claro', 'pale': 'pálido',
    'long': 'largo', 'short': 'corto', 'medium': 'mediano', 'small': 'pequeño',
    'large': 'grande', 'big': 'grande', 'huge': 'enorme', 'tiny': 'diminuto',
    'giant': 'gigante', 'thick': 'grueso', 'thin': 'delgado', 'wide': 'ancho',
    'narrow': 'estrecho',
    'straight': 'liso', 'wavy': 'ondulado', 'curly': 'rizado',
    'messy': 'despeinado', 'spiked': 'puntiagudo', 'braided': 'trenzado',
    'frilled': 'con volantes', 'striped': 'de rayas', 'plaid': 'de cuadros',
    'lace': 'de encaje', 'leather': 'de cuero', 'denim': 'de mezclilla',
    'open': 'abierto', 'closed': 'cerrado', 'torn': 'rasgado', 'wet': 'mojado',
    'sheer': 'transparente', 'tight': 'ajustado', 'loose': 'suelto',
    'fitted': 'ajustado', 'detached': 'suelto', 'bare': 'descubierto',
    'exposed': 'expuesto', 'crossed': 'cruzado', 'raised': 'levantado',
    'shiny': 'brillante', 'glowing': 'resplandeciente',
    'transparent': 'transparente', 'floral': 'floral',
  };

  bool _endsInVowel(String s) => s.isNotEmpty && 'aeiouáéíóú'.contains(s[s.length - 1]);

  /// Aplica concordancia de género/número a un adjetivo en forma base
  /// masculina singular. Las frases preposicionales invariables (p. ej.
  /// "de encaje", "de rayas") no se tocan porque en español no varían.
  String _agreeWord(String masc, {required bool feminine, required bool plural}) {
    if (masc.contains(' ')) return masc;
    String form = masc;
    if (feminine && form.endsWith('o')) {
      form = '${form.substring(0, form.length - 1)}a';
    }
    if (plural) {
      form = _endsInVowel(form) ? '${form}s' : '${form}es';
    }
    return form;
  }

  /// Intenta traducir etiquetas compuestas tipo "{adjetivo}_{sustantivo}"
  /// (p. ej. "blonde_hair", "blue_eyes", "white_background") componiendo
  /// el sustantivo en español con la forma del adjetivo que concuerde en
  /// género y número. Devuelve null si no reconoce el patrón, para que
  /// [_translateTag] caiga al inglés en vez de arriesgar una traducción
  /// mal formada.
  String? _translateSuffixTag(String tag) {
    for (final entry in _kSuffixNouns.entries) {
      final suffix = '_${entry.key}';
      if (tag.length > suffix.length && tag.endsWith(suffix)) {
        final prefixKey = tag.substring(0, tag.length - suffix.length);
        final adj = _kColorAdjectives[prefixKey];
        if (adj == null) return null;
        final noun = entry.value;
        final form = noun.plural
            ? (noun.feminine ? adj.femPlural : adj.mascPlural)
            : (noun.feminine ? adj.femSingular : adj.mascSingular);
        return '${noun.es} $form';
      }
    }
    return null;
  }

  /// Compositor genérico, más flexible que [_translateSuffixTag]: separa la
  /// etiqueta por "_"/"-", localiza el ÚLTIMO token que sea un sustantivo
  /// conocido (así "hair" es el núcleo de "long_blonde_hair") y traduce
  /// cada token restante como adjetivo con concordancia automática.
  /// Devuelve null en cuanto encuentra una palabra que no reconoce, en vez
  /// de arriesgar una traducción parcial o mal formada.
  String? _translateGeneric(String tag) {
    final tokens = tag.split(RegExp(r'[_\-]+')).where((t) => t.isNotEmpty).toList();
    if (tokens.length < 2) return null;

    int nounIndex = -1;
    for (int i = tokens.length - 1; i >= 0; i--) {
      if (_kGenericNouns.containsKey(tokens[i])) {
        nounIndex = i;
        break;
      }
    }
    if (nounIndex == -1) return null;

    final noun = _kGenericNouns[tokens[nounIndex]]!;
    final modifierTokens = [
      ...tokens.sublist(0, nounIndex),
      ...tokens.sublist(nounIndex + 1),
    ];
    if (modifierTokens.isEmpty) return noun.es;

    final parts = <String>[];
    for (final tok in modifierTokens) {
      if (tok == 'very') {
        parts.add('muy');
        continue;
      }
      if (tok == 'absurdly' || tok == 'extremely') {
        parts.add('extremadamente');
        continue;
      }
      final adjBase = _kGenericAdjectives[tok];
      if (adjBase == null) return null;
      parts.add(_agreeWord(adjBase, feminine: noun.feminine, plural: noun.plural));
    }
    return '${noun.es} ${parts.join(' ')}';
  }

  Future<String> get _dictionaryPath async => p.join(
      (await getApplicationSupportDirectory()).path, 'wd14_translations_es.json');

  Future<void> _ensureDictionaryLoaded() async {
    if (_dictionaryLoaded) return;
    try {
      final file = File(await _dictionaryPath);
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        _userDictionary = raw.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {
      // Si el archivo no existe o está corrupto, seguimos con un
      // diccionario vacío en vez de romper el etiquetado.
    }
    _dictionaryLoaded = true;
  }

  Future<void> _persistDictionary() async {
    try {
      final file = File(await _dictionaryPath);
      await file.writeAsString(jsonEncode(_userDictionary));
    } catch (_) {}
  }

  /// Devuelve una copia del diccionario "aprendido + manual" para mostrarlo
  /// en la pantalla de ajustes (no incluye el diccionario curado interno,
  /// que no es editable: solo lo que la app fue generando/aprendiendo o lo
  /// que el propio usuario ha añadido a mano).
  /// Devuelve una copia del diccionario curado interno (el que viene
  /// incorporado en el código de la app, no editable directamente). Se usa
  /// en la pantalla de ajustes para mostrarlo junto al diccionario
  /// aprendido/manual; si el usuario "edita" una de estas entradas, se
  /// guarda como una entrada normal en el diccionario del usuario, que
  /// tiene prioridad sobre esta.
  Map<String, String> getBuiltInDictionary() => Map<String, String>.from(_kExactTranslations);

  Future<Map<String, String>> getEditableDictionary() async {
    await _ensureDictionaryLoaded();
    return Map<String, String>.from(_userDictionary);
  }

  /// Añade o corrige a mano la traducción de una etiqueta. Se consulta con
  /// más prioridad que cualquier otra fuente, así que esto también sirve
  /// para arreglar una traducción automática que no haya quedado bien.
  Future<void> setDictionaryEntry(String enTag, String esTranslation) async {
    final key = enTag.trim().toLowerCase();
    final value = esTranslation.trim();
    if (key.isEmpty || value.isEmpty) return;
    await _ensureDictionaryLoaded();
    _userDictionary[key] = value;
    await _persistDictionary();
  }

  Future<void> deleteDictionaryEntry(String enTag) async {
    await _ensureDictionaryLoaded();
    _userDictionary.remove(enTag.trim().toLowerCase());
    await _persistDictionary();
  }

  /// Vacía por completo el diccionario aprendido/manual. Las traducciones
  /// generadas automáticamente se pueden volver a crear solas la próxima
  /// vez que aparezca esa etiqueta; las manuales se pierden.
  Future<void> clearDictionary() async {
    await _ensureDictionaryLoaded();
    _userDictionary.clear();
    await _persistDictionary();
  }

  /// Traduce una etiqueta canónica (con guiones bajos, tal como viene del
  /// CSV del modelo) a español. Es determinista: la misma [rawTag] siempre
  /// da el mismo resultado. Orden de prioridad: diccionario del usuario
  /// (aprendido o manual, para que una corrección del usuario siempre
  /// gane) → diccionario curado interno → patrón adjetivo+sustantivo
  /// preciso → compositor genérico (si acierta, se aprende para la
  /// próxima vez) → inglés sin traducir, como último recurso — y en ese
  /// último caso se deja constancia en el diccionario como "pendiente"
  /// (valor vacío) para que aparezca en Ajustes › Diccionario de
  /// Traducción a la espera de que el usuario le asigne una traducción a
  /// mano, en vez de perderse en silencio cada vez.
  String _translateTag(String rawTag) {
    final key = rawTag.toLowerCase();
    final userDefined = _userDictionary[key];
    if (userDefined != null && userDefined.isNotEmpty) return userDefined;

    final exact = _kExactTranslations[key];
    if (exact != null) return exact;

    final composed = _translateSuffixTag(key);
    if (composed != null) return composed;

    final generic = _translateGeneric(key);
    if (generic != null) {
      _userDictionary[key] = generic;
      _dictionaryDirty = true;
      return generic;
    }

    // No se pudo traducir de ninguna forma disponible. Si es la primera
    // vez que aparece esta etiqueta, se marca como "pendiente" (traducción
    // vacía); si ya lo estaba, no hace falta volver a escribirla ni
    // marcar el diccionario como "sucio" otra vez.
    if (userDefined == null) {
      _userDictionary[key] = '';
      _dictionaryDirty = true;
    }
    return rawTag.replaceAll('_', ' ').trim();
  }

  String _formatTagName(String rawTag) {
    if (_kaomojiTags.contains(rawTag)) return rawTag;
    if (_translateToSpanish) return _translateTag(rawTag);
    return rawTag.replaceAll('_', ' ').trim();
  }

  Future<List<String>> _tagFile(File file) async {
    final uri = Uri.parse('$baseUrl/tag').replace(queryParameters: {
      'general_threshold': _generalThreshold.toString(),
      'character_threshold': _characterThreshold.toString(),
      'max_tags': _maxTags.toString(),
    });

    final request = http.MultipartRequest('POST', uri);
    // El servidor detecta el formato real por el contenido de los bytes
    // (Pillow no mira la extensión), así que el nombre que mandamos aquí
    // solo es cosmético para los logs; usamos la extensión real descifrada
    // en vez de ".vtx" para que esos logs tengan sentido.
    var realExt = _realExtensionOf(file.path);
    var sourceFile = file;
    // El servidor (Pillow) no lee AVIF: se manda la copia JPEG que genera
    // ThumbnailService (queda en caché, así que no se reconvierte cada vez).
    final thumbs = ThumbnailService();
    if (thumbs.isAvif(file.path)) {
      final converted = await thumbs.getViewableFile(file);
      if (!identical(converted, file)) {
        sourceFile = converted;
        realExt = '.jpg';
      }
    }
    request.files.add(await http.MultipartFile.fromPath(
      'file',
      sourceFile.path,
      filename: 'image${realExt.isNotEmpty ? realExt : '.jpg'}',
    ));

    final streamedResponse = await request.send().timeout(const Duration(seconds: 30));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final tagsList = (data['tags'] as List).cast<Map<String, dynamic>>();
    if (_translateToSpanish) await _ensureDictionaryLoaded();
    // El servidor ya ordena por confianza y recorta a max_tags, pero
    // recortamos también aquí por si el servidor instalado es una versión
    // vieja que todavía no soporta este parámetro (defensa en profundidad).
    final result = tagsList
        .map((t) => _formatTagName(t['tag'] as String))
        .where((t) => t.isNotEmpty)
        .take(_maxTags)
        .toList();
    if (_dictionaryDirty) {
      _dictionaryDirty = false;
      // Guardado en segundo plano: no bloqueamos el etiquetado por esto.
      _persistDictionary();
    }
    return result;
  }

  // Script de instalación embebido: así basta con copiar este único
  // archivo .dart al proyecto, sin tener que declarar assets en
  // pubspec.yaml. El mismo contenido también se entrega como archivo
  // .ps1 aparte solo para que puedas revisarlo/auditarlo más cómodo.
  static const String _installerScript = r'''
# ============================================================
#  WD14 Tagger Server - Instalador / Desinstalador para Windows
#  Compatible con Gallery Vortex
#
#  Uso (invocado normalmente desde la app Flutter):
#    install_wd14_tagger.ps1 -InstallDir "<ruta>" -Port 5010
#    install_wd14_tagger.ps1 -InstallDir "<ruta>" -Uninstall
#    install_wd14_tagger.ps1 -InstallDir "<ruta>" -Port 5010 -Force   (reinstala desde cero)
#
#  Progreso parseable en stdout (para que la app pueda mostrar una
#  barra de progreso real en vez de adivinar por texto libre):
#    ##WD14PROGRESS## <paso>/<total> <mensaje>
#    ##WD14DONE##
#    ##WD14ERROR## <mensaje>
# ============================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$InstallDir,

    [int]$Port = 5010,

    [string]$ModelRepo = "SmilingWolf/wd-swinv2-tagger-v3",

    [string]$BindHost = "127.0.0.1",

    [switch]$Uninstall,

    [switch]$Force
)

$ErrorActionPreference = "Stop"
# En PowerShell 7.3+ los ejecutables nativos que escriben en stderr pueden
# convertirse en errores terminantes incluso con "2>$null" cuando
# $ErrorActionPreference = "Stop" (p. ej. "pip show <paquete-no-instalado>",
# que escribe un WARNING en stderr). Desactivamos esa conversión: seguimos
# comprobando errores nosotros mismos via $LASTEXITCODE / try-catch.
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"

try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { }

if ($Port -lt 1 -or $Port -gt 65535) {
    Write-Host "##WD14ERROR## Puerto invalido: $Port"
    exit 1
}

$ManifestPath = Join-Path $InstallDir "install_manifest.json"

function Write-Step {
    param([int]$Step, [int]$Total, [string]$Message)
    Write-Host "##WD14PROGRESS## $Step/$Total $Message"
}

# ============================================================
#  DESINSTALACION
# ============================================================
if ($Uninstall) {
    $TotalSteps = 3
    Write-Step 1 $TotalSteps "Deteniendo servidor si esta activo..."

    # Si hay un proceso python.exe corriendo desde nuestro venv, lo matamos.
    # Identificamos por ruta del ejecutable, no por nombre generico "python",
    # para no matar otros procesos python del sistema del usuario.
    try {
        $venvPython = Join-Path $InstallDir "venv\Scripts\python.exe"
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $venvPython) }
        foreach ($proc in $procs) {
            # En Windows el python.exe del venv es solo un lanzador: el proceso
            # que de verdad tiene cargado el modelo es su HIJO (el python base).
            # Hay que matar primero al hijo o queda huerfano con archivos abiertos.
            try {
                $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($proc.ProcessId)" -ErrorAction SilentlyContinue
                foreach ($child in $children) {
                    try { Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
                }
            } catch { }
            try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    } catch { }

    Write-Step 2 $TotalSteps "Eliminando archivos instalados..."
    if (Test-Path $InstallDir) {
        try {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host "##WD14ERROR## No se pudo borrar por completo $InstallDir : $($_.Exception.Message)"
            exit 1
        }
    }

    Write-Step 3 $TotalSteps "Desinstalacion completada"
    Write-Host "##WD14DONE##"
    exit 0
}

# ============================================================
#  INSTALACION
# ============================================================
$TotalSteps = 8

if ($Force -and (Test-Path $InstallDir)) {
    Write-Host "-> -Force activo: eliminando instalacion previa..." -ForegroundColor Yellow
    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  WD14 Tagger Server - Instalador" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ---------- 1. Verificar Python ----------
Write-Step 1 $TotalSteps "Verificando Python"
$pyCmd = $null
foreach ($candidate in @("python", "python3", "py")) {
    try {
        $ver = & $candidate --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $pyCmd = $candidate
            Write-Host "   Encontrado: $ver" -ForegroundColor Green
            break
        }
    } catch { }
}
if (-not $pyCmd) {
    Write-Host "##WD14ERROR## Python no esta instalado o no esta en el PATH. Descargalo desde https://www.python.org/downloads/ (marca 'Add to PATH')"
    exit 1
}

# ---------- 2. Carpeta y venv (idempotente) ----------
Write-Step 2 $TotalSteps "Preparando entorno virtual"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}
Set-Location $InstallDir

$venvAlreadyExisted = Test-Path (Join-Path $InstallDir "venv\Scripts\python.exe")
if (-not $venvAlreadyExisted) {
    Write-Host "-> Creando entorno virtual..." -ForegroundColor Yellow
    & $pyCmd -m venv venv
    if ($LASTEXITCODE -ne 0) {
        Write-Host "##WD14ERROR## Fallo creando el entorno virtual"
        exit 1
    }
} else {
    Write-Host "   Entorno virtual ya existente, se reutiliza." -ForegroundColor DarkGray
}

$activateScript = Join-Path $InstallDir "venv\Scripts\Activate.ps1"
if (-not (Test-Path $activateScript)) {
    Write-Host "##WD14ERROR## No se encontro Activate.ps1 en el entorno virtual"
    exit 1
}
& $activateScript

# ---------- 3. Dependencias base ----------
Write-Step 3 $TotalSteps "Instalando dependencias base (fastapi, pillow, etc.)"
python -m pip install --upgrade pip --quiet
if ($LASTEXITCODE -ne 0) { Write-Host "   Advertencia: no se pudo actualizar pip" -ForegroundColor DarkYellow }

python -m pip install --quiet fastapi "uvicorn[standard]" python-multipart pillow numpy huggingface-hub
if ($LASTEXITCODE -ne 0) {
    Write-Host "##WD14ERROR## Fallo instalando dependencias base"
    exit 1
}

# ---------- 4. Detectar GPU y elegir onnxruntime ----------
Write-Step 4 $TotalSteps "Detectando GPU e instalando onnxruntime"

function Test-PipPackageInstalled {
    param([string]$PackageName)
    try {
        # *>$null silencia TODOS los streams (incluido stderr), y no
        # dependemos de que la redireccion coincida con el comportamiento
        # de $ErrorActionPreference: solo miramos el codigo de salida real.
        & python -m pip show $PackageName *>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

$alreadyHasOnnx = (Test-PipPackageInstalled 'onnxruntime') -or
                   (Test-PipPackageInstalled 'onnxruntime-gpu') -or
                   (Test-PipPackageInstalled 'onnxruntime-directml')

if (-not $alreadyHasOnnx) {
    $gpuNames = ""
    try {
        $gpuNames = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                     Select-Object -ExpandProperty Name) -join " | "
    } catch { }
    Write-Host "   GPUs detectadas: $gpuNames" -ForegroundColor DarkGray

    $hasNvidia     = $gpuNames -match "NVIDIA"
    $hasAmdOrIntel = $gpuNames -match "AMD|Radeon|Intel"

    if ($hasNvidia) {
        Write-Host "   GPU NVIDIA detectada -> onnxruntime-gpu" -ForegroundColor Yellow
        python -m pip install --quiet onnxruntime-gpu
        if ($LASTEXITCODE -ne 0) {
            Write-Host "   Fallo onnxruntime-gpu, usando CPU" -ForegroundColor DarkYellow
            python -m pip install --quiet onnxruntime
        }
    } elseif ($hasAmdOrIntel) {
        Write-Host "   GPU AMD/Intel detectada -> onnxruntime-directml" -ForegroundColor Yellow
        python -m pip install --quiet onnxruntime-directml
        if ($LASTEXITCODE -ne 0) {
            Write-Host "   Fallo onnxruntime-directml, usando CPU" -ForegroundColor DarkYellow
            python -m pip install --quiet onnxruntime
        }
    } else {
        Write-Host "   Sin GPU compatible, usando CPU" -ForegroundColor DarkYellow
        python -m pip install --quiet onnxruntime
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "##WD14ERROR## Fallo instalando onnxruntime"
        exit 1
    }
} else {
    Write-Host "   onnxruntime ya instalado, se reutiliza." -ForegroundColor DarkGray
}

# ---------- 5. Descargar modelo (idempotente, no re-descarga si ya existe) ----------
Write-Step 5 $TotalSteps "Descargando modelo IA (~470 MB, solo la primera vez)"
New-Item -ItemType Directory -Force -Path "models" | Out-Null

$modelOnnxPath = Join-Path $InstallDir "models\model.onnx"
$tagsCsvPath   = Join-Path $InstallDir "models\selected_tags.csv"
$modelAlreadyDownloaded = (Test-Path $modelOnnxPath) -and (Test-Path $tagsCsvPath) -and
                          ((Get-Item $modelOnnxPath).Length -gt 1MB)

if (-not $modelAlreadyDownloaded) {
    $downloadPy = @"
from huggingface_hub import hf_hub_download

for fname in ['model.onnx', 'selected_tags.csv']:
    print(f'Descargando {fname}...')
    hf_hub_download(
        repo_id='$ModelRepo',
        filename=fname,
        local_dir='models',
    )
print('Modelo descargado correctamente')
"@
    $downloadPy | Out-File -FilePath "download_model.py" -Encoding utf8
    python download_model.py
    $downloadExit = $LASTEXITCODE
    Remove-Item "download_model.py" -Force -ErrorAction SilentlyContinue
    if ($downloadExit -ne 0) {
        Write-Host "##WD14ERROR## Fallo descargando el modelo"
        exit 1
    }
} else {
    Write-Host "   Modelo ya descargado, se reutiliza." -ForegroundColor DarkGray
}

# ---------- 6. Generar server.py ----------
Write-Step 6 $TotalSteps "Generando servidor"

# Usamos here-string LITERAL (comillas simples) para que nada de lo que
# escribamos en Python ($ de f-strings, comillas, etc.) sea interpretado
# por PowerShell. Los valores dinamicos se inyectan despues via -replace
# sobre marcadores unicos, para evitar cualquier colision de sintaxis.
$serverPyTemplate = @'
"""
WD14 Tagger Server - Generado por Gallery Vortex
"""

import os
import io
import time
import logging
import gc
import csv
import threading
from typing import List
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from PIL import Image
from fastapi import FastAPI, UploadFile, File, Query, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
import onnxruntime as ort

# ==================== Configuracion ====================
PORT = __WD14_PORT__
BIND_HOST = "__WD14_BIND_HOST__"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
MODEL_PATH = os.path.join(BASE_DIR, "models", "model.onnx")
TAGS_PATH = os.path.join(BASE_DIR, "models", "selected_tags.csv")
MAX_WORKERS = 4
MAX_BATCH_SIZE = 16
MAX_FILE_SIZE = 30 * 1024 * 1024  # 30 MB por archivo

# Segundos sin usarse tras los cuales el modelo se descarga de la RAM (0 = nunca).
# El proceso sigue vivo con poca memoria y el modelo se vuelve a cargar solo en
# la siguiente peticion. La app lo fija al iniciar y puede cambiarlo con POST /config.
def _read_idle_seconds() -> int:
    try:
        return max(0, int(os.environ.get("WD14_IDLE_UNLOAD_SECONDS", "300")))
    except ValueError:
        return 300

IDLE_UNLOAD_SECONDS = _read_idle_seconds()
IDLE_CHECK_INTERVAL = 10

# Categorias del CSV de WD14: 0=general, 1=artist, 3=copyright, 4=character,
# 5=meta, 9=rating. Solo etiquetamos con general + character: es lo que
# produce descripciones de contenido utiles; el resto (artista, copyright,
# rating SFW/NSFW, metadatos de calidad de imagen) solo añade ruido.
GENERAL_CATEGORY = 0
CHARACTER_CATEGORY = 4
TAGGABLE_CATEGORIES = {GENERAL_CATEGORY, CHARACTER_CATEGORY}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("wd-tagger")

# ==================== Carga del modelo ====================
def build_session():
    available = ort.get_available_providers()
    preferred = []
    if "CUDAExecutionProvider" in available:
        preferred.append("CUDAExecutionProvider")
    if "DmlExecutionProvider" in available:
        preferred.append("DmlExecutionProvider")
    preferred.append("CPUExecutionProvider")

    # Menos memoria retenida: sin el "arena" de la CPU ORT devuelve al sistema
    # los buffers temporales de cada inferencia en vez de quedarse con ellos, y
    # sin "mem pattern" no se reserva por adelantado el pico de memoria (DirectML
    # ademas exige tenerlo desactivado). El coste en velocidad es minimo.
    opts = ort.SessionOptions()
    opts.enable_cpu_mem_arena = False
    opts.enable_mem_pattern = False
    opts.log_severity_level = 3

    # Si el proveedor acelerado falla en tiempo de ejecucion (DLL de CUDA/GPU
    # ausente, drivers desactualizados, etc.) aunque el paquete se instalara
    # bien, caemos a CPU en vez de tumbar el servidor entero.
    try:
        sess = ort.InferenceSession(MODEL_PATH, sess_options=opts, providers=preferred)
        logger.info("Proveedores activos: %s", sess.get_providers())
        return sess
    except Exception as e:
        if preferred != ["CPUExecutionProvider"]:
            logger.warning("Fallo cargando con %s (%s); reintentando solo con CPU", preferred, e)
            return ort.InferenceSession(MODEL_PATH, sess_options=opts, providers=["CPUExecutionProvider"])
        raise

# Estado del modelo. Se carga al iniciar y se descarga tras un rato sin uso.
_session_lock = threading.Lock()
_session = None
_input_name = None
_model_size = 448
_providers = []
_active_runs = 0
_last_used = time.monotonic()

def _load_model_locked():
    """Carga el modelo. Hay que llamarla con _session_lock tomado."""
    global _session, _input_name, _model_size, _providers
    started = time.time()
    logger.info("Cargando modelo ONNX...")
    sess = build_session()
    input_meta = sess.get_inputs()[0]
    input_shape = input_meta.shape
    # Alto/ancho esperado por el modelo (normalmente 448x448 para wd-v3).
    # Detectamos el tamano sin asumir el orden de canales (NCHW vs NHWC):
    # tomamos la dimension mas grande que no sea el batch (1) ni los canales (3).
    try:
        candidates = [int(d) for d in input_shape if isinstance(d, int) and d not in (1, 3)]
        size = max(candidates) if candidates else 448
    except (TypeError, ValueError):
        size = 448
    _input_name = input_meta.name
    _model_size = size
    _providers = list(sess.get_providers())
    _session = sess
    logger.info("Modelo cargado en %.1f s. Input shape: %s (usando %dx%d)",
                time.time() - started, input_shape, size, size)

def _trim_working_set():
    """Pide a Windows que devuelva ya la memoria liberada (si no, el Administrador
    de tareas tarda en reflejar la bajada)."""
    if os.name != "nt":
        return
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        kernel32.GetCurrentProcess.restype = ctypes.c_void_p
        kernel32.SetProcessWorkingSetSize.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t]
        kernel32.SetProcessWorkingSetSize(kernel32.GetCurrentProcess(), ctypes.c_size_t(-1), ctypes.c_size_t(-1))
    except Exception:
        pass

def _unload_model_locked():
    """Descarga el modelo de la RAM. Hay que llamarla con _session_lock tomado."""
    global _session
    _session = None
    gc.collect()
    _trim_working_set()

def acquire_session():
    """Devuelve (sesion, nombre_entrada, tamano) cargando el modelo si hace falta,
    y lo 'ancla' para que no se descargue mientras se usa."""
    global _active_runs, _last_used
    with _session_lock:
        if _session is None:
            _load_model_locked()
        _active_runs += 1
        _last_used = time.monotonic()
        return _session, _input_name, _model_size

def release_session():
    global _active_runs, _last_used
    with _session_lock:
        _active_runs = max(0, _active_runs - 1)
        _last_used = time.monotonic()

def _idle_watcher():
    while True:
        time.sleep(IDLE_CHECK_INTERVAL)
        try:
            limit = IDLE_UNLOAD_SECONDS
            if limit <= 0:
                continue
            with _session_lock:
                if (_session is not None and _active_runs == 0
                        and time.monotonic() - _last_used >= limit):
                    _unload_model_locked()
                    logger.info("Modelo descargado de la RAM tras %d s sin uso "
                                "(se recargara solo en la proxima imagen).", limit)
        except Exception as e:
            logger.warning("Error en el vigilante de inactividad: %s", e)

# Carga inicial (asi el servidor solo responde cuando ya esta listo para etiquetar).
with _session_lock:
    _load_model_locked()
threading.Thread(target=_idle_watcher, daemon=True).start()

# Solo se leen las columnas necesarias. (Antes se usaba pandas, que por si solo
# ocupa decenas de MB de RAM y tarda en importarse.)
tag_names = []
tag_categories = []
with open(TAGS_PATH, newline="", encoding="utf-8") as _f:
    for _row in csv.DictReader(_f):
        tag_names.append(_row["name"])
        tag_categories.append(int(_row["category"]))

# ==================== Utilidades ====================
# El preprocesado de abajo es un espejo deliberado de `prepare_image()` en
# la demo oficial de HuggingFace (SmilingWolf/wd-tagger, app.py), para que
# el resultado coincida con esa referencia en vez de con una reinterpretacion
# nuestra. Dos detalles que NO son intuitivos pero son asi en el original:
#   1. Los pixeles se mandan en su rango original 0-255 (NO se divide entre
#      255). Normalizarlos hacia 0-1 hace que el modelo vea una imagen casi
#      negra sin importar cual sea la real, y saca etiquetas genericas de
#      imagen oscura/plana (esto era un bug nuestro: "monochrome", "dark",
#      "simple background" en CUALQUIER imagen).
#   2. Los canales van al final (NHWC), no al principio (NCHW).
def preprocess(image: Image.Image, size: int) -> np.ndarray:
    # 1. Aplanar transparencia sobre fondo blanco (igual con o sin alpha).
    if image.mode != "RGBA":
        image = image.convert("RGBA")
    canvas = Image.new("RGBA", image.size, (255, 255, 255))
    canvas.alpha_composite(image)
    image = canvas.convert("RGB")

    # 2. Pad a cuadrado con fondo blanco ANTES de escalar. El modelo se
    #    entreno con imagenes cuadradas; si solo hacemos resize() directo
    #    se distorsiona el aspecto y baja mucho la precision de las tags.
    w, h = image.size
    max_dim = max(w, h)
    pad_left = (max_dim - w) // 2
    pad_top = (max_dim - h) // 2
    padded_image = Image.new("RGB", (max_dim, max_dim), (255, 255, 255))
    padded_image.paste(image, (pad_left, pad_top))

    # 3. Escalar al tamano de entrada del modelo
    if max_dim != size:
        padded_image = padded_image.resize((size, size), Image.Resampling.BICUBIC)

    arr = np.asarray(padded_image, dtype=np.float32)
    arr = arr[:, :, ::-1]  # RGB -> BGR (asi entrenaron el modelo)
    # SIN division entre 255: el modelo espera 0-255, no 0-1.
    return np.expand_dims(arr, axis=0)  # HWC -> NHWC

def to_probabilities(raw_outputs: np.ndarray) -> np.ndarray:
    """Convierte la salida cruda del modelo a probabilidades 0..1.

    Segun como se exporto el grafo ONNX, la sigmoide final puede venir ya
    incluida dentro del propio modelo (salida ya en 0..1) o no (logits
    crudos sin acotar, que pueden ser negativos o mayores a 1). Si
    aplicamos sigmoid() sobre valores que YA son probabilidades, el
    resultado queda comprimido entre 0.5 y ~0.73 para CUALQUIER imagen
    (sigmoid(0)=0.5, sigmoid(1)=0.731), lo que hace que practicamente
    todas las etiquetas del vocabulario superen cualquier umbral razonable
    sin importar si aparecen en la imagen (esto es justo lo que causaba
    miles de etiquetas irrelevantes). Detectamos el caso automaticamente
    en vez de asumirlo, para que funcione con cualquiera de los dos tipos
    de export.
    """
    if raw_outputs.min() >= -1e-4 and raw_outputs.max() <= 1.0 + 1e-4:
        return raw_outputs  # el grafo ya devuelve probabilidades
    return 1.0 / (1.0 + np.exp(-raw_outputs))  # logits crudos: aplicar sigmoide

def postprocess(probs: np.ndarray, general_th: float, character_th: float, max_tags: int):
    results = []
    for i, prob in enumerate(probs):
        category = int(tag_categories[i])
        if category not in TAGGABLE_CATEGORIES:
            continue
        threshold = character_th if category == CHARACTER_CATEGORY else general_th
        if prob > threshold:
            results.append({
                "tag": tag_names[i],
                "confidence": round(float(prob), 4),
                "category": category,
            })
    # Nos quedamos solo con las de mejor confianza, hasta max_tags.
    results.sort(key=lambda x: x["confidence"], reverse=True)
    return results[:max_tags]

def tag_single_image(image_bytes: bytes, general_th: float, character_th: float, max_tags: int):
    sess, input_name, model_size = acquire_session()
    try:
        with Image.open(io.BytesIO(image_bytes)) as image:
            tensor = preprocess(image, model_size)
        outputs = sess.run(None, {input_name: tensor})[0][0]
    finally:
        release_session()
    probs = to_probabilities(outputs)
    tags = postprocess(probs, general_th, character_th, max_tags)
    return {
        "tags": tags,
        "tag_string": ", ".join(t["tag"] for t in tags),
        "count": len(tags),
    }

# ==================== App FastAPI ====================
app = FastAPI(
    title="WD14 Tagger Server",
    description="Servidor local de etiquetado para Gallery Vortex",
    version="2.5.0",
)

# Solo local: el servidor se bindea a 127.0.0.1 por defecto (ver BIND_HOST),
# asi que un CORS abierto no expone nada fuera de la maquina del usuario.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

queue_status = {"processing": 0, "completed": 0, "errors": 0}

# ==================== Endpoints ====================

@app.get("/")
def root():
    return {
        "status": "online",
        "service": "WD14 Tagger",
        "version": "2.5.0",
        "port": PORT,
    }

@app.get("/health")
def health():
    return {
        # Sin tomar _session_lock: debe responder aunque el modelo se este
        # recargando en ese momento.
        "status": "healthy",
        "model_loaded": _session is not None,
        "idle_unload_seconds": IDLE_UNLOAD_SECONDS,
        "providers": _providers,
        "model": MODEL_PATH,
        "tags_loaded": len(tag_names),
        "queue": queue_status,
    }

@app.post("/tag")
def tag_image(
    file: UploadFile = File(...),
    general_threshold: float = Query(0.35, ge=0.0, le=1.0),
    character_threshold: float = Query(0.85, ge=0.0, le=1.0),
    max_tags: int = Query(25, ge=1, le=200),
):
    """Etiqueta una sola imagen."""
    try:
        contents = file.file.read()
        if len(contents) > MAX_FILE_SIZE:
            raise HTTPException(400, "Imagen demasiado grande (max 30 MB)")

        start = time.time()
        result = tag_single_image(contents, general_threshold, character_threshold, max_tags)
        result["filename"] = file.filename
        result["processing_time"] = round(time.time() - start, 3)
        return result

    except HTTPException:
        raise
    except Exception as e:
        logger.error("Error etiquetando %s: %s", file.filename, e)
        raise HTTPException(500, f"Error procesando imagen: {e}")

@app.post("/tag/batch")
def tag_batch(
    files: List[UploadFile] = File(...),
    general_threshold: float = Query(0.35, ge=0.0, le=1.0),
    character_threshold: float = Query(0.85, ge=0.0, le=1.0),
    max_tags: int = Query(25, ge=1, le=200),
):
    """Etiqueta varias imagenes a la vez (max 16)."""
    if len(files) > MAX_BATCH_SIZE:
        raise HTTPException(400, f"Maximo {MAX_BATCH_SIZE} imagenes por batch")

    payloads = []
    for f in files:
        data = f.file.read()
        if len(data) > MAX_FILE_SIZE:
            payloads.append((f.filename, None, "Imagen demasiado grande (max 30 MB)"))
        else:
            payloads.append((f.filename, data, None))

    queue_status["processing"] += len(payloads)
    results = []

    try:
        with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            futures = []
            for name, data, err in payloads:
                if err:
                    futures.append(None)
                else:
                    futures.append(
                        executor.submit(
                            tag_single_image, data, general_threshold, character_threshold, max_tags
                        )
                    )

            for i, fut in enumerate(futures):
                name = payloads[i][0]
                if fut is None:
                    results.append({"filename": name, "error": payloads[i][2]})
                    queue_status["errors"] += 1
                else:
                    try:
                        res = fut.result()
                        res["filename"] = name
                        results.append(res)
                        queue_status["completed"] += 1
                    except Exception as e:
                        results.append({"filename": name, "error": str(e)})
                        queue_status["errors"] += 1
                queue_status["processing"] -= 1

        return {"count": len(results), "results": results}

    except Exception as e:
        queue_status["processing"] = max(0, queue_status["processing"] - len(payloads))
        raise HTTPException(500, str(e))

@app.get("/info")
def info():
    return {
        "model": "__WD14_MODEL_REPO__",
        "total_tags": len(tag_names),
        "providers": _providers,
        "max_batch_size": MAX_BATCH_SIZE,
        "endpoints": {
            "single": "POST /tag",
            "batch": "POST /tag/batch",
            "health": "GET /health",
            "shutdown": "POST /shutdown",
        },
    }

def _require_localhost(request: Request):
    client_host = request.client.host if request.client else None
    if client_host not in ("127.0.0.1", "::1", "localhost"):
        raise HTTPException(403, "Solo se permite desde localhost")

@app.post("/config")
def set_config(request: Request, idle_unload_seconds: int = Query(..., ge=0, le=86400)):
    """Cambia en caliente tras cuantos segundos sin uso se descarga el modelo
    de la RAM (0 = nunca)."""
    global IDLE_UNLOAD_SECONDS
    _require_localhost(request)
    IDLE_UNLOAD_SECONDS = idle_unload_seconds
    return {"idle_unload_seconds": IDLE_UNLOAD_SECONDS}

@app.post("/shutdown")
def shutdown(request: Request):
    """Apagado ordenado. Solo se acepta desde localhost: este endpoint
    permite a la app pedir un cierre limpio de uvicorn en vez de matar
    el proceso a la fuerza desde fuera."""
    _require_localhost(request)

    def _stop():
        time.sleep(0.3)
        os._exit(0)

    threading.Thread(target=_stop, daemon=True).start()
    return {"status": "shutting_down"}

# ==================== Arranque ====================
if __name__ == "__main__":
    import uvicorn
    logger.info("Iniciando servidor en http://%s:%s", BIND_HOST, PORT)
    uvicorn.run(app, host=BIND_HOST, port=PORT, log_level="info")
'@

$serverPy = $serverPyTemplate.
    Replace('__WD14_PORT__', [string]$Port).
    Replace('__WD14_BIND_HOST__', $BindHost).
    Replace('__WD14_MODEL_REPO__', $ModelRepo)

$serverPy | Out-File -FilePath "server.py" -Encoding utf8

# ---------- 7. Script de arranque manual (doble clic) ----------
Write-Step 7 $TotalSteps "Generando accesos directos"
$startBatTemplate = @'
@echo off
title WD14 Tagger Server
cd /d "%~dp0"
call venv\Scripts\activate.bat
echo.
echo  Iniciando WD14 Tagger Server...
echo  URL:  http://__WD14_BIND_HOST__:__WD14_PORT__
echo  Docs: http://__WD14_BIND_HOST__:__WD14_PORT__/docs
echo.
python server.py
pause
'@
$startBat = $startBatTemplate.
    Replace('__WD14_PORT__', [string]$Port).
    Replace('__WD14_BIND_HOST__', $BindHost)
$startBat | Out-File -FilePath "start_server.bat" -Encoding ascii

# ---------- 8. Manifest para que la app sepa que quedo instalado ----------
Write-Step 8 $TotalSteps "Finalizando instalacion"
$manifest = [ordered]@{
    version       = "2.5.0"
    installedAt   = (Get-Date).ToString("o")
    installDir    = $InstallDir
    port          = $Port
    bindHost      = $BindHost
    modelRepo     = $ModelRepo
    pythonExe     = (Join-Path $InstallDir "venv\Scripts\python.exe")
    serverScript  = (Join-Path $InstallDir "server.py")
    startBat      = (Join-Path $InstallDir "start_server.bat")
}
$manifest | ConvertTo-Json | Out-File -FilePath $ManifestPath -Encoding utf8

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  Instalacion completada correctamente" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host "Carpeta de instalacion: $InstallDir"
Write-Host "##WD14DONE##"
''';
}