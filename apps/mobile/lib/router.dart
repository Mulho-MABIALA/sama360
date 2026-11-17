import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'features/notifications/notifications_screen.dart';
import 'features/loyalty/loyalty_screen.dart';
import 'features/reminders/reminders_screen.dart';
import 'features/settings/display_screen.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/login_screens.dart';
import 'features/auth/pin_screen.dart';
import 'features/business/business_screen.dart';
import 'features/cash/cash_close_screen.dart';
import 'features/cash/cash_screen.dart';
import 'features/cash/cash_session_screen.dart';
import 'features/customers/customer_editor.dart';
import 'features/purchasing/purchase_editor.dart';
import 'features/shop/shop_order_screen.dart';
import 'features/shop/shop_screen.dart';
import 'features/shop/shop_settings_screen.dart';
import 'features/purchasing/purchase_screen.dart';
import 'features/purchasing/purchases_screen.dart';
import 'features/customers/customers_screens.dart';
import 'features/home/home_screen.dart';
import 'features/inventory/stock_screen.dart';
import 'core/models.dart';
import 'features/catalog/categories_screen.dart';
import 'features/catalog/product_editor.dart';
import 'features/invoicing/document_editor.dart';
import 'features/invoicing/document_screen.dart';
import 'features/invoicing/invoices_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/reports/insights_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/sales/pos_screen.dart';
import 'features/team/team_screen.dart';
import 'features/sales/receipt_screen.dart';
import 'features/sales/sales_history_screen.dart';
import 'features/shell/shell.dart';

/// Où envoyer l'utilisateur selon l'état de sa session. Fonction pure, testée.
String? authRedirect(AsyncValue<AuthState> auth, String location) {
  const publicRoutes = ['/login', '/otp'];
  if (auth.isLoading && !auth.hasValue) return location == '/splash' ? null : '/splash';
  if (auth.hasError && !auth.hasValue) return location == '/splash' ? null : '/splash';

  final s = auth.value!;
  if (!s.signedIn) return publicRoutes.contains(location) ? null : '/login';
  if (s.needsProfile) return location == '/profile' ? null : '/profile';
  if (s.businessId == null) return location == '/business' ? null : '/business';
  if (publicRoutes.contains(location) || location == '/profile' || location == '/splash') return '/';
  return null;
}

/// Prévient go_router quand la session change.
class _AuthListenable extends ChangeNotifier {
  void notify() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _AuthListenable();
  ref.listen(authProvider, (_, _) => listenable.notify());
  ref.onDispose(listenable.dispose);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: listenable,
    redirect: (_, state) => authRedirect(ref.read(authProvider), state.matchedLocation),
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, _) => const PhoneScreen()),
      GoRoute(
        path: '/otp',
        builder: (_, s) => OtpScreen(phone: s.extra as String? ?? ''),
      ),
      GoRoute(path: '/profile', builder: (_, _) => const ProfileSetupScreen()),
      GoRoute(path: '/business', builder: (_, _) => const BusinessScreen()),
      GoRoute(path: '/cash', builder: (_, _) => const CashScreen()),
      GoRoute(path: '/notifications', builder: (_, _) => const NotificationsScreen()),
      GoRoute(path: '/reminders', builder: (_, _) => const RemindersScreen()),
      GoRoute(path: '/settings/display', builder: (_, _) => const DisplaySettingsScreen()),
      GoRoute(path: '/loyalty', builder: (_, _) => const LoyaltyScreen()),
      GoRoute(path: '/loyalty/settings', builder: (_, _) => const LoyaltySettingsScreen()),
      GoRoute(
        path: '/cash/close',
        builder: (_, s) => CashCloseScreen(sessionId: s.uri.queryParameters['session']),
      ),
      GoRoute(path: '/cash/history', builder: (_, _) => const CashHistoryScreen()),
      GoRoute(
        path: '/cash/sessions/:id',
        builder: (_, s) => CashSessionScreen(sessionId: s.pathParameters['id']!),
      ),
      GoRoute(path: '/shop', builder: (_, _) => const ShopScreen()),
      GoRoute(
        path: '/shop/settings',
        builder: (_, s) => ShopSettingsScreen(opening: s.uri.queryParameters['open'] == '1'),
      ),
      GoRoute(path: '/shop/products', builder: (_, _) => const ShopProductsScreen()),
      GoRoute(
        path: '/shop/orders/:id',
        builder: (_, s) => ShopOrderScreen(orderId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/purchases',
        builder: (_, s) => PurchasesScreen(suppliersTab: s.uri.queryParameters['tab'] == 'suppliers'),
      ),
      GoRoute(
        path: '/purchases/new',
        builder: (_, s) => PurchaseEditorScreen(
          supplierId: s.uri.queryParameters['supplierId'],
          lowStock: s.uri.queryParameters['low'] == '1',
        ),
      ),
      GoRoute(
        path: '/purchases/:id',
        builder: (_, s) => PurchaseScreen(purchaseId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/purchases/:id/edit',
        builder: (_, s) => PurchaseEditorScreen(editId: s.pathParameters['id']!),
      ),
      GoRoute(path: '/suppliers/new', builder: (_, _) => const CustomerEditorScreen(supplier: true)),
      GoRoute(
        path: '/suppliers/:id',
        builder: (_, s) => SupplierScreen(supplierId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/suppliers/:id/edit',
        builder: (_, s) => CustomerEditorScreen(customerId: s.pathParameters['id']!, supplier: true),
      ),
      GoRoute(
        path: '/customers/new',
        builder: (_, s) => CustomerEditorScreen(initialName: s.uri.queryParameters['name']),
      ),
      GoRoute(
        path: '/customers/:id',
        builder: (_, s) => CustomerScreen(customerId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/customers/:id/edit',
        builder: (_, s) => CustomerEditorScreen(customerId: s.pathParameters['id']!),
      ),
      GoRoute(path: '/account', builder: (_, _) => const ProfileScreen()),
      GoRoute(path: '/team', builder: (_, _) => const TeamScreen()),
      GoRoute(path: '/categories', builder: (_, _) => const CategoriesScreen()),
      GoRoute(
        path: '/products/new',
        builder: (_, s) => ProductEditorScreen(initialBarcode: s.uri.queryParameters['barcode']),
      ),
      GoRoute(
        path: '/products/:id',
        builder: (_, s) => ProductEditorScreen(productId: s.pathParameters['id']),
      ),
      GoRoute(path: '/reports', builder: (_, _) => const ReportsScreen()),
      GoRoute(
        path: '/pin/change',
        builder: (_, _) => const PinScreen(mode: PinMode.change),
      ),
      GoRoute(path: '/insights', builder: (_, _) => const InsightsScreen()),
      GoRoute(path: '/insights/week', builder: (_, _) => const WeeklyReportScreen()),
      GoRoute(
        path: '/invoices',
        builder: (_, s) => InvoicesScreen(initialKind: DocKind.fromApi(s.uri.queryParameters['kind'] ?? 'invoice')),
      ),
      GoRoute(
        path: '/invoices/new',
        builder: (_, s) => DocumentEditorScreen(kind: DocKind.fromApi(s.uri.queryParameters['kind'])),
      ),
      GoRoute(
        path: '/invoices/:id',
        builder: (_, s) => DocumentScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/invoices/:id/edit',
        builder: (_, s) => DocumentEditorScreen(kind: DocKind.quote, editId: s.pathParameters['id']),
      ),
      GoRoute(path: '/sales', builder: (_, _) => const SalesHistoryScreen()),
      GoRoute(
        path: '/sales/:id',
        builder: (_, s) => ReceiptScreen(saleId: s.pathParameters['id']!),
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/', builder: (_, _) => const HomeScreen())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/pos', builder: (_, _) => const PosScreen())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/stock',
                builder: (_, s) => StockScreen(lowOnly: s.uri.queryParameters['low'] == '1'),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/customers',
                builder: (_, s) => CustomersScreen(
                  initialFilter: s.uri.queryParameters['debt'] == '1' ? CustomerFilter.debt : CustomerFilter.all,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
