import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/services/subscription_service.dart';

void main() {
  test('missing entitlement defaults to Free', () {
    final entitlement = SubscriptionEntitlement.fromMap(null);
    expect(entitlement.effectivePlan, SubscriptionPlan.free);
    expect(entitlement.hasPremium, isFalse);
  });

  test('active monthly and yearly plans unlock Premium', () {
    for (final plan in ['premium_monthly', 'premium_yearly']) {
      final entitlement = SubscriptionEntitlement.fromMap({
        'plan': plan,
        'status': 'active',
        'provider': 'manual',
        'validUntil': DateTime.now().add(const Duration(days: 30)).toIso8601String(),
      });
      expect(entitlement.hasPremium, isTrue);
    }
  });

  test('expired, inactive and unknown plans stay Free', () {
    final expired = SubscriptionEntitlement.fromMap({
      'plan': 'premium_monthly',
      'status': 'active',
      'validUntil': DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
    });
    final inactive = SubscriptionEntitlement.fromMap({
      'plan': 'premium_yearly',
      'status': 'cancelled',
    });
    final unknown = SubscriptionEntitlement.fromMap({'plan': 'enterprise'});
    expect(expired.hasPremium, isFalse);
    expect(inactive.hasPremium, isFalse);
    expect(unknown.hasPremium, isFalse);
  });

  test('future payment providers use the same entitlement model', () {
    expect(
      SubscriptionEntitlement.fromMap({'provider': 'stripe'}).provider,
      SubscriptionProvider.stripe,
    );
    expect(
      SubscriptionEntitlement.fromMap({'provider': 'google_play'}).provider,
      SubscriptionProvider.googlePlay,
    );
    expect(
      SubscriptionEntitlement.fromMap({'provider': 'app_store'}).provider,
      SubscriptionProvider.appStore,
    );
  });
}
