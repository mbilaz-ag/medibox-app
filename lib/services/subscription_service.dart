import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

enum SubscriptionPlan {
  free,
  premiumMonthly,
  premiumYearly;

  String get firestoreValue => switch (this) {
    free => 'free',
    premiumMonthly => 'premium_monthly',
    premiumYearly => 'premium_yearly',
  };

  static SubscriptionPlan parse(Object? value) => switch ('$value') {
    'premium_monthly' => premiumMonthly,
    'premium_yearly' => premiumYearly,
    _ => free,
  };
}

enum SubscriptionProvider {
  manual,
  stripe,
  googlePlay,
  appStore;

  String get firestoreValue => switch (this) {
    manual => 'manual',
    stripe => 'stripe',
    googlePlay => 'google_play',
    appStore => 'app_store',
  };

  static SubscriptionProvider parse(Object? value) => switch ('$value') {
    'stripe' => stripe,
    'google_play' => googlePlay,
    'app_store' => appStore,
    _ => manual,
  };
}

@immutable
class SubscriptionEntitlement {
  final SubscriptionPlan plan;
  final SubscriptionProvider provider;
  final bool active;
  final DateTime? validUntil;

  const SubscriptionEntitlement({
    this.plan = SubscriptionPlan.free,
    this.provider = SubscriptionProvider.manual,
    this.active = true,
    this.validUntil,
  });

  static const free = SubscriptionEntitlement();

  bool get hasPremium {
    if (!active || plan == SubscriptionPlan.free) return false;
    final expiry = validUntil;
    return expiry == null || expiry.isAfter(DateTime.now());
  }

  SubscriptionPlan get effectivePlan => hasPremium ? plan : SubscriptionPlan.free;

  factory SubscriptionEntitlement.fromMap(Map<String, dynamic>? value) {
    if (value == null) return free;
    final rawExpiry = value['validUntil'];
    DateTime? expiry;
    if (rawExpiry is Timestamp) {
      expiry = rawExpiry.toDate();
    } else if (rawExpiry is DateTime) {
      expiry = rawExpiry;
    } else if (rawExpiry is String) {
      expiry = DateTime.tryParse(rawExpiry);
    }
    return SubscriptionEntitlement(
      plan: SubscriptionPlan.parse(value['plan']),
      provider: SubscriptionProvider.parse(value['provider']),
      active: value['status'] == null || value['status'] == 'active',
      validUntil: expiry,
    );
  }
}

/// Provider-neutral source of truth for paid access.
///
/// Today the entitlement is edited manually in Firestore. Stripe, Google Play
/// and App Store integrations can later update the same protected document via
/// a trusted backend, without changing feature checks in the app.
class SubscriptionService extends ChangeNotifier {
  SubscriptionService._();
  static final instance = SubscriptionService._();

  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _entitlementSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _premiumRequestSubscription;
  SubscriptionEntitlement _entitlement = SubscriptionEntitlement.free;
  bool _premiumRequestPending = false;
  bool _initialized = false;
  bool _loading = false;
  String _message = '';

  SubscriptionEntitlement get entitlement => _entitlement;
  bool get hasPremium => _entitlement.hasPremium;
  bool get loading => _loading;
  String get message => _message;
  bool get premiumRequestPending => _premiumRequestPending;

  DocumentReference<Map<String, dynamic>> _document(String uid) =>
      FirebaseFirestore.instance.doc('users/$uid/subscription/current');

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen(
      _bindUser,
      onError: (_) => _setError('subscription_auth_error'),
    );
    await _bindUser(FirebaseAuth.instance.currentUser);
  }

  Future<void> _bindUser(User? user) async {
    await _entitlementSubscription?.cancel();
    await _premiumRequestSubscription?.cancel();
    _entitlementSubscription = null;
    _premiumRequestSubscription = null;
    if (user == null) {
      _loading = false;
      _message = '';
      _premiumRequestPending = false;
      _setEntitlement(SubscriptionEntitlement.free);
      return;
    }
    _loading = true;
    _message = '';
    notifyListeners();
    try {
      await _upsertUserProfile(user);
    } catch (_) {
      // A profile is useful for administration, but must never block the app.
    }
    _entitlementSubscription = _document(user.uid).snapshots().listen(
      (snapshot) {
        _loading = false;
        _message = '';
        _setEntitlement(SubscriptionEntitlement.fromMap(snapshot.data()));
      },
      onError: (_) {
        _loading = false;
        _setError('subscription_read_error');
      },
    );
    _premiumRequestSubscription = FirebaseFirestore.instance
        .doc('premiumRequests/${user.uid}')
        .snapshots()
        .listen((snapshot) {
      _premiumRequestPending = snapshot.data()?['status'] == 'pending';
      notifyListeners();
    });
  }

  Future<void> _upsertUserProfile(User user) async {
    await FirebaseFirestore.instance.doc('userProfiles/${user.uid}').set({
      'uid': user.uid,
      'email': user.email ?? '',
      'displayName': user.displayName ?? '',
      'photoUrl': user.photoURL ?? '',
      'isAnonymous': user.isAnonymous,
      'providers': user.providerData.map((value) => value.providerId).toList(),
      'createdAt': user.metadata.creationTime ?? FieldValue.serverTimestamp(),
      'lastSeenAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> refresh() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _setEntitlement(SubscriptionEntitlement.free);
      return;
    }
    _loading = true;
    _message = '';
    notifyListeners();
    try {
      final snapshot = await _document(user.uid).get();
      _loading = false;
      _setEntitlement(SubscriptionEntitlement.fromMap(snapshot.data()));
    } catch (_) {
      _loading = false;
      _setError('subscription_read_error');
    }
  }

  Future<void> requestPremium(SubscriptionPlan plan) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('sign_in_required');
    await FirebaseFirestore.instance.doc('premiumRequests/${user.uid}').set({
      'uid': user.uid,
      'email': user.email ?? '',
      'requestedPlan': plan.firestoreValue,
      'status': 'pending',
      'requestedAt': FieldValue.serverTimestamp(),
      'termsVersion': '2026-09-11',
      'termsAcceptedAt': FieldValue.serverTimestamp(),
      'immediateServiceRequested': true,
    });
  }

  void _setEntitlement(SubscriptionEntitlement value) {
    _entitlement = value;
    notifyListeners();
  }

  void _setError(String value) {
    _message = value;
    _entitlement = SubscriptionEntitlement.free;
    notifyListeners();
  }

  @visibleForTesting
  void setEntitlementForTesting(SubscriptionEntitlement value) =>
      _setEntitlement(value);

  Future<void> disposeService() async {
    await _authSubscription?.cancel();
    await _entitlementSubscription?.cancel();
    await _premiumRequestSubscription?.cancel();
    _initialized = false;
  }
}
