import 'package:intl/intl.dart';

import 'countries.dart';

final _group = NumberFormat('#,##0', 'fr');

/// 86500 → « 86 500 F » : la même écriture partout dans l'app (« FCFA » reste sur les factures imprimées).
String money(num amount) => '${_group.format(amount.round())} F';

/// 86500 → « 86 500 F » (version courte pour les cartes)
String moneyShort(num amount) => '${_group.format(amount.round())} F';

/// 3 → « 3 », 2.5 → « 2,5 »
String qty(num q) {
  if (q == q.roundToDouble()) return q.round().toString();
  return NumberFormat('0.###', 'fr').format(q);
}

/// « Awa Diallo » → « AD »
String initials(String? name, {String fallback = '?'}) {
  final parts = (name ?? '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return fallback;
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
}

const _smallWords = {'de', 'du', 'des', 'la', 'le', 'les', 'à', 'au', 'aux', 'et', 'en', "l'", "d'"};

/// « Beurre de karité 250 g » → « BK » : initiales des deux premiers mots significatifs.
String productInitials(String name) {
  final words = name
      .split(RegExp(r"[\s']+"))
      .where((w) => w.length > 1 && !_smallWords.contains(w.toLowerCase()) && !RegExp(r'^\d').hasMatch(w))
      .toList();
  if (words.isEmpty) return initials(name);
  return words.take(2).map((w) => w.substring(0, 1).toUpperCase()).join();
}

/// Prénom pour les salutations.
String firstName(String? name) => (name ?? '').trim().split(RegExp(r'\s+')).first;

final _day = DateFormat('d MMM', 'fr');
final _dayTime = DateFormat("d MMM, HH:mm", 'fr');
final _longDay = DateFormat('EEEE d MMMM', 'fr');

String shortDate(DateTime d) => _day.format(d.toLocal());
String dateTime(DateTime d) => _dayTime.format(d.toLocal());
String longDate(DateTime d) => _longDay.format(d.toLocal());

final _fullDay = DateFormat('d MMMM y', 'fr');

/// Fin d'un abonnement, lisible : « 3 jours restants », « jusqu’au 12 mars 2027 », « à vie ».
String proEndLabel(DateTime until) {
  final days = (until.difference(DateTime.now()).inHours / 24).ceil();
  if (days > 3650) return 'à vie';
  if (days <= 1) return 'dernier jour';
  if (days <= 31) return '$days jours restants';
  return 'jusqu’au ${_fullDay.format(until.toLocal())}';
}

/// Numéro saisi → E.164, d'après le pays de la boutique. Accepte aussi un numéro
/// international (« +221 77… », « 00225… ») ; les numéros de nos pays sont vérifiés.
/// Renvoie null s'il est invalide.
String? localPhone(String input, Country country) {
  final trimmed = input.trim();
  var digits = trimmed.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return null;
  if (trimmed.startsWith('+')) {
    // déjà international
  } else if (digits.startsWith('00')) {
    digits = digits.substring(2);
  } else if (country.localRe.hasMatch(digits)) {
    digits = '${country.dial}$digits';
  } else if (!(digits.startsWith(country.dial) && country.localRe.hasMatch(digits.substring(country.dial.length)))) {
    return null;
  }
  if (digits.length < 8 || digits.length > 15) return null;
  final known = Country.ofPhone(digits);
  if (known != null && !known.localRe.hasMatch(digits.substring(known.dial.length))) return null;
  return '+$digits';
}

/// « Numéro invalide : 10 chiffres, ex. 07 07 12 34 56 »
String invalidPhone(Country c) => 'Numéro invalide : ${c.groups.fold(0, (a, b) => a + b)} chiffres, ex. ${c.example}';

/// Numéro sénégalais saisi sans indicatif → E.164 (raccourci de [localPhone]).
String? senegalPhone(String input) => localPhone(input, Country.sn);

/// +221771234567 → « 77 123 45 67 » ; +2250707123456 → « 07 07 12 34 56 ».
/// Un numéro d'un autre pays est rendu tel quel.
String displayPhone(String e164) {
  final c = Country.ofPhone(e164);
  if (c == null || !e164.startsWith('+')) return e164;
  final local = e164.substring(1 + c.dial.length);
  if (!c.localRe.hasMatch(local)) return e164;
  final parts = <String>[];
  var at = 0;
  for (final g in c.groups) {
    parts.add(local.substring(at, at + g));
    at += g;
  }
  return parts.join(' ');
}

/// « +221 77 123 45 67 » : indicatif et numéro lisible.
String intlPhone(String e164) {
  final c = Country.ofPhone(e164);
  final local = displayPhone(e164);
  return c == null || local == e164 ? e164 : '+${c.dial} $local';
}

/// Numéro à afficher dans un champ : local s'il est du pays de la boutique, sinon complet.
String editablePhone(String e164, Country country) =>
    Country.ofPhone(e164) == country ? displayPhone(e164) : intlPhone(e164);
