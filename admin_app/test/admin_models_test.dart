import 'package:flutter_test/flutter_test.dart';
import 'package:medibox_admin/admin_models.dart';

AdminUser user({
  required String plan,
  String status = 'active',
  DateTime? validUntil,
}) => AdminUser(
  uid: plan,
  email: '$plan@example.com',
  name: '',
  createdAt: null,
  lastSeenAt: null,
  plan: plan,
  status: status,
  provider: 'manual',
  validUntil: validUntil,
);

void main() {
  test('counts free, monthly and yearly plans', () {
    final snapshot = AdminSnapshot(
      users: [
        user(plan: 'free'),
        user(plan: 'premium_monthly'),
        user(plan: 'premium_yearly'),
        user(plan: 'premium_monthly', status: 'cancelled'),
      ],
      requests: const [],
    );

    expect(snapshot.free, 2);
    expect(snapshot.premium, 2);
    expect(snapshot.monthly, 1);
    expect(snapshot.yearly, 1);
  });

  test('expired plan is counted as free', () {
    final snapshot = AdminSnapshot(
      users: [
        user(
          plan: 'premium_yearly',
          validUntil: DateTime.now().subtract(const Duration(days: 1)),
        ),
      ],
      requests: const [],
    );

    expect(snapshot.premium, 0);
    expect(snapshot.free, 1);
  });

  test('only pending requests appear in queue', () {
    final snapshot = AdminSnapshot(
      users: const [],
      requests: const [
        PremiumRequest(
          uid: 'pending',
          email: 'pending@example.com',
          requestedPlan: 'premium_monthly',
          status: 'pending',
          requestedAt: null,
          reviewedAt: null,
        ),
        PremiumRequest(
          uid: 'approved',
          email: 'approved@example.com',
          requestedPlan: 'premium_yearly',
          status: 'approved',
          requestedAt: null,
          reviewedAt: null,
        ),
      ],
    );

    expect(snapshot.pendingRequests.map((item) => item.uid), ['pending']);
  });
}

