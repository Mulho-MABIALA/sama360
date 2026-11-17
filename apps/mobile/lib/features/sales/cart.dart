import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/models.dart';

/// Mode d'encaissement choisi à la caisse.
enum PaymentMode {
  cash('Espèces', PayMethod.cash),
  wave('Wave', PayMethod.wave),
  orangeMoney('O. Money', PayMethod.orangeMoney),
  freeMoney('Free', PayMethod.freeMoney),
  mtnMomo('MTN MoMo', PayMethod.mtnMomo),
  moovMoney('Moov', PayMethod.moovMoney),
  airtelMoney('Airtel', PayMethod.airtelMoney),
  credit('Crédit', null);

  const PaymentMode(this.label, this.method);
  final String label;
  final PayMethod? method; // null = crédit

  /// Boutons de la caisse : espèces, paiements mobiles du pays, crédit.
  /// (Au Sénégal, Free Money reste dans les factures : la caisse garde Wave et Orange Money.)
  static List<PaymentMode> forCountry(Country c) => [
    cash,
    for (final m in c.mobileMoney)
      if (m != PayMethod.freeMoney) values.firstWhere((p) => p.method == m),
    credit,
  ];
}

class CartLine {
  const CartLine(this.product, this.quantity);
  final Product product;
  final double quantity;

  /// Prix unitaire appliqué (prix de gros dès la quantité minimale, comme le serveur).
  int get unitPrice => product.unitPriceFor(quantity);
  bool get wholesale => unitPrice != product.price;
  int get total => (unitPrice * quantity).round();
}

class CartState {
  const CartState({
    this.lines = const {},
    this.customer,
    this.mode = PaymentMode.cash,
    this.deposit = 0,
    this.saleId,
    this.rewards = 0,
    this.rewardValue = 0,
  });

  final Map<String, CartLine> lines; // par productId, dans l'ordre d'ajout
  final Contact? customer;
  final PaymentMode mode;
  final int deposit; // acompte en espèces pour une vente à crédit
  final String? saleId; // généré une fois : un renvoi après coupure ne crée pas de doublon

  /// Récompenses de fidélité utilisées et valeur de chacune (remise en F).
  final int rewards;
  final int rewardValue;

  /// Total des articles, avant la remise fidélité.
  int get subtotal => lines.values.fold(0, (s, l) => s + l.total);
  int get loyaltyDiscount => math.min(rewards * rewardValue, subtotal);

  /// À payer : articles moins la remise fidélité.
  int get total => subtotal - loyaltyDiscount;
  double get itemCount => lines.values.fold(0.0, (s, l) => s + l.quantity);
  bool get isEmpty => lines.isEmpty;
  double quantityOf(String productId) => lines[productId]?.quantity ?? 0;

  CartState copyWith({
    Map<String, CartLine>? lines,
    Contact? customer,
    bool clearCustomer = false,
    PaymentMode? mode,
    int? deposit,
    String? saleId,
    int? rewards,
    int? rewardValue,
  }) => CartState(
    lines: lines ?? this.lines,
    customer: clearCustomer ? null : (customer ?? this.customer),
    mode: mode ?? this.mode,
    deposit: deposit ?? this.deposit,
    saleId: saleId ?? this.saleId,
    rewards: rewards ?? this.rewards,
    rewardValue: rewardValue ?? this.rewardValue,
  );
}

/// Paiements envoyés à l'API pour un panier donné. Fonction pure, testée.
List<({PayMethod method, int amount})> paymentsFor(int total, PaymentMode mode, int deposit) {
  if (mode == PaymentMode.credit) {
    final d = deposit.clamp(0, total);
    return d > 0 ? [(method: PayMethod.cash, amount: d)] : [];
  }
  return total > 0 ? [(method: mode.method!, amount: total)] : [];
}

/// Pourquoi le panier ne peut pas encore être encaissé (null si c'est possible).
String? checkoutBlocker(CartState cart) {
  if (cart.isEmpty) return 'Ajoutez au moins un article';
  if (cart.mode == PaymentMode.credit && cart.customer == null) return 'Choisissez le client pour une vente à crédit';
  if (cart.mode == PaymentMode.credit && cart.deposit >= cart.total) {
    return "L'acompte couvre tout : choisissez Espèces";
  }
  return null;
}

class CartController extends Notifier<CartState> {
  @override
  CartState build() => const CartState();

  void add(Product p, {double step = 1}) {
    final lines = Map.of(state.lines);
    lines[p.id] = CartLine(p, (lines[p.id]?.quantity ?? 0) + step);
    state = state.copyWith(lines: lines);
  }

  void remove(String productId, {double step = 1}) {
    final current = state.lines[productId];
    if (current == null) return;
    final lines = Map.of(state.lines);
    final next = current.quantity - step;
    if (next <= 0) {
      lines.remove(productId);
    } else {
      lines[productId] = CartLine(current.product, next);
    }
    state = state.copyWith(lines: lines);
  }

  // Changer de client annule les récompenses choisies (ce sont les points de l'ancien client).
  void setCustomer(Contact? c) => state = c == null
      ? state.copyWith(clearCustomer: true, rewards: 0)
      : state.copyWith(customer: c, rewards: c.id == state.customer?.id ? state.rewards : 0);

  /// Utilise [n] récompenses de fidélité (0 pour annuler), chacune valant [value] F.
  void setRewards(int n, int value) => state = state.copyWith(rewards: n < 0 ? 0 : n, rewardValue: value);
  void setMode(PaymentMode m) => state = state.copyWith(mode: m);
  void setDeposit(int amount) => state = state.copyWith(deposit: amount < 0 ? 0 : amount);

  /// Identifiant de vente stable jusqu'au succès (idempotence côté serveur).
  String ensureSaleId() {
    final id = state.saleId ?? const Uuid().v7();
    if (state.saleId == null) state = state.copyWith(saleId: id);
    return id;
  }

  void clear() => state = const CartState();
}

final cartProvider = NotifierProvider<CartController, CartState>(CartController.new);
