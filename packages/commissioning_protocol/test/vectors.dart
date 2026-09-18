import 'dart:io';
import 'dart:typed_data';

/// Lettore dei file di `protocol/vectors`, lo stesso formato letto dai test in
/// C: una parola iniziale, poi parole libere e coppie chiave=valore.
class VecLine {
  VecLine(this.number, this.tokens);

  final int number;
  final List<String> tokens;

  String get kind => tokens.first;

  int get arrow {
    final index = tokens.indexOf('->');
    return index < 0 ? tokens.length : index;
  }

  String? get(String key, [int from = 1, int? to]) {
    final end = to ?? tokens.length;
    for (var i = from; i < end && i < tokens.length; i++) {
      final token = tokens[i];
      if (token.startsWith('$key=')) return token.substring(key.length + 1);
    }
    return null;
  }

  String require(String key, [int from = 1, int? to]) {
    final value = get(key, from, to);
    if (value == null) {
      throw StateError('riga $number: manca il campo $key');
    }
    return value;
  }

  int integer(String key, [int from = 1, int? to]) =>
      int.parse(require(key, from, to));

  @override
  String toString() => 'riga $number: ${tokens.join(' ')}';
}

List<VecLine> readVectors(String name) {
  final file = File('../../protocol/vectors/$name');
  final lines = <VecLine>[];
  var number = 0;
  for (final raw in file.readAsLinesSync()) {
    number++;
    final tokens =
        raw.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty || tokens.first.startsWith('#')) continue;
    lines.add(VecLine(number, tokens));
  }
  return lines;
}

Uint8List hex(String text) {
  if (text == '-') return Uint8List(0);
  return Uint8List.fromList([
    for (var i = 0; i < text.length; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16),
  ]);
}
