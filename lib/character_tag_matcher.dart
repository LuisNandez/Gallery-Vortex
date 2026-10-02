// character_tag_matcher.dart
//
// Coincidencia flexible entre un perfil (LocalCharacter) y las etiquetas
// automáticas de personaje que genera WD14, para la sección "Sugerencias"
// de Administración de Perfiles.
//
// El etiquetador guarda los personajes como "nombre (franquicia)" en
// minúsculas y con espacios en vez de guiones bajos, pero el texto exacto
// varía: "laplace gray (franquicia)", "laplace_gray (franquicia)",
// "laplace (franquicia)", "gray laplace (franquicia)"... Por eso NO se
// compara el texto completo: se separa el nombre de la franquicia (lo que
// va entre paréntesis), se parte cada uno en palabras y se comparan las
// palabras sin importar el orden, los acentos, mayúsculas, guiones bajos ni
// pequeños errores de tecleo.

import 'metadata_service.dart';
import 'ui_utils.dart';

/// Resultado de comparar UNA etiqueta contra el perfil.
class CharacterTagMatch {
  /// 0.6 – 1.3 aprox. Más alto = mejor coincidencia (nombre + bonus de franquicia).
  final double score;

  /// true si la franquicia de la etiqueta también coincide con la del perfil.
  final bool franchiseMatch;

  const CharacterTagMatch(this.score, this.franchiseMatch);
}

/// Una imagen sugerida para un perfil, con la etiqueta que la hizo coincidir.
class CharacterSuggestion {
  final String imageId;
  final String tag;
  final double score;
  final bool franchiseMatch;

  const CharacterSuggestion({
    required this.imageId,
    required this.tag,
    required this.score,
    required this.franchiseMatch,
  });
}

class _ParsedTag {
  final List<String> nameTokens;
  final List<String> franchiseTokens;
  const _ParsedTag(this.nameTokens, this.franchiseTokens);
}

class CharacterTagMatcher {
  /// Mínimo de parecido del nombre para aceptar una etiqueta con franquicia
  /// entre paréntesis (0 = nada en común, 1 = mismas palabras).
  static const double _nameThreshold = 0.6;

  /// Bonus de puntuación cuando la franquicia también coincide.
  static const double _franchiseBonus = 0.3;

  /// Pequeña penalización (solo para ordenar) cuando ambos tienen franquicia
  /// pero no se parecen en nada: puede ser otro personaje con el mismo nombre.
  static const double _franchisePenalty = 0.1;

  static final RegExp _parenGroup = RegExp(r'\(([^()]*)\)');
  static final RegExp _separators = RegExp(r'[^a-z0-9\u0080-\uFFFF]+');

  // Analizar una etiqueta es una función pura, así que se cachea: las
  // bóvedas grandes tienen miles de etiquetas distintas y se re-evalúan
  // cada vez que se selecciona un perfil.
  static final Map<String, _ParsedTag> _parseCache = {};

  static const Set<String> _emptyFranchiseValues = {
    'desconocido',
    'desconocida',
    'sin franquicia',
    'unknown',
    'n/a',
  };

  final List<String> _nameTokens;
  final List<String> _franchiseTokens;

  CharacterTagMatcher({required String name, required String franchise})
      : _nameTokens = _parse(name).nameTokens,
        _franchiseTokens = _emptyFranchiseValues
                .contains(normalizeForSearch(franchise.trim()))
            ? const []
            : _tokenize(franchise);

  bool get isUsable => _nameTokens.isNotEmpty;

  // ---------------------------------------------------------------------
  // API pública
  // ---------------------------------------------------------------------

  /// Busca en toda la bóveda imágenes con una etiqueta parecida al perfil.
  /// Excluye las imágenes que ya están vinculadas a [character].
  /// Resultado ordenado de mejor a peor coincidencia.
  static List<CharacterSuggestion> suggest(
      MetadataService service, LocalCharacter character) {
    final matcher = CharacterTagMatcher(
        name: character.name, franchise: character.franchise);
    if (!matcher.isUsable) return [];

    // 1) Se evalúan las etiquetas ÚNICAS (no cada imagen por separado).
    final matchedTags = <String, CharacterTagMatch>{};
    for (final tag in service.getAllTags()) {
      final match = matcher.matchTag(tag);
      if (match != null) matchedTags[tag] = match;
    }
    if (matchedTags.isEmpty) return [];

    // 2) Se buscan las imágenes que tienen alguna de esas etiquetas.
    final hits = service.getImageTagHits(matchedTags.keys.toSet(),
        excludeCharacterId: character.id);

    final result = <CharacterSuggestion>[];
    hits.forEach((imageId, tags) {
      String? bestTag;
      CharacterTagMatch? best;
      for (final tag in tags) {
        final m = matchedTags[tag]!;
        if (best == null || m.score > best.score) {
          best = m;
          bestTag = tag;
        }
      }
      result.add(CharacterSuggestion(
        imageId: imageId,
        tag: bestTag!,
        score: best!.score,
        franchiseMatch: best.franchiseMatch,
      ));
    });

    result.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.imageId.compareTo(b.imageId);
    });
    return result;
  }

  /// Compara una etiqueta con el perfil. Devuelve null si no se parece.
  CharacterTagMatch? matchTag(String rawTag) {
    if (_nameTokens.isEmpty) return null;

    final parsed = _parse(rawTag);
    if (parsed.nameTokens.isEmpty) return null;

    final nameScore = _nameSimilarity(_nameTokens, parsed.nameTokens);
    final tagHasFranchise = parsed.franchiseTokens.isNotEmpty;

    // Las etiquetas de personaje de WD14 llevan la franquicia entre
    // paréntesis. Una etiqueta SIN paréntesis podría ser una etiqueta
    // general ("long hair", "rain"), así que solo se acepta si el nombre
    // coincide por completo.
    if (tagHasFranchise) {
      if (nameScore < _nameThreshold) return null;
    } else {
      if (nameScore < 0.99) return null;
    }

    var score = nameScore;
    var franchiseMatch = false;

    if (tagHasFranchise && _franchiseTokens.isNotEmpty) {
      final f = _tokenDice(_franchiseTokens, parsed.franchiseTokens);
      if (f >= 0.5) {
        franchiseMatch = true;
        score += _franchiseBonus;
      } else if (f == 0) {
        score -= _franchisePenalty;
      }
    }

    // Las etiquetas sin franquicia van siempre por detrás de las que la tienen.
    if (!tagHasFranchise) score -= 0.05;

    return CharacterTagMatch(score, franchiseMatch);
  }

  // ---------------------------------------------------------------------
  // Análisis de texto
  // ---------------------------------------------------------------------

  /// Separa "nombre (franquicia)" en palabras de nombre y de franquicia.
  static _ParsedTag _parse(String text) {
    final cached = _parseCache[text];
    if (cached != null) return cached;

    final franchisePart =
        _parenGroup.allMatches(text).map((m) => m.group(1)!).join(' ');
    final namePart = text.replaceAll(_parenGroup, ' ');

    final parsed = _ParsedTag(_tokenize(namePart), _tokenize(franchisePart));
    if (_parseCache.length > 200000) _parseCache.clear();
    _parseCache[text] = parsed;
    return parsed;
  }

  /// Minúsculas, sin acentos y partido por cualquier separador
  /// (espacio, "_", ",", "-", "'"...).
  static List<String> _tokenize(String text) {
    return normalizeForSearch(text)
        .split(_separators)
        .where((t) => t.isNotEmpty)
        .toList();
  }

  // ---------------------------------------------------------------------
  // Similitud
  // ---------------------------------------------------------------------

  static double _nameSimilarity(List<String> a, List<String> b) {
    // "laplacegray" vs "laplace gray", o el mismo conjunto en otro orden.
    if (a.join() == b.join()) return 1.0;
    final sa = List<String>.from(a)..sort();
    final sb = List<String>.from(b)..sort();
    if (sa.join(' ') == sb.join(' ')) return 1.0;
    return _tokenDice(a, b);
  }

  /// Parecido entre dos conjuntos de palabras, sin importar el orden.
  /// 1.0 = mismas palabras. "laplace" vs "laplace gray" = 0.75.
  static double _tokenDice(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final used = <int>{};
    var matched = 0;
    for (final ta in a) {
      for (var j = 0; j < b.length; j++) {
        if (used.contains(j)) continue;
        if (_tokenEquals(ta, b[j])) {
          used.add(j);
          matched++;
          break;
        }
      }
    }
    if (matched == 0) return 0;
    return (matched / a.length + matched / b.length) / 2;
  }

  /// Igualdad de palabras tolerando 1 error de tecleo en palabras largas
  /// ("laplase" ≈ "laplace"), pero no en cortas ("rem" ≠ "ram").
  static bool _tokenEquals(String a, String b) {
    if (a == b) return true;
    if (a.length < 5 || b.length < 5) return false;
    if ((a.length - b.length).abs() > 1) return false;
    return _levenshtein(a, b) <= 1;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final curr = List<int>.filled(b.length + 1, 0);
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final del = prev[j] + 1;
        final ins = curr[j - 1] + 1;
        final sub = prev[j - 1] + cost;
        curr[j] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
      }
      prev = curr;
    }
    return prev[b.length];
  }
}