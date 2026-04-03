import 'dart:io';
import 'dart:ui';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class CustomVideoPlayer extends StatefulWidget {
  final File videoFile;
  final bool isFullScreen; // Recibe el estado del padre
  final VoidCallback? onToggleFullscreen; // Recibe la función del padre
  final ValueChanged<bool>? onControlsVisibilityChanged;

  const CustomVideoPlayer({
    super.key, 
    required this.videoFile,
    this.isFullScreen = false,
    this.onToggleFullscreen,
    this.onControlsVisibilityChanged,
  });

  @override
  State<CustomVideoPlayer> createState() => _CustomVideoPlayerState();
}

// ¡ELIMINAMOS el 'with WindowListener'!
class _CustomVideoPlayerState extends State<CustomVideoPlayer> { 
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

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
      String base = filename.substring(0, filename.length - 4); 
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
    _player.open(Media(widget.videoFile.path), play: true);
    _player.setPlaylistMode(PlaylistMode.loop); 

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onControlsVisibilityChanged?.call(true);
    });

    _startHideTimer();
  }

  @override
  void dispose() {
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

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isPlaying && !_isHoveringControls) {
        setState(() => _controlsVisible = false);
        widget.onControlsVisibilityChanged?.call(false); 
      }
    });
  }

  void _onPointerHover() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
      widget.onControlsVisibilityChanged?.call(true);
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
      body: MouseRegion(
        cursor: _controlsVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
        onHover: (_) => _onPointerHover(),
        child: Stack(
          children: [
            Center(
              child: GestureDetector(
                onDoubleTap: widget.onToggleFullscreen, // Llama al padre
                onTap: () {
                  final newVisible = !_controlsVisible;
                  setState(() => _controlsVisible = newVisible);
                  // NOTIFICAR AL PADRE
                  widget.onControlsVisibilityChanged?.call(newVisible);
                  if (newVisible) _startHideTimer();
                },
                child: Video(
                  controller: _controller,
                  controls: NoVideoControls, 
                ),
              ),
            ),
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
        constraints: const BoxConstraints(maxWidth: 800), 
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
                              value: _position.inMilliseconds.toDouble().clamp(0.0, _duration.inMilliseconds.toDouble() > 0 ? _duration.inMilliseconds.toDouble() : 0.0),
                              min: 0.0,
                              max: _duration.inMilliseconds.toDouble() > 0 ? _duration.inMilliseconds.toDouble() : 1.0,
                              onChanged: (value) {
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
                          widget.isFullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                          size: 22,
                        ),
                        color: Colors.white70,
                        onPressed: widget.onToggleFullscreen, // Delega la acción
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