import 'models.dart' show PayMethod;

/// Pays où Sama360 est lancé (même liste que l'API : shared/countries.ts).
enum Country {
  // 9 chiffres : mobiles 7x, fixes 33
  sn(
    code: 'SN',
    name: 'Sénégal',
    flag: '🇸🇳',
    dial: '221',
    local: r'^[37]\d{8}$',
    groups: [2, 3, 2, 2],
    currency: 'XOF',
    taxIdLabel: 'NINEA',
    mobileMoney: [PayMethod.wave, PayMethod.orangeMoney, PayMethod.freeMoney],
    example: '77 123 45 67',
    cities: ['Dakar', 'Thiès', 'Touba', 'Saint-Louis', 'Kaolack', 'Mbour', 'Ziguinchor'],
  ),
  // 10 chiffres depuis 2021 : mobiles 01 (Moov), 05 (MTN), 07 (Orange) ; fixes 21, 25, 27
  ci(
    code: 'CI',
    name: "Côte d'Ivoire",
    flag: '🇨🇮',
    dial: '225',
    local: r'^(0[157]|2[157])\d{8}$',
    groups: [2, 2, 2, 2, 2],
    currency: 'XOF',
    taxIdLabel: 'N° CC',
    mobileMoney: [PayMethod.wave, PayMethod.orangeMoney, PayMethod.mtnMomo, PayMethod.moovMoney],
    example: '07 07 12 34 56',
    cities: ['Abidjan', 'Bouaké', 'Yamoussoukro', 'San-Pédro', 'Daloa', 'Korhogo', 'Man'],
  ),
  // 9 chiffres : mobiles 04, 05 (Airtel), 06 (MTN) ; fixes 22
  cg(
    code: 'CG',
    name: 'Congo',
    flag: '🇨🇬',
    dial: '242',
    local: r'^(0[1456]|22)\d{7}$',
    groups: [2, 3, 2, 2],
    currency: 'XAF',
    taxIdLabel: 'NIU',
    mobileMoney: [PayMethod.mtnMomo, PayMethod.airtelMoney],
    example: '06 612 34 56',
    cities: ['Brazzaville', 'Pointe-Noire', 'Dolisie', 'Nkayi', 'Ouesso', 'Owando'],
  );

  const Country({
    required this.code,
    required this.name,
    required this.flag,
    required this.dial,
    required this.local,
    required this.groups,
    required this.currency,
    required this.taxIdLabel,
    required this.mobileMoney,
    required this.example,
    required this.cities,
  });

  final String code;
  final String name;
  final String flag;

  /// Indicatif sans « + ».
  final String dial;

  /// Numéro national complet (sans indicatif), mobile ou fixe.
  final String local;
  final List<int> groups;
  final String currency;
  final String taxIdLabel;
  final List<PayMethod> mobileMoney;
  final String example;
  final List<String> cities;

  RegExp get localRe => RegExp(local);

  static Country fromCode(String? code) => values.where((c) => c.code == code).firstOrNull ?? sn;

  /// Pays d'un numéro E.164, ou null s'il est d'ailleurs.
  static Country? ofPhone(String e164) {
    final digits = e164.replaceAll(RegExp(r'\D'), '');
    return values.where((c) => digits.startsWith(c.dial)).firstOrNull;
  }
}
