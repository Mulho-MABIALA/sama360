import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/discount.dart';
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
  const CartLine(
    this.product,
    this.quantity, {
    this.extras = const [],
    this.serials = const [],
    this.discount = Discount.none,
  });
  final Product product;
  final double quantity;

  /// Remise sur cette ligne (propriétaire, gérant) : % ou montant.
  final Discount discount;

  /// Restaurant : suppléments choisis (ajoutés au prix).
  final List<ProductExtra> extras;

  /// Téléphonie : IMEI / numéros de série, un par appareil.
  final List<String> serials;

  /// Identifiant de la ligne : un même plat avec ou sans supplément fait deux lignes.
  String get key => lineKey(product.id, extras);

  String get name => extras.isEmpty ? product.name : '${product.name} + ${extras.map((e) => e.name).join(', ')}';

  /// Prix unitaire appliqué (prix de gros dès la quantité minimale, comme le serveur), suppléments compris.
  int get unitPrice => product.unitPriceFor(quantity) + extras.fold(0, (s, e) => s + e.price);
  bool get wholesale => product.unitPriceFor(quantity) != product.price;

  /// Montant avant remise.
  int get gross => (unitPrice * quantity).round();
  int get discountAmount => discount.of(gross);
  int get total => gross - discountAmount;

  CartLine copyWith({double? quantity, List<String>? serials, Discount? discount}) => CartLine(
    product,
    quantity ?? this.quantity,
    extras: extras,
    serials: serials ?? this.serials,
    discount: discount ?? this.discount,
  );
}

/// Clé d'une ligne de panier : le produit et ses suppléments.
String lineKey(String productId, List<ProductExtra> extras) =>
    extras.isEmpty ? productId : '$productId|${(extras.map((e) => e.name).toList()..sort()).join('|')}';

class CartState {
  const CartState({
    this.lines = const {},
    this.customer,
    this.mode = PaymentMode.cash,
    this.deposit = 0,
    this.depositMethod,
    this.noAdvance = false,
    this.saleId,
    this.rewards = 0,
    this.rewardValue = 0,
    this.saleDiscount = Discount.none,
  });

  final Map<String, CartLine> lines; // par productId, dans l'ordre d'ajout
  final Contact? customer;
  final PaymentMode mode;
  final int deposit; // avance reçue pour une vente à crédit

  /// Vente à crédit : comment l'avance a été payée (espèces, Wave…), ou [noAdvance] si le client n'a rien donné.
  /// L'un des deux est obligatoire : on ne valide pas un crédit sans l'avoir dit.
  final PayMethod? depositMethod;
  final bool noAdvance;
  final String? saleId; // généré une fois : un renvoi après coupure ne crée pas de doublon

  /// Récompenses de fidélité utilisées et valeur de chacune (remise en F).
  final int rewards;
  final int rewardValue;

  /// Remise sur toute la vente (propriétaire, gérant) : 10 % ou 5 000 F.
  final Discount saleDiscount;

  /// Articles avant toute remise.
  int get grossTotal => lines.values.fold(0, (s, l) => s + l.gross);

  /// Remises faites sur les lignes.
  int get lineDiscounts => lines.values.fold(0, (s, l) => s + l.discountAmount);

  /// Total des articles (remises par ligne déduites), avant la remise sur la vente et la fidélité.
  int get subtotal => lines.values.fold(0, (s, l) => s + l.total);
  int get saleDiscountAmount => saleDiscount.of(subtotal);
  int get loyaltyDiscount => math.min(rewards * rewardValue, subtotal - saleDiscountAmount);

  /// Toutes les remises (articles, vente, fidélité).
  int get discountTotal => grossTotal - total;

  /// À payer : articles moins les remises.
  int get total => subtotal - saleDiscountAmount - loyaltyDiscount;
  double get itemCount => lines.values.fold(0.0, (s, l) => s + l.quantity);
  bool get isEmpty => lines.isEmpty;

  /// Quantité d'un produit dans le panier, toutes lignes confondues (avec ou sans suppléments).
  double quantityOf(String productId) =>
      lines.values.where((l) => l.product.id == productId).fold(0.0, (s, l) => s + l.quantity);

  CartState copyWith({
    Map<String, CartLine>? lines,
    Contact? customer,
    bool clearCustomer = false,
    PaymentMode? mode,
    int? deposit,
    PayMethod? depositMethod,
    bool clearDepositMethod = false,
    bool? noAdvance,
    String? saleId,
    int? rewards,
    int? rewardValue,
    Discount? saleDiscount,
  }) => CartState(
    lines: lines ?? this.lines,
    customer: clearCustomer ? null : (customer ?? this.customer),
    mode: mode ?? this.mode,
    deposit: deposit ?? this.deposit,
    depositMethod: clearDepositMethod ? null : (depositMethod ?? this.depositMethod),
    noAdvance: noAdvance ?? this.noAdvance,
    saleId: saleId ?? this.saleId,
    rewards: rewards ?? this.rewards,
    rewardValue: rewardValue ?? this.rewardValue,
    saleDiscount: saleDiscount ?? this.saleDiscount,
  );
}

/// Paiements envoyés à l'API pour un panier donné. Fonction pure, testée.
List<({PayMethod method, int amount})> paymentsFor(
  int total,
  PaymentMode mode,
  int deposit, {
  PayMethod depositMethod = PayMethod.cash,
}) {
  if (mode == PaymentMode.credit) {
    final d = deposit.clamp(0, total);
    return d > 0 ? [(method: depositMethod, amount: d)] : [];
  }
  return total > 0 ? [(method: mode.method!, amount: total)] : [];
}

/// Pourquoi le panier ne peut pas encore être encaissé (null si c'est possible).
String? checkoutBlocker(CartState cart) {
  if (cart.isEmpty) return 'Ajoutez au moins un article';
  if (cart.mode == PaymentMode.credit && cart.customer == null) return 'Choisissez le client pour une vente à crédit';
  if (cart.mode == PaymentMode.credit) {
    if (!cart.noAdvance && cart.depositMethod == null) {
      return 'Le client a-t-il donné une avance ? Choisissez « Aucune avance » ou comment il a payé';
    }
    if (cart.depositMethod != null && cart.deposit <= 0) return 'Entrez le montant de l’avance reçue';
    if (cart.depositMethod != null && cart.deposit >= cart.total) {
      return "L'avance couvre tout : ce n'est pas un crédit, encaissez normalement";
    }
  }
  return null;
}

class CartController extends Notifier<CartState> {
  @override
  CartState build() => const CartState();

  void add(Product p, {double step = 1}) {
    final lines = Map.of(state.lines);
    final current = lines[p.id];
    lines[p.id] = current == null ? CartLine(p, step) : current.copyWith(quantity: current.quantity + step);
    state = state.copyWith(lines: lines);
  }

  /// Quantité saisie à la main (2,5 m, 1 carton de 24…) ; 0 retire la ligne.
  void setQuantity(Product p, double quantity) => setLineQuantity(p.id, quantity, product: p);

  /// Quantité d'une ligne précise (plat avec suppléments…) ; 0 la retire.
  void setLineQuantity(String key, double quantity, {Product? product}) {
    final lines = Map.of(state.lines);
    final current = lines[key];
    if (quantity <= 0) {
      lines.remove(key);
    } else if (current != null) {
      lines[key] = current.copyWith(quantity: quantity);
    } else if (product != null) {
      lines[key] = CartLine(product, quantity);
    }
    state = state.copyWith(lines: lines);
  }

  /// Ajoute une ligne (plat avec suppléments, téléphones avec leurs IMEI) ; fusionne avec la même.
  void addLine(CartLine line) {
    final lines = Map.of(state.lines);
    final current = lines[line.key];
    lines[line.key] = current == null
        ? line
        : current.copyWith(
            quantity: current.quantity + line.quantity,
            serials: [...current.serials, ...line.serials.where((s) => !current.serials.contains(s))],
          );
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
      // Un appareil de moins : son IMEI part aussi
      lines[productId] = current.copyWith(
        quantity: next,
        serials: current.serials.isEmpty ? null : current.serials.take(next.round()).toList(),
      );
    }
    state = state.copyWith(lines: lines);
  }

  // Changer de client annule les récompenses choisies (ce sont les points de l'ancien client).
  void setCustomer(Contact? c) => state = c == null
      ? state.copyWith(clearCustomer: true, rewards: 0)
      : state.copyWith(customer: c, rewards: c.id == state.customer?.id ? state.rewards : 0);

  /// Remise sur une ligne du panier (Discount.none pour la retirer).
  void setLineDiscount(String key, Discount d) {
    final current = state.lines[key];
    if (current == null) return;
    state = state.copyWith(
      lines: {
        ...state.lines,
        key: current.copyWith(discount: d),
      },
    );
  }

  /// Remise sur toute la vente.
  void setSaleDiscount(Discount d) => state = state.copyWith(saleDiscount: d);

  /// Utilise [n] récompenses de fidélité (0 pour annuler), chacune valant [value] F.
  void setRewards(int n, int value) => state = state.copyWith(rewards: n < 0 ? 0 : n, rewardValue: value);

  /// Changer de mode remet l'avance à zéro (rien n'est choisi d'avance pour un crédit).
  void setMode(PaymentMode m) =>
      state = m == state.mode ? state : state.copyWith(mode: m, deposit: 0, clearDepositMethod: true, noAdvance: false);
  void setDeposit(int amount) => state = state.copyWith(deposit: amount < 0 ? 0 : amount);

  /// Crédit : aucune avance (null) ou avance reçue par [method].
  void setAdvance(PayMethod? method) => state = method == null
      ? state.copyWith(noAdvance: true, deposit: 0, clearDepositMethod: true)
      : state.copyWith(noAdvance: false, depositMethod: method);

  /// Identifiant de vente stable jusqu'au succès (idempotence côté serveur).
  String ensureSaleId() {
    final id = state.saleId ?? const Uuid().v7();
    if (state.saleId == null) state = state.copyWith(saleId: id);
    return id;
  }

  void clear() => state = const CartState();
}

final cartProvider = NotifierProvider<CartController, CartState>(CartController.new);
