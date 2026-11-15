import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/models.dart';

/// Mode d'encaissement choisi à la caisse.
enum PaymentMode {
  cash('Espèces', PayMethod.cash),
  wave('Wave', PayMethod.wave),
  orangeMoney('O. Money', PayMethod.orangeMoney),
  credit('Crédit', null);

  const PaymentMode(this.label, this.method);
  final String label;
  final PayMethod? method; // null = crédit
}

class CartLine {
  const CartLine(this.product, this.quantity);
  final Product product;
  final double quantity;
  int get total => (product.price * quantity).round();
}

class CartState {
  const CartState({this.lines = const {}, this.customer, this.mode = PaymentMode.cash, this.deposit = 0, this.saleId});

  final Map<String, CartLine> lines; // par productId, dans l'ordre d'ajout
  final Contact? customer;
  final PaymentMode mode;
  final int deposit; // acompte en espèces pour une vente à crédit
  final String? saleId; // généré une fois : un renvoi après coupure ne crée pas de doublon

  int get total => lines.values.fold(0, (s, l) => s + l.total);
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
  }) => CartState(
    lines: lines ?? this.lines,
    customer: clearCustomer ? null : (customer ?? this.customer),
    mode: mode ?? this.mode,
    deposit: deposit ?? this.deposit,
    saleId: saleId ?? this.saleId,
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

  void setCustomer(Contact? c) => state = c == null ? state.copyWith(clearCustomer: true) : state.copyWith(customer: c);
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
