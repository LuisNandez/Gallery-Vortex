// search_ranking.dart
//
// Lógica pura (sin Flutter) del buscador principal: cómo se interpreta lo
// que escribe el usuario y cómo se puntúa cada resultado para ordenarlos por
// relevancia. Ejemplo: al buscar "rem", un archivo con la etiqueta
// "rem (re:zero)" puntúa mucho más que uno con "lorem", porque la coincidencia
// es una palabra completa y no el final de otra palabra.

import 'ui_utils.dart';

// ---------------------------------------------------------------------------
// Coincidencia de una palabra dentro de un texto
// ---------------------------------------------------------------------------

bool _isWordUnit(int cu) =>
    (cu >= 0x61 && cu <= 0x7A) || // a-z (el texto ya viene en minúsculas)
    (cu >= 0x30 && cu <= 0x39) || // 0-9
    cu > 0x7F; // letras no ASCII

/// Calidad de la coincidencia de [token] dentro de [text] (ambos YA
/// normalizados con [normalizeForSearch]). Devuelve 0 si no aparece.
///
///  1.00  el texto es exactamente la palabra          ("rem" en "rem")
///  0.95  palabra completa al inicio del texto        ("rem" en "rem (re:zero)")
///  0.90  palabra completa en otra posición           ("rem" en "maid rem")
///  0.75  inicio de una palabra (prefijo)             ("rem" en "remilia")
///  0.30  final de una palabra                        ("rem" en "lorem")
///  0.20  en medio de una palabra                     ("rem" en "premium")
double matchQuality(String text, String token) {
  var idx = text.indexOf(token);
  if (idx < 0) return 0;
  if (text.length == token.length) return 1.0;

  var best = 0.0;
  while (idx >= 0) {
    final end = idx + token.length;
    final startOk = idx == 0 || !_isWordUnit(text.codeUnitAt(idx - 1));
    final endOk = end == text.length || !_isWordUnit(text.codeUnitAt(end));

    double q;
    if (startOk && endOk) {
      q = idx == 0 ? 0.95 : 0.90;
    } else if (startOk) {
      q = idx == 0 ? 0.78 : 0.75;
    } else if (endOk) {
      q = 0.30;
    } else {
      q = 0.20;
    }
    if (q > best) best = q;
    if (best >= 0.95) break;
    idx = text.indexOf(token, idx + 1);
  }
  return best;
}

// ---------------------------------------------------------------------------
// Consulta
// ---------------------------------------------------------------------------

/// Lo que escribió el usuario, ya normalizado y separado en palabras.
///  - "rem ram"   → ambas palabras deben aparecer (en cualquier campo).
///  - "rem -lorem" → una palabra con "-" delante EXCLUYE esos resultados.
class ParsedSearch {
  final List<String> include;
  final List<String> exclude;
  const ParsedSearch(this.include, this.exclude);

  static final RegExp _spaces = RegExp(r'\s+');

  bool get isEmpty => include.isEmpty && exclude.isEmpty;
  bool get hasInclude => include.isNotEmpty;

  factory ParsedSearch.parse(String raw) {
    final normalized = normalizeForSearch(raw.trim());
    if (normalized.isEmpty) return const ParsedSearch([], []);
    final include = <String>[];
    final exclude = <String>[];
    for (final token in normalized.split(_spaces)) {
      if (token.isEmpty) continue;
      if (token.startsWith('-')) {
        if (token.length > 1) exclude.add(token.substring(1));
      } else {
        include.add(token);
      }
    }
    return ParsedSearch(include, exclude);
  }
}

// ---------------------------------------------------------------------------
// Documento de búsqueda de una imagen
// ---------------------------------------------------------------------------

/// Textos normalizados de una imagen, separados por tipo de campo para poder
/// darle más peso a unos que a otros. [all] los junta (separados por "\n")
/// para descartar rápido con un único `contains`.
class ImageSearchDoc {
  final List<String> tags;
  final List<String> characters;
  final List<String> franchises;
  final List<String> profileValues;
  final String all;

  const ImageSearchDoc({
    required this.tags,
    required this.characters,
    required this.franchises,
    required this.profileValues,
    required this.all,
  });

  static const ImageSearchDoc empty = ImageSearchDoc(
      tags: [], characters: [], franchises: [], profileValues: [], all: '');
}

/// Etiqueta sugerida con el número de imágenes que la usan.
class TagSuggestion {
  final String tag;
  final int count;
  const TagSuggestion(this.tag, this.count);
}

// ---------------------------------------------------------------------------
// Puntuación
// ---------------------------------------------------------------------------

const double _wCharacter = 100;
const double _wTag = 85;
const double _wName = 80;
const double _wFranchise = 45;
const double _wProfileField = 40;

/// Puntuación (≈0-100) de un nombre suelto (carpetas). -1 = no coincide.
double scoreName(String name, ParsedSearch q) {
  for (final ex in q.exclude) {
    if (name.contains(ex)) return -1;
  }
  if (q.include.isEmpty) return 0;
  var total = 0.0;
  for (final tok in q.include) {
    final m = matchQuality(name, tok);
    if (m == 0) return -1;
    total += m * 100;
  }
  return total / q.include.length;
}

double _bestIn(List<String> texts, String token, double weight, double current) {
  var best = current;
  for (final t in texts) {
    if (!t.contains(token)) continue;
    final s = matchQuality(t, token) * weight;
    if (s > best) best = s;
  }
  return best;
}

/// Puntuación (≈0-110) de un archivo: nombre + documento de metadatos.
/// -1 = no coincide (falta una palabra o aparece una excluida).
double scoreDocument(String name, ImageSearchDoc doc, ParsedSearch q) {
  for (final ex in q.exclude) {
    if (name.contains(ex) || doc.all.contains(ex)) return -1;
  }
  if (q.include.isEmpty) return 0;

  // Descarte rápido: cada palabra tiene que estar en alguna parte.
  for (final tok in q.include) {
    if (!name.contains(tok) && !doc.all.contains(tok)) return -1;
  }

  var total = 0.0;
  for (final tok in q.include) {
    var best = name.contains(tok) ? matchQuality(name, tok) * _wName : 0.0;
    best = _bestIn(doc.characters, tok, _wCharacter, best);
    best = _bestIn(doc.tags, tok, _wTag, best);
    best = _bestIn(doc.franchises, tok, _wFranchise, best);
    best = _bestIn(doc.profileValues, tok, _wProfileField, best);
    total += best;
  }
  var score = total / q.include.length;

  // Pequeño extra si la frase completa aparece junta en un mismo campo.
  if (q.include.length > 1) {
    final phrase = q.include.join(' ');
    if (name.contains(phrase) || doc.all.contains(phrase)) score += 8;
  }
  return score;
}