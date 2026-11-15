import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sama360/core/format.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/permissions.dart';
import 'package:sama360/features/auth/auth_controller.dart';
import 'package:sama360/features/sales/cart.dart';
import 'package:sama360/router.dart';

const _p1 = Product(id: 'p1', name: 'Beurre de karité', price: 3800, cost: 2000);
const _p2 = Product(id: 'p2', name: 'Huile de coco', price: 4000, cost: 2600);
const _me = Me(id: 'u', phone: '+221771234567', fullName: 'Awa Diallo');

void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  group('format', () {
    test('montants en FCFA avec séparateur de milliers', () {
      expect(money(86500).replaceAll(' ', ' ').replaceAll(' ', ' '), '86 500 FCFA');
      expect(moneyShort(1240000).replaceAll(' ', ' ').replaceAll(' ', ' '), '1 240 000 F');
    });
    test('quantités', () {
      expect(qty(3), '3');
      expect(qty(2.5), '2,5');
    });
    test('initiales et prénom', () {
      expect(initials('Awa Diallo'), 'AD');
      expect(initials('Moussa'), 'M');
      expect(initials(''), '?');
      expect(firstName('Awa Diallo'), 'Awa');
      expect(productInitials('Beurre de karité 250 g'), 'BK');
      expect(productInitials('Huile de coco 500 ml'), 'HC');
      expect(productInitials('Savon noir'), 'SN');
      expect(productInitials('Sachet'), 'S');
    });
    test('numéros sénégalais', () {
      expect(senegalPhone('77 123 45 67'), '+221771234567');
      expect(senegalPhone('221771234567'), '+221771234567');
      expect(senegalPhone('12345678'), isNull);
      expect(senegalPhone('991234567'), isNull);
      expect(displayPhone('+221771234567'), '77 123 45 67');
    });
  });

  test('permissions identiques au serveur', () {
    expect(hasPermission(['*'], 'reports:read'), isTrue);
    expect(hasPermission(['sales:*'], 'sales:void'), isTrue);
    expect(hasPermission(['sales:read', 'sales:create'], 'reports:read'), isFalse);
  });

  group('panier', () {
    test('ajoute, retire et totalise', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final cart = c.read(cartProvider.notifier)
        ..add(_p1)
        ..add(_p1)
        ..add(_p2);
      expect(c.read(cartProvider).total, 11600);
      expect(c.read(cartProvider).itemCount, 3);
      cart.remove('p1');
      expect(c.read(cartProvider).quantityOf('p1'), 1);
      cart.remove('p2');
      expect(c.read(cartProvider).lines.keys, ['p1']);
    });

    test("l'identifiant de vente reste stable jusqu'à la réussite (idempotence)", () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final cart = c.read(cartProvider.notifier)..add(_p1);
      final id = cart.ensureSaleId();
      expect(cart.ensureSaleId(), id);
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-')));
      cart.clear();
      expect(c.read(cartProvider).saleId, isNull);
    });

    test('paiements envoyés selon le mode', () {
      expect(paymentsFor(11600, PaymentMode.cash, 0), [(method: PayMethod.cash, amount: 11600)]);
      expect(paymentsFor(11600, PaymentMode.wave, 999), [(method: PayMethod.wave, amount: 11600)]);
      expect(paymentsFor(20000, PaymentMode.credit, 5000), [(method: PayMethod.cash, amount: 5000)]);
      expect(paymentsFor(20000, PaymentMode.credit, 0), isEmpty);
    });

    test('ce qui bloque l’encaissement', () {
      const customer = Contact(id: 'c', name: 'Aminata');
      final line = {'p2': const CartLine(_p2, 5)};
      expect(checkoutBlocker(const CartState()), contains('article'));
      expect(checkoutBlocker(CartState(lines: line, mode: PaymentMode.credit)), contains('client'));
      expect(checkoutBlocker(CartState(lines: line, mode: PaymentMode.credit, customer: customer, deposit: 20000)), contains('Espèces'));
      expect(checkoutBlocker(CartState(lines: line, mode: PaymentMode.credit, customer: customer, deposit: 5000)), isNull);
      expect(checkoutBlocker(CartState(lines: line)), isNull);
    });
  });

  group('redirections selon la session', () {
    const link = BusinessLink(id: 'b', name: 'Awa Beauté', role: 'owner', roleName: 'Propriétaire');
    AsyncValue<AuthState> s(AuthState a) => AsyncData(a);

    test('chargement et erreur → écran de démarrage', () {
      expect(authRedirect(const AsyncLoading(), '/'), '/splash');
      expect(authRedirect(AsyncError(Exception(), StackTrace.empty), '/pos'), '/splash');
    });
    test('déconnecté → connexion, sauf écrans publics', () {
      expect(authRedirect(s(const AuthState()), '/'), '/login');
      expect(authRedirect(s(const AuthState()), '/otp'), isNull);
    });
    test('profil incomplet puis entreprise manquante', () {
      expect(authRedirect(s(const AuthState(me: Me(id: 'u', phone: '+221'))), '/'), '/profile');
      expect(authRedirect(s(const AuthState(me: _me)), '/'), '/business');
    });
    test('prêt → accueil, et le changement d’entreprise reste possible', () {
      const ready = AuthState(me: Me(id: 'u', phone: '+221', fullName: 'Awa', businesses: [link]), businessId: 'b');
      expect(authRedirect(s(ready), '/login'), '/');
      expect(authRedirect(s(ready), '/splash'), '/');
      expect(authRedirect(s(ready), '/pos'), isNull);
      expect(authRedirect(s(ready), '/business'), isNull);
    });
  });
}
