/// Remise : un pourcentage (10 %) ou un montant fixe (5 000 F).
/// Le pourcentage est recalculé si le montant de base change (article ajouté au panier…).
class Discount {
  const Discount.percent(int this.percent) : amount = 0;
  const Discount.amount(this.amount) : percent = null;
  static const none = Discount.amount(0);

  final int? percent;
  final int amount;

  bool get isPercent => percent != null;
  bool get isNone => isPercent ? percent! <= 0 : amount <= 0;

  /// Montant de la remise (en F) sur [base] : jamais plus que la base.
  int of(int base) {
    if (base <= 0 || isNone) return 0;
    final v = isPercent ? (base * percent! / 100).round() : amount;
    return v.clamp(0, base);
  }

  @override
  bool operator ==(Object other) => other is Discount && other.percent == percent && other.amount == amount;
  @override
  int get hashCode => Object.hash(percent, amount);
}
