import 'package:intl/intl.dart';

final _group = NumberFormat('#,##0', 'fr');

/// 86500 → « 86 500 FCFA »
String money(num amount) => '${_group.format(amount.round())} FCFA';

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

/// Numéro sénégalais saisi sans indicatif → E.164. Renvoie null s'il est invalide.
String? senegalPhone(String input) {
  final digits = input.replaceAll(RegExp(r'\D'), '');
  if (RegExp(r'^[37]\d{8}$').hasMatch(digits)) return '+221$digits';
  if (RegExp(r'^221[37]\d{8}$').hasMatch(digits)) return '+$digits';
  return null;
}

/// +221771234567 → « 77 123 45 67 »
String displayPhone(String e164) {
  final m = RegExp(r'^\+221(\d{2})(\d{3})(\d{2})(\d{2})$').firstMatch(e164);
  if (m == null) return e164;
  return '${m[1]} ${m[2]} ${m[3]} ${m[4]}';
}
