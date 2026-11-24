import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'core/permissions.dart' show accessRedirect;
import 'core/providers.dart' show currentBusinessProvider;
import 'core/widgets.dart' show AccessDeniedScreen;
import 'features/admin/admin_dashboard.dart';
import 'features/admin/admin_merchant.dart';
import 'features/admin/admin_merchants.dart';
import 'features/admin/admin_payments.dart';
import 'features/notifications/notifications_screen.dart';
import 'features/loyalty/loyalty_screen.dart';
import 'features/reminders/reminders_screen.dart';
import 'features/settings/display_screen.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/login_screens.dart';
import 'features/assistant/assistant_screen.dart';
import 'features/auth/pin_screen.dart';
import 'features/profile/closure_screens.dart';
import 'features/booking/booking_screen.dart';
import 'features/delivery/delivery_screen.dart';
import 'features/catalog/product_photo.dart' show PickedPhoto;
import 'features/documents/documents_screen.dart';
import 'features/business/business_screen.dart';
import 'features/cash/cash_close_screen.dart';
import 'features/cash/cash_screen.dart';
import 'features/cash/cash_session_screen.dart';
import 'features/customers/customer_editor.dart';
import 'features/locations/locations_screen.dart';
import 'features/purchasing/invoice_scan_screen.dart';
import 'features/purchasing/purchase_editor.dart';
import 'features/pro/pro_screen.dart';
import 'features/shop/status_screen.dart';
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
String? authRedirect(AsyncValue<AuthState> auth, String location, {Uri? uri}) {
  const publicRoutes = ['/login', '/otp'];
  // Pendant le chargement de la session, on garde l'écran demandé (ex. retour de la page de paiement)
  String splash() => location == '/splash' || uri == null || uri.path == '/'
      ? '/splash'
      : '/splash?to=${Uri.encodeComponent(uri.toString())}';
  if (auth.isLoading && !auth.hasValue) return location == '/splash' ? null : splash();
  if (auth.hasError && !auth.hasValue) return location == '/splash' ? null : splash();

  final s = auth.value!;
  if (!s.signedIn) return publicRoutes.contains(location) ? null : '/login';
  if (s.needsProfile) return location == '/profile' ? null : '/profile';
  // Sans entreprise : en créer une, en restaurer une, ou supprimer son compte
  if (s.businessId == null) return location == '/business' || location == '/account/delete' ? null : '/business';
  if (location == '/splash') {
    final to = uri?.queryParameters['to'];
    return to != null && to.startsWith('/') && !to.startsWith('//') && !to.startsWith('/splash') ? to : '/';
  }
  if (publicRoutes.contains(location) || location == '/profile') return '/';
  return null;
}

/// Prévient go_router quand la session change.
class _AuthListenable extends ChangeNotifier {
  void notify() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _AuthListenable();
  ref.listen(authProvider, (_, _) => listenable.notify());
  // Droits connus (ou changés) : un écran interdit pour ce rôle se ferme
  ref.listen(currentBusinessProvider, (_, _) => listenable.notify());
  ref.onDispose(listenable.dispose);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: listenable,
    redirect: (_, state) =>
        authRedirect(ref.read(authProvider), state.matchedLocation, uri: state.uri) ??
        accessRedirect(ref.read(currentBusinessProvider).value?.permissions, state.matchedLocation),
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/denied', builder: (_, _) => const AccessDeniedScreen()),
      GoRoute(path: '/login', builder: (_, _) => const PhoneScreen()),
      GoRoute(
        path: '/otp',
        builder: (_, s) => OtpScreen(
          target: s.extra is OtpTarget ? s.extra! as OtpTarget : OtpTarget(s.extra as String? ?? ''),
        ),
      ),
      GoRoute(path: '/profile', builder: (_, _) => const ProfileSetupScreen()),
      GoRoute(path: '/business', builder: (_, _) => const BusinessScreen()),
      GoRoute(path: '/business/delete', builder: (_, _) => const DeleteBusinessScreen()),
      GoRoute(path: '/account/delete', builder: (_, _) => const DeleteAccountScreen()),
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
        path: '/pro',
        builder: (_, s) =>
            ProScreen(feature: ProFeature.of(s.uri.queryParameters['feature']), paidId: s.uri.queryParameters['paid']),
      ),
      GoRoute(path: '/referral', builder: (_, _) => const ReferralScreen()),
      GoRoute(path: '/admin', builder: (_, _) => const AdminDashboardScreen()),
      GoRoute(path: '/admin/merchants', builder: (_, _) => const AdminMerchantsScreen()),
      GoRoute(
        path: '/admin/merchants/:id',
        builder: (_, s) => AdminMerchantScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(path: '/admin/payments', builder: (_, _) => const AdminPaymentsScreen()),
      GoRoute(
        path: '/status',
        builder: (_, s) => StatusScreen(
          initialIds: (s.uri.queryParameters['ids'] ?? '').split(',').where((e) => e.isNotEmpty).toList(),
        ),
      ),
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
          prefill: s.extra is PurchasePrefill ? s.extra! as PurchasePrefill : null,
        ),
      ),
      GoRoute(path: '/locations', builder: (_, _) => const LocationsScreen()),
      GoRoute(path: '/stock/transfer', builder: (_, _) => const TransferScreen()),
      GoRoute(
        path: '/purchases/scan',
        builder: (_, s) => InvoiceScanScreen(photo: s.extra is PickedPhoto ? s.extra! as PickedPhoto : null),
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
      GoRoute(
        path: '/team',
        builder: (_, s) => TeamScreen(openInvite: s.uri.queryParameters['invite'] == '1'),
      ),
      GoRoute(path: '/categories', builder: (_, _) => const CategoriesScreen()),
      GoRoute(
        path: '/products/new',
        builder: (_, s) => ProductEditorScreen(
          initialBarcode: s.uri.queryParameters['barcode'],
          initialService: s.uri.queryParameters['service'] == '1',
        ),
      ),
      GoRoute(
        path: '/products/:id',
        builder: (_, s) => ProductEditorScreen(productId: s.pathParameters['id']),
      ),
      GoRoute(path: '/reports', builder: (_, _) => const ReportsScreen()),
      GoRoute(path: '/deliveries', builder: (_, _) => const DeliveriesScreen()),
      GoRoute(path: '/deliveries/new', builder: (_, _) => const NewDeliveryScreen()),
      GoRoute(path: '/deliveries/couriers', builder: (_, _) => const CouriersScreen()),
      GoRoute(path: '/booking', builder: (_, _) => const BookingScreen()),
      GoRoute(path: '/booking/settings', builder: (_, _) => const BookingSettingsScreen()),
      GoRoute(
        path: '/booking/new',
        builder: (_, s) => AppointmentEditorScreen(day: DateTime.tryParse(s.uri.queryParameters['day'] ?? '')),
      ),
      GoRoute(
        path: '/booking/edit',
        builder: (_, s) => s.extra is Appointment
            ? AppointmentEditorScreen(appointment: s.extra! as Appointment)
            : const BookingScreen(), // rechargement de page : on revient à l'agenda
      ),
      GoRoute(path: '/assistant', builder: (_, _) => const AssistantScreen()),
      GoRoute(path: '/documents', builder: (_, _) => const DocumentsScreen()),
      GoRoute(
        path: '/documents/new',
        builder: (_, s) => s.extra is PickedPhoto
            ? StoredDocumentEditorScreen(file: s.extra! as PickedPhoto)
            : const DocumentsScreen(), // rechargement de page : plus de fichier en mémoire
      ),
      GoRoute(
        path: '/documents/:id',
        builder: (_, s) => StoredDocumentScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/documents/:id/edit',
        builder: (_, s) => StoredDocumentEditorScreen(documentId: s.pathParameters['id']),
      ),
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
