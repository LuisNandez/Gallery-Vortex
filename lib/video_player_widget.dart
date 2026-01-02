import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class VideoViewerWidget extends StatefulWidget {
  final File videoFile;
  const VideoViewerWidget({super.key, required this.videoFile});

  @override
  State<VideoViewerWidget> createState() => _VideoViewerWidgetState();
}

class _VideoViewerWidgetState extends State<VideoViewerWidget> {
  // 1. Instanciamos el Reproductor
  late final Player _player = Player();
  // 2. Instanciamos el Controlador de Video
  late final VideoController _controller = VideoController(_player);

  @override
  void initState() {
    super.initState();
    // 3. Abrimos el archivo inmediatamente
    _player.open(Media(widget.videoFile.path));
    _player.setPlaylistMode(PlaylistMode.single);
  }

  @override
  void dispose() {
    // 4. Liberamos recursos
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Video(
          controller: _controller,
          // Puedes personalizar los controles si lo deseas
          controls: AdaptiveVideoControls, 
        ),
      ),
    );
  }
}