// search_suggestions_panel.dart
//
// Panel discreto de sugerencias que aparece debajo de la barra de búsqueda
// principal: perfiles (con su foto) primero, luego etiquetas y, con la barra
// vacía, las búsquedas recientes.

import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';

import 'metadata_service.dart';
import 'ui_utils.dart';

enum SuggestionKind { profile, tag, recent }

class SearchSuggestion {
  final SuggestionKind kind;

  /// Texto que se escribe en la barra al elegir la sugerencia.
  final String label;
  final String? subtitle;
  final LocalCharacter? character;
  final int count;

  const SearchSuggestion._({
    required this.kind,
    required this.label,
    this.subtitle,
    this.character,
    this.count = 0,
  });

  factory SearchSuggestion.profile(LocalCharacter c) => SearchSuggestion._(
        kind: SuggestionKind.profile,
        label: c.name,
        subtitle: c.franchise,
        character: c,
      );

  factory SearchSuggestion.tag(String tag, int count) => SearchSuggestion._(
        kind: SuggestionKind.tag,
        label: tag,
        count: count,
      );

  factory SearchSuggestion.recent(String text) => SearchSuggestion._(
        kind: SuggestionKind.recent,
        label: text,
      );
}

class SearchSuggestionsPanel extends StatelessWidget {
  final List<SearchSuggestion> items;
  final int highlightedIndex;

  /// Texto buscado, ya normalizado (para resaltar la parte que coincide).
  final String query;
  final ValueChanged<SearchSuggestion> onPick;
  final ValueChanged<SearchSuggestion> onRemoveRecent;
  final VoidCallback onClearRecents;

  const SearchSuggestionsPanel({
    super.key,
    required this.items,
    required this.highlightedIndex,
    required this.query,
    required this.onPick,
    required this.onRemoveRecent,
    required this.onClearRecents,
  });

  static String _sectionTitle(SuggestionKind kind) {
    switch (kind) {
      case SuggestionKind.profile:
        return 'PERFILES';
      case SuggestionKind.tag:
        return 'ETIQUETAS';
      case SuggestionKind.recent:
        return 'RECIENTES';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    SuggestionKind? last;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.kind != last) {
        last = item.kind;
        children.add(_SectionHeader(
          title: _sectionTitle(item.kind),
          onClear: item.kind == SuggestionKind.recent ? onClearRecents : null,
        ));
      }
      children.add(_SuggestionRow(
        item: item,
        query: query,
        highlighted: i == highlightedIndex,
        onTap: () => onPick(item),
        onRemove: item.kind == SuggestionKind.recent
            ? () => onRemoveRecent(item)
            : null,
      ));
    }

    // TextFieldTapRegion: hacer clic aquí NO cuenta como "clic fuera" del
    // campo de texto, así el buscador conserva el foco.
    return TextFieldTapRegion(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, (1 - t) * -4), child: child),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(
              width: 350,
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF252525).withOpacity(0.9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12, width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Column(mainAxisSize: MainAxisSize.min, children: children),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onClear;
  const _SectionHeader({required this.title, this.onClear});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 10, 2),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const Spacer(),
          if (onClear != null)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onClear,
                child: const Text('Borrar',
                    style: TextStyle(color: Colors.white38, fontSize: 10.5)),
              ),
            ),
        ],
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  final SearchSuggestion item;
  final String query;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _SuggestionRow({
    required this.item,
    required this.query,
    required this.highlighted,
    required this.onTap,
    this.onRemove,
  });

  Widget _leading() {
    switch (item.kind) {
      case SuggestionKind.profile:
        return _ProfileAvatar(path: item.character?.avatarPath);
      case SuggestionKind.tag:
        return const SizedBox(
          width: 28,
          child: Icon(Icons.tag, size: 15, color: Colors.white38),
        );
      case SuggestionKind.recent:
        break;
    }
    return const SizedBox(
      width: 28,
      child: Icon(Icons.history, size: 15, color: Colors.white38),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isProfile = item.kind == SuggestionKind.profile;
    final String? subtitle = item.subtitle;

    return InkWell(
      canRequestFocus: false,
      onTap: onTap,
      hoverColor: Colors.white.withOpacity(0.06),
      child: Container(
        height: isProfile ? 42 : 32,
        color: highlighted ? Colors.white.withOpacity(0.10) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            _leading(),
            const SizedBox(width: 8),
            Expanded(
              child: isProfile
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Highlighted(
                          text: item.label,
                          query: query,
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        if (subtitle != null && subtitle.trim().isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white38, fontSize: 10.5),
                          ),
                      ],
                    )
                  : _Highlighted(
                      text: item.label,
                      query: query,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
            ),
            if (item.kind == SuggestionKind.tag && item.count > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text('${item.count}',
                    style: const TextStyle(color: Colors.white30, fontSize: 11)),
              ),
            if (onRemove != null)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onRemove,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.close, size: 14, color: Colors.white30),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  final String? path;
  const _ProfileAvatar({this.path});

  @override
  Widget build(BuildContext context) {
    const double size = 28;
    const fallback = Icon(Icons.person, size: 16, color: Colors.white38);
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF3A3A3C),
      ),
      child: ClipOval(
        child: (path == null || path!.isEmpty)
            ? fallback
            : Image.file(
                File(path!),
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: 64, // miniatura: no decodifica la foto completa
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}

/// Texto de una sola línea con la parte buscada resaltada.
class _Highlighted extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle style;
  const _Highlighted({required this.text, required this.query, required this.style});

  @override
  Widget build(BuildContext context) {
    int idx = -1;
    if (query.isNotEmpty) {
      final norm = normalizeForSearch(text);
      // Solo se resalta si la normalización no cambió la longitud del texto.
      if (norm.length == text.length) idx = norm.indexOf(query);
    }
    if (idx < 0) {
      return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: text.substring(0, idx)),
          TextSpan(
            text: text.substring(idx, idx + query.length),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          TextSpan(text: text.substring(idx + query.length)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}