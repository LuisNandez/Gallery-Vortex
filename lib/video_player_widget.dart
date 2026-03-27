import 'dart:io';
import 'dart:ui';
import 'dart:async';
import 'package:flutter/material.dart';
// Volvemos a tu librería de alto rendimiento
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

class CustomVideoPlayer extends StatefulWidget {
  final File videoFile;

  const CustomVideoPlayer({super.key, required this.videoFile});

  @override
  State<CustomVideoPlayer> createState() => _CustomVideoPlayerState();
}

class _CustomVideoPlayerState extends State<CustomVideoPlayer> with WindowListener {
  // Motores de media_kit restaurados
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  bool _isFullScreenOrMaximized = false;
  bool _controlsVisible = true;
  bool _isPlaying = true;
  double _volume = 100.0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Timer? _hideTimer;
  bool _isHoveringControls = false;

  String _getCleanName(String path) {
    String filename = path.split(Platform.pathSeparator).last;
    if (filename.toLowerCase().endsWith('.vtx')) {
      String base = filename.substring(0, filename.length - 4); // Quita .vtx
      int lastZero = base.lastIndexOf('0');
      if (lastZero != -1) {
        return base.substring(0, lastZero); 
      }
      return base;
    }
    return filename;
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initWindowState();

    // 1. Inicializamos con reproducción automática
    _player.open(Media(widget.videoFile.path), play: true);
    
    // 2. SOLUCIÓN LOOP: Configuramos el modo de reproducción en bucle
    _player.setPlaylistMode(PlaylistMode.loop); 

    // Escuchadores para actualizar la barra de progreso e iconos
    _player.stream.playing.listen((playing) {
      if (mounted) setState(() => _isPlaying = playing);
    });
    _player.stream.position.listen((position) {
      if (mounted) setState(() => _position = position);
    });
    _player.stream.duration.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });
    _player.stream.volume.listen((volume) {
      if (mounted) setState(() => _volume = volume);
    });

    _startHideTimer();
  }

  Future<void> _initWindowState() async {
    final isFull = await windowManager.isFullScreen();
    final isMax = await windowManager.isMaximized();
    if (mounted) setState(() => _isFullScreenOrMaximized = isFull || isMax);
  }

  @override
  void onWindowEnterFullScreen() => _updateIconState(true);
  @override
  void onWindowLeaveFullScreen() => _updateIconState(false);
  @override
  void onWindowMaximize() => _updateIconState(true);
  @override
  void onWindowRestore() => _updateIconState(false);

  void _updateIconState(bool isMaximized) {
    if (mounted) setState(() => _isFullScreenOrMaximized = isMaximized);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _hideTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (_isPlaying) {
      _player.pause();
      _controlsVisible = true;
      _hideTimer?.cancel();
    } else {
      _player.play();
      _startHideTimer();
    }
  }

  void _toggleMute() {
    if (_volume == 0.0) {
      _player.setVolume(100.0);
    } else {
      _player.setVolume(0.0);
    }
  }

  Future<void> _toggleFullscreen() async {
    final isFull = await windowManager.isFullScreen();
    if (isFull) {
      await windowManager.setFullScreen(false);
    } else {
      await windowManager.setFullScreen(true);
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isPlaying && !_isHoveringControls) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _onPointerHover() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _startHideTimer();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return "${duration.inHours}:$twoDigitMinutes:$twoDigitSeconds";
    }
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // Usamos MouseRegion para que los controles despierten al mover el mouse
      body: MouseRegion(
        onHover: (_) => _onPointerHover(),
        child: Stack(
          children: [
            // REPRODUCTOR MEDIA_KIT (Alto rendimiento devuelto)
            Center(
              child: GestureDetector(
                onDoubleTap: _toggleFullscreen,
                onTap: () {
                  setState(() => _controlsVisible = !_controlsVisible);
                  if (_controlsVisible) _startHideTimer();
                },
                child: Video(
                  controller: _controller,
                  controls: NoVideoControls, // Apagamos los controles base para usar los nuestros
                ),
              ),
            ),

            // CONTROLES MAC OS
            AnimatedOpacity(
              opacity: _controlsVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: Stack(
                children: [
                  Positioned(
                    top: 20,
                    left: 20,
                    right: 20,
                    child: MouseRegion(
                      onEnter: (_) => _isHoveringControls = true,
                      onExit: (_) {
                        _isHoveringControls = false;
                        _startHideTimer();
                      },
                      child: _buildTopBar(),
                    ),
                  ),
                  Positioned(
                    bottom: 30,
                    left: 30,
                    right: 30,
                    child: MouseRegion(
                      onEnter: (_) => _isHoveringControls = true,
                      onExit: (_) {
                        _isHoveringControls = false;
                        _startHideTimer();
                      },
                      child: _buildBottomFloatingPanel(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Align(
      alignment: Alignment.centerLeft,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4),
              border: Border.all(color: Colors.white12, width: 0.5),
            ),
            child: Text(
              _getCleanName(widget.videoFile.path),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomFloatingPanel() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800), // Evita que se estire demasiado en FullScreen
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                border: Border.all(color: Colors.white12, width: 0.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 3. SOLUCIÓN BARRA INTERACTIVA
                  Row(
                    children: [
                      Text(
                        _formatDuration(_position),
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SizedBox(
                          height: 20,
                          child: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 4.0,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
                              activeTrackColor: const Color(0xFF0A84FF),
                              inactiveTrackColor: Colors.white24,
                              thumbColor: Colors.white,
                              trackShape: const RoundedRectSliderTrackShape(),
                            ),
                            child: Slider(
                              // Evitamos errores matemáticos si el video aún no carga su duración
                              value: _position.inMilliseconds.toDouble().clamp(0.0, _duration.inMilliseconds.toDouble() > 0 ? _duration.inMilliseconds.toDouble() : 0.0),
                              min: 0.0,
                              max: _duration.inMilliseconds.toDouble() > 0 ? _duration.inMilliseconds.toDouble() : 1.0,
                              onChanged: (value) {
                                // Buscamos en el video la posición seleccionada
                                _player.seek(Duration(milliseconds: value.toInt()));
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatDuration(_duration),
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  
                  // BOTONES
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(
                          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          size: 28,
                        ),
                        color: const Color(0xFF0A84FF),
                        onPressed: _togglePlay,
                      ),
                      const Spacer(),
                      IconButton(
                        icon: Icon(
                          _volume == 0.0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                          size: 22,
                        ),
                        color: Colors.white70,
                        onPressed: _toggleMute,
                      ),
                      IconButton(
                        icon: Icon(
                          _isFullScreenOrMaximized ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                          size: 22,
                        ),
                        color: Colors.white70,
                        onPressed: _toggleFullscreen,
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