// wd14_tagger_dialog.dart
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';

import 'metadata_service.dart';
import 'ui_utils.dart';
import 'wd14_tagger_service.dart';

const Color _kAccent = Color(0xFF0A84FF);
const Color _kPanelColor = Color(0xFF1C1C1E);
const Color _kSurfaceColor = Color(0xFF252525);

class Wd14TaggerDialog extends StatefulWidget {
  final MetadataService metadataService;
  final String vaultRootPath;

  const Wd14TaggerDialog({
    super.key,
    required this.metadataService,
    required this.vaultRootPath,
  });

  @override
  State<Wd14TaggerDialog> createState() => _Wd14TaggerDialogState();
}

class _Wd14TaggerDialogState extends State<Wd14TaggerDialog> {
  final Wd14TaggerService _service = Wd14TaggerService.instance;

  final List<String> _logLines = [];
  final ScrollController _logScrollController = ScrollController();
  StreamSubscription<String>? _logSub;
  bool _showLog = false;
  bool _showAdvanced = false;

  int? _resumeCount;
  bool _checkingResume = false;

  bool _wasTaggingRunning = false;

  // Espejo local de las "opciones avanzadas". Los getters de
  // Wd14TaggerService (_service.generalThreshold, etc.) son correctos,
  // pero el widget los leía directamente en cada build() sin ningún
  // estado propio: como los setters del servicio son `async` (escriben en
  // SharedPreferences), el slider podía quedarse mostrando el valor viejo
  // hasta el siguiente repintado por otro motivo (por eso había que
  // contraer/expandir el panel para "refrescarlo"). Con un espejo local
  // que se actualiza de forma síncrona en el mismo setState del gesto, el
  // control SIEMPRE se ve al instante, y el guardado al servicio/disco
  // ocurre en segundo plano sin bloquear la UI.
  double _generalThreshold = Wd14TaggerService.kDefaultGeneralThreshold;
  double _characterThreshold = Wd14TaggerService.kDefaultCharacterThreshold;
  int _maxTags = Wd14TaggerService.kDefaultMaxTags;
  bool _onlyUntagged = Wd14TaggerService.kDefaultOnlyUntagged;
  bool _translateToSpanish = Wd14TaggerService.kDefaultTranslateToSpanish;
  bool _autoTagOnAbsorb = Wd14TaggerService.kDefaultAutoTagOnAbsorb;
  int _idleUnloadMinutes = Wd14TaggerService.kDefaultIdleUnloadMinutes;

  @override
  void initState() {
    super.initState();
    _logSub = _service.logStream.listen(_onLogLine);
    _service.taggingProgress.addListener(_onTaggingProgressChanged);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _service.initialize();
    _generalThreshold = _service.generalThreshold;
    _characterThreshold = _service.characterThreshold;
    _maxTags = _service.maxTags;
    _onlyUntagged = _service.onlyUntagged;
    _translateToSpanish = _service.translateToSpanish;
    _autoTagOnAbsorb = _service.autoTagOnAbsorb;
    _idleUnloadMinutes = _service.idleUnloadMinutes;
    await _refreshResumeCount();
    if (mounted) setState(() {});
  }

  Future<void> _refreshResumeCount() async {
    if (!mounted || !_service.isSupportedPlatform) return;
    setState(() => _checkingResume = true);
    final count = await _service.pendingResumeCount(widget.vaultRootPath);
    if (!mounted) return;
    setState(() {
      _resumeCount = count;
      _checkingResume = false;
    });
  }

  void _onLogLine(String line) {
    if (!mounted) return;
    setState(() {
      _logLines.add(line);
      if (_logLines.length > 400) _logLines.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _service.taggingProgress.removeListener(_onTaggingProgressChanged);
    _logScrollController.dispose();
    super.dispose();
  }

  void _onTaggingProgressChanged() {
    final progress = _service.taggingProgress.value;
    // Detecta la transición "corriendo" -> "parado" para avisar con un
    // snackbar aunque el usuario haya cambiado de pestaña dentro del diálogo,
    // o incluso si vuelve a abrir el diálogo más tarde y ya había terminado.
    if (_wasTaggingRunning && !progress.isRunning && mounted) {
      if (progress.done > 0) {
        showGlassSnackBar(
          context,
          'Etiquetado: ${progress.done} imágenes procesadas'
          '${progress.errors > 0 ? " (${progress.errors} con error)" : ""}',
          icon: Icons.auto_awesome,
          iconColor: _kAccent,
        );
      } else if (progress.errors > 0) {
        showGlassSnackBar(
          context,
          'El etiquetado se detuvo sin procesar imágenes.',
          icon: Icons.error_outline,
          iconColor: Colors.redAccent,
        );
      }
      _refreshResumeCount();
    }
    _wasTaggingRunning = progress.isRunning;
  }

  // ------------------------------------------------------------ acciones ---

  Future<void> _handleInstall({bool force = false}) async {
    setState(() => _showLog = true);
    await _service.install(force: force);
  }

  Future<bool> _confirmDialog({required String title, required String content, String confirmLabel = 'Aceptar'}) {
    return showDialog<bool>(
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
              width: 340,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: _kSurfaceColor.withOpacity(0.85),
                border: Border.all(color: Colors.white12, width: 0.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(content,
                      style: const TextStyle(fontSize: 13, color: Colors.white70),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 22),
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
                        style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                        child: Text(confirmLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).then((v) => v ?? false);
  }

  Future<void> _handleUninstall() async {
    final confirm = await _confirmDialog(
      title: '¿Desinstalar WD14 Tagger?',
      content: 'Se eliminará el entorno Python, el modelo descargado y toda la carpeta de instalación. '
          'Tus etiquetas ya guardadas en la bóveda NO se borran.',
      confirmLabel: 'Desinstalar',
    );
    if (!confirm) return;
    setState(() => _showLog = true);
    await _service.uninstall();
    await _refreshResumeCount();
  }

  Future<void> _handleStartServer() async {
    await _service.startServer();
    await _refreshResumeCount();
  }

  Future<void> _handleStopServer() async {
    await _service.stopServer();
  }

  Future<void> _handleStartTagging({required bool resume}) async {
    await _service.startAutoTagging(
      metadataService: widget.metadataService,
      vaultRootPath: widget.vaultRootPath,
      resume: resume,
    );
    await _refreshResumeCount();
  }

  // ----------------------------------------------------------------- UI ---

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16.0),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: 480,
            constraints: const BoxConstraints(maxHeight: 640),
            decoration: BoxDecoration(
              color: _kSurfaceColor.withOpacity(0.92),
              border: Border.all(color: Colors.white12, width: 0.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    child: ValueListenableBuilder<Wd14InstallState>(
                      valueListenable: _service.installState,
                      builder: (context, installState, _) {
                        if (!_service.isSupportedPlatform) {
                          return _buildUnsupportedPlatform();
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildInstallSection(installState),
                            if (installState == Wd14InstallState.installed) ...[
                              const SizedBox(height: 20),
                              const Divider(color: Colors.white12, height: 1),
                              const SizedBox(height: 20),
                              _buildServerSection(),
                            ],
                            ValueListenableBuilder<Wd14ServerState>(
                              valueListenable: _service.serverState,
                              builder: (context, serverState, __) {
                                if (installState != Wd14InstallState.installed ||
                                    serverState != Wd14ServerState.running) {
                                  return const SizedBox.shrink();
                                }
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 20),
                                    const Divider(color: Colors.white12, height: 1),
                                    const SizedBox(height: 20),
                                    _buildTaggingSection(),
                                  ],
                                );
                              },
                            ),
                            if (_logLines.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              _buildLogSection(),
                            ],
                            ValueListenableBuilder<String?>(
                              valueListenable: _service.lastError,
                              builder: (context, error, __) {
                                if (error == null || error.isEmpty) return const SizedBox.shrink();
                                return Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: _buildErrorBanner(error),
                                );
                              },
                            ),
                            ValueListenableBuilder<String?>(
                              valueListenable: _service.lastInfo,
                              builder: (context, info, __) {
                                if (info == null || info.isEmpty) return const SizedBox.shrink();
                                return Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: _buildInfoBanner(info),
                                );
                              },
                            ),
                          ],
                        );
                      },
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

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12, width: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome, color: _kAccent, size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Etiquetado automático WD14',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white54, size: 20),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Cerrar',
          ),
        ],
      ),
    );
  }

  Widget _buildUnsupportedPlatform() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kPanelColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.orangeAccent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _service.lastError.value ?? 'Esta función solo está disponible en Windows.',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoBanner(String info) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kAccent.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kAccent.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: _kAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(info, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String error) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(error, style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------- instalacion ---

  Widget _buildInstallSection(Wd14InstallState state) {
    switch (state) {
      case Wd14InstallState.unknown:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent)),
        );

      case Wd14InstallState.notInstalled:
      case Wd14InstallState.error:
        return _sectionCard(
          icon: Icons.download_rounded,
          iconColor: _kAccent,
          title: 'Servidor no instalado',
          subtitle: 'Se descargará Python, el modelo de IA (~470 MB) y se creará un entorno '
              'aislado en la carpeta de datos de la app. Requiere Python instalado en el sistema.',
          trailing: _PrimaryButton(label: 'Instalar', onPressed: () => _handleInstall()),
        );

      case Wd14InstallState.installing:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionCard(
              icon: Icons.hourglass_top_rounded,
              iconColor: _kAccent,
              title: 'Instalando...',
              customSubtitle: ValueListenableBuilder<String>(
                valueListenable: _service.installStepLabel,
                builder: (context, label, _) => Text(
                  label.isEmpty ? 'Preparando...' : label,
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<double>(
              valueListenable: _service.installProgress,
              builder: (context, progress, _) => ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress > 0 ? progress : null,
                  minHeight: 6,
                  backgroundColor: Colors.white12,
                  color: _kAccent,
                ),
              ),
            ),
          ],
        );

      case Wd14InstallState.installed:
        return ValueListenableBuilder<bool>(
          valueListenable: _service.serverOutdated,
          builder: (context, outdated, _) => _sectionCard(
          icon: outdated ? Icons.system_update_alt : Icons.check_circle_rounded,
          iconColor: outdated ? Colors.orangeAccent : Colors.greenAccent,
          title: outdated ? 'Hay una versión nueva del servidor' : 'Servidor instalado',
          subtitle: outdated
              ? 'Usa menos memoria RAM. Detén el servidor y pulsa Actualizar.'
              : 'Listo para iniciarse.',
          trailing: ValueListenableBuilder<Wd14ServerState>(
            valueListenable: _service.serverState,
            builder: (context, serverState, _) {
              final canModify = serverState == Wd14ServerState.stopped;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: canModify ? () => _handleInstall(force: false) : null,
                    style: TextButton.styleFrom(foregroundColor: _kAccent),
                    child: const Text('Actualizar', style: TextStyle(fontSize: 13)),
                  ),
                  TextButton(
                    onPressed: canModify ? _handleUninstall : null,
                    style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                    child: const Text('Desinstalar', style: TextStyle(fontSize: 13)),
                  ),
                ],
              );
            },
          ),
          ),
        );

      case Wd14InstallState.uninstalling:
        return _sectionCard(
          icon: Icons.delete_outline,
          iconColor: Colors.redAccent,
          title: 'Desinstalando...',
          subtitle: 'Eliminando archivos...',
        );
    }
  }

  // ------------------------------------------------------------- servidor ---

  Widget _buildServerSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ValueListenableBuilder<Wd14ServerState>(
          valueListenable: _service.serverState,
          builder: (context, state, _) {
            final color = _serverStateColor(state);
            final label = _serverStateLabel(state);
            final busy = state == Wd14ServerState.starting || state == Wd14ServerState.stopping;

            return Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 13, color: Colors.white70)),
                ),
                if (busy)
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent),
                  )
                else if (state == Wd14ServerState.running)
                  _SecondaryButton(label: 'Detener servidor', onPressed: _handleStopServer)
                else
                  _PrimaryButton(label: 'Iniciar servidor', onPressed: _handleStartServer),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                'Etiquetar automáticamente al absorber imágenes',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withOpacity(0.85)),
              ),
            ),
            Switch(
              value: _autoTagOnAbsorb,
              activeColor: _kAccent,
              onChanged: (v) {
                setState(() => _autoTagOnAbsorb = v);
                _service.setAutoTagOnAbsorb(v);
              },
            ),
          ],
        ),
        _helpText(
          'Cada imagen que entre a la bóveda (por el Vórtice o arrastrándola) '
          'se etiqueta sola, una tras otra y sin bloquear la app. Si el '
          'servidor está detenido, se inicia solo al llegar la primera imagen '
          '(tarda unos segundos en cargar el modelo). No toca imágenes que ya '
          'tengan etiquetas y los videos se omiten.',
        ),
        ValueListenableBuilder<int>(
          valueListenable: _service.autoQueueLength,
          builder: (context, pending, _) {
            if (pending == 0) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(left: 2, top: 4),
              child: Text('$pending imagen(es) en cola de etiquetado',
                  style: const TextStyle(fontSize: 11, color: _kAccent)),
            );
          },
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => setState(() => _showAdvanced = !_showAdvanced),
          child: Row(
            children: [
              Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more, size: 18, color: Colors.white54),
              const SizedBox(width: 4),
              const Text('Opciones avanzadas', style: TextStyle(fontSize: 12, color: Colors.white54)),
            ],
          ),
        ),
        if (_showAdvanced) _buildAdvancedOptions(),
      ],
    );
  }

  Color _serverStateColor(Wd14ServerState state) {
    switch (state) {
      case Wd14ServerState.running:
        return Colors.greenAccent;
      case Wd14ServerState.starting:
      case Wd14ServerState.stopping:
        return Colors.orangeAccent;
      case Wd14ServerState.error:
        return Colors.redAccent;
      case Wd14ServerState.stopped:
        return Colors.white38;
    }
  }

  String _serverStateLabel(Wd14ServerState state) {
    switch (state) {
      case Wd14ServerState.running:
        return 'En ejecución · puerto ${_service.port}';
      case Wd14ServerState.starting:
        return 'Iniciando...';
      case Wd14ServerState.stopping:
        return 'Deteniendo...';
      case Wd14ServerState.error:
        return 'Error';
      case Wd14ServerState.stopped:
        return 'Detenido';
    }
  }

  Widget _buildAdvancedOptions() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: _kPanelColor, borderRadius: BorderRadius.circular(8)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _thresholdSlider(
              label: 'Umbral general',
              value: _generalThreshold,
              onChanged: (v) {
                setState(() => _generalThreshold = v);
                _service.setThresholds(general: v);
              },
            ),
            _helpText(
              'Confianza mínima para aceptar una etiqueta de contenido general '
              '(pose, ropa, objetos, escenario...). Más alto = menos etiquetas '
              'pero más fiables; más bajo = más etiquetas, con más riesgo de error.',
            ),
            const SizedBox(height: 8),
            _thresholdSlider(
              label: 'Umbral de personajes',
              value: _characterThreshold,
              onChanged: (v) {
                setState(() => _characterThreshold = v);
                _service.setThresholds(character: v);
              },
            ),
            _helpText(
              'Confianza mínima para reconocer a un personaje conocido (de anime, '
              'videojuegos, etc.). Suele ir más alto que el general porque hay '
              'miles de personajes con diseños parecidos entre sí.',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(
                  width: 130,
                  child: Text('Máx. etiquetas', style: TextStyle(fontSize: 12, color: Colors.white70)),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      activeTrackColor: _kAccent,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: _kAccent,
                    ),
                    child: Slider(
                      value: _maxTags.toDouble(),
                      min: 5,
                      max: 60,
                      divisions: 55,
                      onChanged: (v) {
                        final rounded = v.round();
                        setState(() => _maxTags = rounded);
                        _service.setMaxTags(rounded);
                      },
                    ),
                  ),
                ),
                SizedBox(
                  width: 24,
                  child: Text('$_maxTags',
                      style: const TextStyle(fontSize: 11, color: Colors.white54)),
                ),
              ],
            ),
            _helpText(
              'Cuántas etiquetas se guardan como máximo por imagen. Si hay más '
              'candidatas por encima del umbral que este número, se quedan las '
              'de mayor confianza y se descarta el resto.',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Solo imágenes sin etiquetas',
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.7)),
                  ),
                ),
                Switch(
                  value: _onlyUntagged,
                  activeColor: _kAccent,
                  onChanged: (v) {
                    setState(() => _onlyUntagged = v);
                    _service.setOnlyUntagged(v);
                  },
                ),
              ],
            ),
            _helpText(
              'Si está activado, el etiquetado automático se salta las imágenes '
              'que ya tengan alguna etiqueta (puesta a mano o de una pasada '
              'anterior) y solo procesa las que aún no tienen ninguna.',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Traducir etiquetas al español',
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.7)),
                  ),
                ),
                Switch(
                  value: _translateToSpanish,
                  activeColor: _kAccent,
                  onChanged: (v) {
                    setState(() => _translateToSpanish = v);
                    _service.setTranslateToSpanish(v);
                  },
                ),
              ],
            ),
            _helpText(
              'La IA etiqueta en inglés; con esto activado, cada etiqueta se '
              'traduce al guardarla (diccionario propio + reglas gramaticales), '
              'así que la misma etiqueta de origen siempre queda igual en '
              'español. Lo que no reconoce se guarda en inglés. Puedes revisar '
              'y corregir las traducciones en Ajustes › Diccionario de '
              'Traducción. Este ajuste solo afecta a etiquetas nuevas.',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Liberar el modelo de la RAM si no se usa',
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.7)),
                  ),
                ),
                DropdownButton<int>(
                  value: Wd14TaggerService.kIdleUnloadChoices.contains(_idleUnloadMinutes)
                      ? _idleUnloadMinutes
                      : Wd14TaggerService.kDefaultIdleUnloadMinutes,
                  dropdownColor: _kPanelColor,
                  underline: const SizedBox.shrink(),
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                  items: [
                    for (final m in Wd14TaggerService.kIdleUnloadChoices)
                      DropdownMenuItem<int>(
                        value: m,
                        child: Text(m == 0 ? 'Nunca' : 'Tras $m min'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _idleUnloadMinutes = v);
                    _service.setIdleUnloadMinutes(v);
                  },
                ),
              ],
            ),
            _helpText(
              'El modelo de IA ocupa unos 500 MB de RAM mientras está cargado. '
              'Con esto, si pasa el tiempo indicado sin etiquetar nada, se '
              'descarga de la memoria (el servidor sigue encendido con muy poco '
              'consumo) y se vuelve a cargar solo al etiquetar la siguiente '
              'imagen, lo que tarda unos segundos. Elige "Nunca" si prefieres '
              'la máxima velocidad de respuesta.',
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  setState(() {
                    _generalThreshold = Wd14TaggerService.kDefaultGeneralThreshold;
                    _characterThreshold = Wd14TaggerService.kDefaultCharacterThreshold;
                    _maxTags = Wd14TaggerService.kDefaultMaxTags;
                    _onlyUntagged = Wd14TaggerService.kDefaultOnlyUntagged;
                    _translateToSpanish = Wd14TaggerService.kDefaultTranslateToSpanish;
                    _idleUnloadMinutes = Wd14TaggerService.kDefaultIdleUnloadMinutes;
                  });
                  _service.resetAdvancedOptionsToDefaults();
                },
                icon: const Icon(Icons.restart_alt, size: 16, color: Colors.white54),
                label: const Text('Restaurar valores por defecto',
                    style: TextStyle(fontSize: 12, color: Colors.white54)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _helpText(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, top: 2, right: 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 10.5, color: Colors.white.withOpacity(0.38), height: 1.3),
      ),
    );
  }

  Widget _thresholdSlider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTrackColor: _kAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: _kAccent,
            ),
            child: Slider(
              value: value,
              min: 0.05,
              max: 0.95,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(value.toStringAsFixed(2),
              style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ),
      ],
    );
  }

  // -------------------------------------------------------- etiquetado ---

  Widget _buildTaggingSection() {
    return ValueListenableBuilder<Wd14TaggingProgress>(
      valueListenable: _service.taggingProgress,
      builder: (context, progress, _) {
        final running = progress.isRunning;

        if (!running && !_service.isTagging) {
          final hasResume = (_resumeCount ?? 0) > 0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Etiquetado automático',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
              const SizedBox(height: 4),
              Text(
                hasResume
                    ? 'Hay una sesión anterior con ${_resumeCount!} imágenes pendientes.'
                    : 'Recorre la bóveda y etiqueta con IA todas las imágenes'
                        '${_onlyUntagged ? " que aún no tienen etiquetas" : ""}.',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (hasResume) ...[
                    _PrimaryButton(
                      label: 'Reanudar (${_resumeCount!})',
                      onPressed: () => _handleStartTagging(resume: true),
                    ),
                    const SizedBox(width: 10),
                    _SecondaryButton(
                      label: 'Empezar de nuevo',
                      onPressed: () => _handleStartTagging(resume: false),
                    ),
                  ] else if (_checkingResume) ...[
                    const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent),
                    ),
                  ] else ...[
                    _PrimaryButton(
                      label: 'Iniciar etiquetado automático',
                      onPressed: () => _handleStartTagging(resume: false),
                    ),
                  ],
                ],
              ),
            ],
          );
        }

        final currentLabel = progress.currentFile ?? '';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    progress.isScanning ? 'Buscando imágenes en la bóveda...' : 'Etiquetando bóveda...',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                ),
                _SecondaryButton(label: 'Cancelar', onPressed: _service.cancelAutoTagging),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                // Indeterminado mientras se escanea el disco (con bóvedas de
                // miles de imágenes esto puede tardar y aún no hay un total
                // real que mostrar), barra real una vez conocido el total.
                value: progress.isScanning ? null : progress.fraction,
                minHeight: 6,
                backgroundColor: Colors.white12,
                color: _kAccent,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              progress.isScanning
                  ? (progress.total > 0 ? '${progress.total} imágenes encontradas...' : 'Explorando carpetas...')
                  : '${progress.done} / ${progress.total}'
                    '${progress.errors > 0 ? "  ·  ${progress.errors} errores" : ""}',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
            if (!progress.isScanning && currentLabel.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                currentLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ],
          ],
        );
      },
    );
  }

  // --------------------------------------------------------------- log ---

  Widget _buildLogSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _showLog = !_showLog),
          child: Row(
            children: [
              Icon(_showLog ? Icons.expand_less : Icons.expand_more, size: 18, color: Colors.white54),
              const SizedBox(width: 4),
              const Text('Registro', style: TextStyle(fontSize: 12, color: Colors.white54)),
            ],
          ),
        ),
        if (_showLog)
          Container(
            margin: const EdgeInsets.only(top: 6),
            height: 160,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.35),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: ListView.builder(
              controller: _logScrollController,
              itemCount: _logLines.length,
              itemBuilder: (context, index) => Text(
                _logLines[index],
                style: const TextStyle(
                  fontSize: 10.5,
                  color: Colors.white54,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ------------------------------------------------------------ helpers ---

  Widget _sectionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? customSubtitle,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: _kPanelColor, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white)),
                if (customSubtitle != null) ...[
                  const SizedBox(height: 3),
                  customSubtitle,
                ] else if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.white54)),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing,
          ],
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const _PrimaryButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: _kAccent,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const _SecondaryButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white70,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
      ),
      child: Text(label),
    );
  }
}