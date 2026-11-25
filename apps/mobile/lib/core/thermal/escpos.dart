/// Commandes ESC/POS pour les petites imprimantes thermiques (58 et 80 mm).
/// Texte encodé en page de codes 850 (accents français) ; le reste est remplacé.
class EscPos {
  EscPos({this.width = 32}) {
    _bytes.addAll([0x1B, 0x40]); // initialisation
    _bytes.addAll([0x1B, 0x74, 0x02]); // page de codes 850
  }

  /// Caractères par ligne : 32 sur un rouleau de 58 mm, 48 sur 80 mm.
  final int width;
  final _bytes = <int>[];

  List<int> get bytes => List.unmodifiable(_bytes);

  void _align(int a) => _bytes.addAll([0x1B, 0x61, a]);
  void _bold(bool on) => _bytes.addAll([0x1B, 0x45, on ? 1 : 0]);
  void _size(int s) => _bytes.addAll([0x1D, 0x21, s]);

  /// Une ligne de texte (coupée en plusieurs si elle est trop longue).
  void text(String s, {bool bold = false, bool center = false, bool big = false}) {
    _align(center ? 1 : 0);
    _bold(bold);
    if (big) _size(0x11); // double largeur et hauteur
    final w = big ? width ~/ 2 : width;
    for (final line in wrap(s, w)) {
      _bytes.addAll(encode(line));
      _bytes.add(0x0A);
    }
    if (big) _size(0);
    _bold(false);
    _align(0);
  }

  /// « Libellé ........ Montant » sur une ligne (le libellé passe à la ligne s'il est trop long).
  void row(String left, String right, {bool bold = false, bool big = false}) {
    _bold(bold);
    if (big) _size(0x01); // double hauteur seulement : la largeur reste la même
    final r = right.length >= width ? right.substring(0, width - 1) : right;
    final room = width - r.length - 1;
    final lines = wrap(left, room);
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final out = i == lines.length - 1 ? '${l.padRight(room)} $r' : l;
      _bytes.addAll(encode(out));
      _bytes.add(0x0A);
    }
    if (big) _size(0);
    _bold(false);
  }

  void dashes() {
    _bytes.addAll(encode('-' * width));
    _bytes.add(0x0A);
  }

  void feed([int lines = 1]) => _bytes.addAll([0x1B, 0x64, lines]);

  /// Avance le papier puis coupe (sans effet sur les imprimantes sans massicot).
  void cut() {
    feed(3);
    _bytes.addAll([0x1D, 0x56, 0x41, 0x03]);
  }

  /// Découpe un texte en lignes de [w] caractères au plus, sur les espaces si possible.
  static List<String> wrap(String s, int w) {
    final t = normalize(s);
    if (w <= 0) return [t];
    final out = <String>[];
    var rest = t;
    while (rest.length > w) {
      var cut = rest.lastIndexOf(' ', w);
      if (cut <= 0) cut = w;
      out.add(rest.substring(0, cut).trimRight());
      rest = rest.substring(cut).trimLeft();
    }
    out.add(rest);
    return out;
  }

  /// Espaces spéciaux et signes typographiques ramenés à ce que l'imprimante connaît.
  static String normalize(String s) => s
      .replaceAll(RegExp('[   ]'), ' ')
      .replaceAll(RegExp('[‘’]'), "'")
      .replaceAll(RegExp('[“”]'), '"')
      .replaceAll(RegExp('[–—−]'), '-')
      .replaceAll('…', '...')
      .replaceAll('×', 'x');

  static const _cp850 = {
    'Ç': 0x80, 'ü': 0x81, 'é': 0x82, 'â': 0x83, 'ä': 0x84, 'à': 0x85, 'ç': 0x87, 'ê': 0x88, //
    'ë': 0x89, 'è': 0x8A, 'ï': 0x8B, 'î': 0x8C, 'Ä': 0x8E, 'É': 0x90, 'ô': 0x93, 'ö': 0x94,
    'û': 0x96, 'ù': 0x97, 'Ö': 0x99, 'Ü': 0x9A, 'á': 0xA0, 'í': 0xA1, 'ó': 0xA2, 'ú': 0xA3,
    'ñ': 0xA4, 'Ñ': 0xA5, '«': 0xAE, '»': 0xAF, 'Á': 0xB5, 'Â': 0xB6, 'À': 0xB7, 'Ê': 0xD2,
    'Ë': 0xD3, 'È': 0xD4, 'Î': 0xD7, 'Ï': 0xD8, 'Ô': 0xE2, 'Ù': 0xEB, 'Û': 0xEA, '°': 0xF8,
  };

  /// Octets CP850 d'une ligne ; un caractère inconnu devient « ? ».
  static List<int> encode(String s) => [
    for (final ch in normalize(s).runes.map(String.fromCharCode))
      if (ch.codeUnitAt(0) < 0x80) ch.codeUnitAt(0) else _cp850[ch] ?? 0x3F,
  ];
}
