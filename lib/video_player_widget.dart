import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

class VideoViewerWidget extends StatefulWidget {
  final File videoFile;
  const VideoViewerWidget({super.key, required this.videoFile});

  @override
  State<VideoViewerWidget> createState() => _VideoViewerWidgetState();
}

class _VideoViewerWidgetState extends State<VideoViewerWidget> with WindowListener {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  
  bool _isFullScreenOrMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initWindowState();
    
    _player.open(Media(widget.videoFile.path));
    _player.setPlaylistMode(PlaylistMode.single);
  }

  Future<void> _initWindowState() async {
    final isFull = await windowManager.isFullScreen();
    final isMax = await windowManager.isMaximized();
    if (mounted) {
      setState(() {
        _isFullScreenOrMaximized = isFull || isMax;
      });
    }
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
    if (mounted) {
      setState(() => _isFullScreenOrMaximized = isMaximized);
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggleFullScreen() async {
    final isFull = await windowManager.isFullScreen();
    
    if (isFull) {
      await windowManager.setFullScreen(false);
      // SOLUCIÓN PARPADEO: Eliminamos el 'await windowManager.restore()' 
      // porque causaba un conflicto de redibujado en Windows.
    } else {
      await windowManager.setFullScreen(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktopTheme = MaterialDesktopVideoControlsThemeData(
      // SOLUCIÓN DOBLE CLIC 1: Apagamos el comportamiento nativo roto
      toggleFullscreenOnDoublePress: false, 
      bottomButtonBar: [
        const MaterialDesktopPlayOrPauseButton(),
        const MaterialDesktopVolumeButton(),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        IconButton(
          icon: Icon(
            _isFullScreenOrMaximized ? Icons.fullscreen_exit : Icons.fullscreen,
            color: Colors.white,
          ),
          iconSize: 28,
          tooltip: _isFullScreenOrMaximized ? 'Restaurar' : 'Pantalla Completa',
          onPressed: _toggleFullScreen,
        ),
      ],
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: MaterialDesktopVideoControlsTheme(
          normal: desktopTheme,
          fullscreen: desktopTheme,
          // SOLUCIÓN DOBLE CLIC 2: Inyectamos nuestro propio detector de toques
          child: GestureDetector(
            onDoubleTap: _toggleFullScreen,
            child: Video(
              controller: _controller,
              controls: AdaptiveVideoControls, 
            ),
          ),
        ),
      ),
    );
  }
}