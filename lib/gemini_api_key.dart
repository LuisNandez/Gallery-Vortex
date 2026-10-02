// gemini_api_key.dart
// Todo lo relacionado con la clave de API de Gemini en un solo lugar:
//  - GeminiApiKeyService: guardar/cargar/borrar, limpiar lo pegado, validar contra Google.
//  - showGeminiApiKeyDialog: asistente paso a paso con enlaces directos.
//  - GeminiKeySettingsTile: fila para la pantalla de Ajustes con estado y acciones.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'ui_utils.dart';

const String kGeminiApiKeyPref = 'gemini_api_key';

// Enlaces oficiales de Google
const String kGeminiKeysUrl = 'https://aistudio.google.com/apikey';
const String kGeminiDocsUrl = 'https://ai.google.dev/gemini-api/docs/api-key';
const String kGeminiLimitsUrl = 'https://ai.google.dev/gemini-api/docs/rate-limits';
const String kGeminiRegionsUrl = 'https://ai.google.dev/gemini-api/docs/available-regions';

const Color _kAccent = Color(0xFF0A84FF);
const Color _kGreen = Color(0xFF30D158);

// ---------------------------------------------------------------------------
// Resultado de una comprobación
// ---------------------------------------------------------------------------
enum GeminiKeyStatus { valid, invalid, region, forbidden, quotaExceeded, network, unknown }

class GeminiKeyCheck {
  final GeminiKeyStatus status;
  final String message;
  const GeminiKeyCheck(this.status, this.message);

  /// La clave sirve (una cuota agotada significa que la clave es válida).
  bool get isUsable =>
      status == GeminiKeyStatus.valid || status == GeminiKeyStatus.quotaExceeded;
}

// ---------------------------------------------------------------------------
// Servicio
// ---------------------------------------------------------------------------
class GeminiApiKeyService {
  GeminiApiKeyService._();

  static Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final k = prefs.getString(kGeminiApiKeyPref)?.trim();
    return (k == null || k.isEmpty) ? null : k;
  }

  static Future<void> save(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kGeminiApiKeyPref, key.trim());
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kGeminiApiKeyPref);
  }

  /// Limpia lo que el usuario pegó: espacios, comillas, saltos de línea y
  /// prefijos como `GEMINI_API_KEY=` o `?key=`.
  static String sanitize(String raw) {
    var s = raw.trim();
    if (s.contains('=')) s = s.substring(s.lastIndexOf('=') + 1);
    return s.replaceAll(RegExp(r'''["'\s]'''), '');
  }

  /// Formato típico de una clave de Gemini (AIza + 35 caracteres).
  static bool looksLikeKey(String s) =>
      RegExp(r'^AIza[0-9A-Za-z_\-]{35}$').hasMatch(s);

  /// Problema que impide siquiera intentar la validación (null = todo bien).
  static String? formatProblem(String key) {
    if (key.isEmpty) return 'Pega tu clave para continuar.';
    if (key.length < 20) {
      return 'La clave parece incompleta. Cópiala entera desde AI Studio.';
    }
    if (!RegExp(r'^[0-9A-Za-z_\-\.]+$').hasMatch(key)) {
      return 'La clave tiene caracteres no válidos. Revisa que copiaste solo la clave.';
    }
    return null;
  }

  /// Aviso suave (no bloquea): la prueba real contra Google decide.
  static String? formatHint(String key) {
    if (key.length >= 20 && !key.startsWith('AIza')) {
      return 'No empieza con "AIza". Puede que no sea una clave de Gemini; la prueba lo confirmará.';
    }
    return null;
  }

  static String mask(String key) {
    if (key.length <= 8) return '••••';
    return '${key.substring(0, 4)}••••••••${key.substring(key.length - 4)}';
  }

  /// Traduce una respuesta de error de la API de Google a algo entendible.
  static GeminiKeyCheck interpretError(int statusCode, String body) {
    String apiMsg = '';
    String reason = '';
    try {
      final data = jsonDecode(body);
      final err = data['error'];
      apiMsg = (err?['message'] ?? '').toString();
      final details = err?['details'];
      if (details is List) {
        for (final d in details) {
          if (d is Map && d['reason'] != null) reason = d['reason'].toString();
        }
      }
    } catch (_) {}
    final lower = apiMsg.toLowerCase();

    if (statusCode == 429) {
      return const GeminiKeyCheck(GeminiKeyStatus.quotaExceeded,
          'Tu clave es válida, pero alcanzaste el límite de uso. Espera un momento e inténtalo de nuevo.');
    }
    if (lower.contains('location is not supported')) {
      return const GeminiKeyCheck(GeminiKeyStatus.region,
          'La API de Gemini no está disponible en tu región. Revisa la lista de países disponibles.');
    }
    if (reason == 'API_KEY_INVALID' ||
        (statusCode == 400 && lower.contains('api key'))) {
      return const GeminiKeyCheck(GeminiKeyStatus.invalid,
          'Google no reconoce esta clave. Cópiala de nuevo completa o crea una nueva en AI Studio.');
    }
    if (statusCode == 403) {
      return GeminiKeyCheck(GeminiKeyStatus.forbidden,
          'Google denegó el acceso. La clave puede estar restringida, revocada o ser de un proyecto sin la API habilitada. ${apiMsg.isNotEmpty ? '($apiMsg)' : ''}'
              .trim());
    }
    return GeminiKeyCheck(GeminiKeyStatus.unknown,
        apiMsg.isNotEmpty ? apiMsg : 'Error $statusCode al contactar con Google.');
  }

  /// Comprueba la clave con una llamada barata (lista de modelos, no gasta cuota
  /// de generación). La clave viaja en la cabecera, no en la URL.
  static Future<GeminiKeyCheck> validate(String key) async {
    try {
      final res = await http.get(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?pageSize=1'),
        headers: {'x-goog-api-key': key},
      ).timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        return const GeminiKeyCheck(GeminiKeyStatus.valid, '¡Clave válida! Gemini respondió correctamente.');
      }
      return interpretError(res.statusCode, utf8.decode(res.bodyBytes));
    } on TimeoutException {
      return const GeminiKeyCheck(GeminiKeyStatus.network,
          'Google tardó demasiado en responder. Revisa tu conexión.');
    } on SocketException {
      return const GeminiKeyCheck(GeminiKeyStatus.network,
          'No hay conexión con Google. Revisa tu internet.');
    } on http.ClientException {
      return const GeminiKeyCheck(GeminiKeyStatus.network,
          'No hay conexión con Google. Revisa tu internet.');
    } catch (e) {
      return GeminiKeyCheck(GeminiKeyStatus.unknown, 'Error inesperado: $e');
    }
  }

  /// Abre un enlace en el navegador del sistema (sin dependencias extra).
  /// Si falla, copia el enlace al portapapeles.
  static Future<void> openUrl(BuildContext context, String url) async {
    try {
      final ProcessResult r;
      if (Platform.isWindows) {
        r = await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
      } else if (Platform.isMacOS) {
        r = await Process.run('open', [url]);
      } else {
        r = await Process.run('xdg-open', [url]);
      }
      if (r.exitCode == 0) return;
    } catch (_) {}
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      showGlassSnackBar(context, 'No pude abrir el navegador. Enlace copiado al portapapeles.',
          icon: Icons.link, iconColor: Colors.amber);
    }
  }
}

// ---------------------------------------------------------------------------
// Asistente paso a paso
// ---------------------------------------------------------------------------

/// Muestra el asistente. Devuelve la clave ya verificada y guardada, o null si
/// el usuario cancela. [notice] muestra un aviso arriba (p. ej. "Google rechazó
/// tu clave anterior").
Future<String?> showGeminiApiKeyDialog(BuildContext context, {String? notice}) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black45,
    barrierDismissible: false,
    builder: (_) => GeminiApiKeyDialog(notice: notice),
  );
}

class GeminiApiKeyDialog extends StatefulWidget {
  final String? notice;
  const GeminiApiKeyDialog({super.key, this.notice});

  @override
  State<GeminiApiKeyDialog> createState() => _GeminiApiKeyDialogState();
}

class _GeminiApiKeyDialogState extends State<GeminiApiKeyDialog> with WidgetsBindingObserver {
  final TextEditingController _ctrl = TextEditingController();
  bool _obscure = true;
  bool _testing = false;
  GeminiKeyCheck? _result;
  String? _clipboardKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkClipboard();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.dispose();
    super.dispose();
  }

  // Al volver del navegador (la ventana recupera el foco) buscamos si el
  // usuario copió una clave, para ofrecerla con un solo clic.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkClipboard();
  }

  Future<void> _checkClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = GeminiApiKeyService.sanitize(data?.text ?? '');
      final found = GeminiApiKeyService.looksLikeKey(text) ? text : null;
      if (mounted && found != _clipboardKey) setState(() => _clipboardKey = found);
    } catch (_) {}
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = GeminiApiKeyService.sanitize(data?.text ?? '');
    if (text.isEmpty) return;
    setState(() {
      _ctrl.text = text;
      _result = null;
    });
  }

  Future<void> _submit() async {
    if (_testing) return;
    final key = GeminiApiKeyService.sanitize(_ctrl.text);
    final problem = GeminiApiKeyService.formatProblem(key);
    if (problem != null) {
      setState(() => _result = GeminiKeyCheck(GeminiKeyStatus.invalid, problem));
      return;
    }
    setState(() {
      _ctrl.text = key;
      _testing = true;
      _result = null;
    });
    final check = await GeminiApiKeyService.validate(key);
    if (!mounted) return;
    if (check.isUsable) {
      await GeminiApiKeyService.save(key);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _result = check;
      });
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) Navigator.pop(context, key);
      return;
    }
    setState(() {
      _testing = false;
      _result = check;
    });
  }

  Future<void> _saveWithoutChecking() async {
    final key = GeminiApiKeyService.sanitize(_ctrl.text);
    if (GeminiApiKeyService.formatProblem(key) != null) return;
    await GeminiApiKeyService.save(key);
    if (mounted) Navigator.pop(context, key);
  }

  // ---------- Widgets auxiliares ----------
  Widget _step(int n, String title, String body, {List<Widget> actions = const []}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: _kAccent, shape: BoxShape.circle),
            child: Text('$n',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body, style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.35)),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkChip(String label, String url, {IconData icon = Icons.open_in_new}) {
    return TextButton.icon(
      onPressed: () => GeminiApiKeyService.openUrl(context, url),
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 11)),
      style: TextButton.styleFrom(
        foregroundColor: _kAccent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _banner(String text, Color color, IconData icon) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.35))),
        ],
      ),
    );
  }

  Widget _troubleItem(String problem, String fix) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(problem, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(fix, style: const TextStyle(color: Colors.white60, fontSize: 11.5, height: 1.35)),
        ],
      ),
    );
  }

  Widget _resultBanner() {
    final r = _result;
    if (r == null) return const SizedBox.shrink();
    Color color;
    IconData icon;
    switch (r.status) {
      case GeminiKeyStatus.valid:
        color = _kGreen;
        icon = Icons.check_circle_outline;
        break;
      case GeminiKeyStatus.quotaExceeded:
        color = Colors.amber;
        icon = Icons.hourglass_bottom;
        break;
      case GeminiKeyStatus.network:
        color = Colors.amber;
        icon = Icons.wifi_off;
        break;
      default:
        color = Colors.redAccent;
        icon = Icons.error_outline;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _banner(r.message, color, icon),
        if (r.status == GeminiKeyStatus.region)
          Align(alignment: Alignment.centerLeft, child: _linkChip('Ver países disponibles', kGeminiRegionsUrl)),
        if (r.status == GeminiKeyStatus.invalid || r.status == GeminiKeyStatus.forbidden)
          Align(alignment: Alignment.centerLeft, child: _linkChip('Crear una clave nueva', kGeminiKeysUrl)),
        if (r.status == GeminiKeyStatus.network)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _saveWithoutChecking,
              style: TextButton.styleFrom(foregroundColor: Colors.amber, padding: const EdgeInsets.symmetric(horizontal: 8)),
              child: const Text('Guardar sin verificar', style: TextStyle(fontSize: 11)),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentKey = GeminiApiKeyService.sanitize(_ctrl.text);
    final hint = GeminiApiKeyService.formatHint(currentKey);
    final showClipboardChip = _clipboardKey != null && _clipboardKey != currentKey;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: 470,
            constraints: const BoxConstraints(maxHeight: 700),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2E).withOpacity(0.92),
              border: Border.all(color: Colors.white12, width: 0.5),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // --- Encabezado ---
                  const Center(child: Icon(Icons.auto_awesome, color: _kAccent, size: 36)),
                  const SizedBox(height: 12),
                  const Center(
                    child: Text('Conectar Gemini (IA)',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                  const SizedBox(height: 6),
                  const Center(
                    child: Text(
                      'La IA rellena los datos y la biografía de tus personajes. Necesitas una clave gratuita de Google; te toma menos de un minuto.',
                      style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.35),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (widget.notice != null) _banner(widget.notice!, Colors.amber, Icons.info_outline),
                  const SizedBox(height: 18),

                  // --- Pasos ---
                  _step(
                    1,
                    'Abre Google AI Studio',
                    'Inicia sesión con tu cuenta de Google.',
                    actions: [
                      ElevatedButton.icon(
                        onPressed: () => GeminiApiKeyService.openUrl(context, kGeminiKeysUrl),
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: const Text('Abrir AI Studio', style: TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          minimumSize: const Size(0, 30),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copiar enlace',
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        color: Colors.white54,
                        icon: const Icon(Icons.copy),
                        onPressed: () async {
                          await Clipboard.setData(const ClipboardData(text: kGeminiKeysUrl));
                          if (context.mounted) {
                            showGlassSnackBar(context, 'Enlace copiado.', icon: Icons.link);
                          }
                        },
                      ),
                    ],
                  ),
                  _step(
                    2,
                    'Acepta los términos (solo la primera vez)',
                    'Google puede pedirte aceptar las condiciones y confirmar tu país. La API de Gemini no está disponible en todas las regiones.',
                    actions: [_linkChip('Países disponibles', kGeminiRegionsUrl)],
                  ),
                  _step(
                    3,
                    'Crea la clave',
                    'Pulsa "Create API key" (Crear clave de API). Elige "proyecto nuevo" si no sabes cuál usar; es lo más sencillo.',
                  ),
                  _step(
                    4,
                    'Copia y pega aquí',
                    'La clave empieza con "AIza…". Cópiala y vuelve a esta ventana: la detectaremos sola.',
                  ),

                  // --- Campo de la clave ---
                  if (showClipboardChip)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ActionChip(
                        avatar: const Icon(Icons.content_paste_go, size: 16, color: _kGreen),
                        label: Text('Usar clave del portapapeles (${GeminiApiKeyService.mask(_clipboardKey!)})',
                            style: const TextStyle(fontSize: 11, color: Colors.white)),
                        backgroundColor: _kGreen.withOpacity(0.15),
                        side: BorderSide(color: _kGreen.withOpacity(0.5), width: 0.5),
                        onPressed: () => setState(() {
                          _ctrl.text = _clipboardKey!;
                          _result = null;
                        }),
                      ),
                    ),
                  TextField(
                    controller: _ctrl,
                    obscureText: _obscure,
                    enabled: !_testing,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    onChanged: (_) => setState(() => _result = null),
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.black26,
                      hintText: 'Pega tu clave (AIza...) aquí',
                      hintStyle: const TextStyle(color: Colors.white24),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: _obscure ? 'Mostrar clave' : 'Ocultar clave',
                            iconSize: 18,
                            color: Colors.white54,
                            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                          IconButton(
                            tooltip: 'Pegar',
                            iconSize: 18,
                            color: Colors.white54,
                            icon: const Icon(Icons.content_paste),
                            onPressed: _testing ? null : _paste,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (hint != null && _result == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 4),
                      child: Text(hint, style: const TextStyle(color: Colors.amber, fontSize: 11)),
                    ),
                  _resultBanner(),
                  const SizedBox(height: 16),

                  // --- Botones ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _testing ? null : () => Navigator.pop(context, null),
                        child: const Text('Cancelar', style: TextStyle(color: Colors.white70)),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _testing ? null : _submit,
                        icon: _testing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.verified_outlined, size: 16),
                        label: Text(_testing ? 'Probando...' : 'Probar y guardar'),
                        style: ElevatedButton.styleFrom(backgroundColor: _kAccent, foregroundColor: Colors.white),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Divider(color: Colors.white10),

                  // --- Ayuda ---
                  Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      iconColor: Colors.white54,
                      collapsedIconColor: Colors.white54,
                      title: const Text('¿Algo salió mal?',
                          style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _troubleItem('"Clave no válida"',
                            'Cópiala de nuevo completa, sin espacios ni comillas, o crea una nueva en AI Studio.'),
                        _troubleItem('"Ubicación no compatible"',
                            'La API de Gemini no está disponible en tu país o región.'),
                        _troubleItem('"Límite alcanzado" (429)',
                            'La clave funciona, pero el nivel gratuito tiene límites por minuto y por día. Espera un poco.'),
                        _troubleItem('"Acceso denegado" (403)',
                            'La clave puede tener restricciones o haber sido revocada. Crea una nueva.'),
                        _troubleItem('No se abre el navegador',
                            'Usa el botón de copiar enlace y pégalo en tu navegador.'),
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    children: [
                      _linkChip('Guía oficial', kGeminiDocsUrl, icon: Icons.menu_book_outlined),
                      _linkChip('Mis claves', kGeminiKeysUrl, icon: Icons.vpn_key_outlined),
                      _linkChip('Límites y cuotas', kGeminiLimitsUrl, icon: Icons.speed),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lock_outline, size: 13, color: Colors.white38),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'La clave se guarda solo en este equipo y únicamente se envía a Google. No la compartas: quien la tenga puede usar tu cuota.',
                          style: TextStyle(color: Colors.white38, fontSize: 10.5, height: 1.35),
                        ),
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
}

// ---------------------------------------------------------------------------
// Fila para la pantalla de Ajustes
// ---------------------------------------------------------------------------
class GeminiKeySettingsTile extends StatefulWidget {
  const GeminiKeySettingsTile({super.key});

  @override
  State<GeminiKeySettingsTile> createState() => _GeminiKeySettingsTileState();
}

class _GeminiKeySettingsTileState extends State<GeminiKeySettingsTile> {
  String? _key;
  bool _loading = true;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final k = await GeminiApiKeyService.load();
    if (mounted) {
      setState(() {
        _key = k;
        _loading = false;
      });
    }
  }

  Future<void> _configure() async {
    await showGeminiApiKeyDialog(context);
    await _reload();
  }

  Future<void> _test() async {
    final k = _key;
    if (k == null || _testing) return;
    setState(() => _testing = true);
    final r = await GeminiApiKeyService.validate(k);
    if (!mounted) return;
    setState(() => _testing = false);
    showGlassSnackBar(
      context,
      r.message,
      icon: r.isUsable ? Icons.check_circle_outline : Icons.error_outline,
      iconColor: r.isUsable ? _kGreen : Colors.redAccent,
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2E),
        title: const Text('¿Borrar la clave?', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text('Tendrás que volver a ingresarla para usar la IA.',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await GeminiApiKeyService.clear();
    await _reload();
    if (mounted) showGlassSnackBar(context, 'Clave eliminada del sistema.', icon: Icons.delete_outline);
  }

  Widget _btn(String label, VoidCallback? onPressed, {bool destructive = false}) {
    final color = destructive ? Colors.redAccent : _kAccent;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withOpacity(0.4), width: 1),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        minimumSize: const Size(90, 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = _key != null;
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: _loading
            ? const SizedBox(height: 32)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(hasKey ? Icons.check_circle : Icons.vpn_key_outlined,
                          color: hasKey ? _kGreen : _kAccent, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Clave API de Gemini',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white)),
                            const SizedBox(height: 2),
                            Text(
                              hasKey
                                  ? 'Configurada · ${GeminiApiKeyService.mask(_key!)}'
                                  : 'No configurada · necesaria para autocompletar biografías con IA',
                              style: TextStyle(fontSize: 11, color: hasKey ? _kGreen : Colors.white54),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _btn(hasKey ? 'Cambiar' : 'Configurar', _configure),
                      if (hasKey) _btn(_testing ? 'Probando...' : 'Probar', _testing ? null : _test),
                      if (!hasKey) _btn('Obtener clave', () => GeminiApiKeyService.openUrl(context, kGeminiKeysUrl)),
                      if (hasKey) _btn('Borrar', _delete, destructive: true),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}