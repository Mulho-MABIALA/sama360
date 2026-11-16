import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sama360/features/home/monument.dart';
import 'package:sama360/features/home/monuments_data.dart';

void main() {
  test('un monument différent chaque jour, qui tourne sur toute la liste', () {
    expect(monumentOfDay(DateTime(2026, 11, 16)).name, 'Monument de la Renaissance africaine');
    expect(monumentOfDay(DateTime(2026, 11, 16, 23, 59)).name, 'Monument de la Renaissance africaine');
    expect(monumentOfDay(DateTime(2026, 11, 17)).name, monuments[1].name);
    final seen = {for (var d = 0; d < monuments.length; d++) monumentOfDay(DateTime(2026, 11, 16 + d)).name};
    expect(seen.length, monuments.length);
    expect(monumentOfDay(DateTime(2026, 11, 16 + monuments.length)).name, monuments.first.name);
    // Avant la date de référence aussi (changement d'heure compris)
    expect(monumentOfDay(DateTime(2026, 11, 15)).name, monuments.last.name);
    expect(monumentOfDay(DateTime(2027, 3, 28)), isA<Monument>());
  });

  test('chaque photo existe et est créditée', () {
    expect(monuments.length, greaterThanOrEqualTo(30));
    for (final m in monuments) {
      expect(File(m.asset).existsSync(), isTrue, reason: m.asset);
      expect(m.author, isNotEmpty);
      expect(m.license, matches(RegExp(r'CC|Public domain')));
      expect(m.source, startsWith('https://commons.wikimedia.org/'));
    }
    expect(monuments.map((m) => m.asset).toSet().length, monuments.length);
  });
}
