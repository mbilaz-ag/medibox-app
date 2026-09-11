import 'package:cloud_firestore/cloud_firestore.dart';

DateTime? firestoreDate(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

class AdminUser {
  final String uid;
  final String email;
  final String name;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;
  final String plan;
  final String status;
  final String provider;
  final DateTime? validUntil;

  const AdminUser({
    required this.uid,
    required this.email,
    required this.name,
    required this.createdAt,
    required this.lastSeenAt,
    required this.plan,
    required this.status,
    required this.provider,
    required this.validUntil,
  });

  bool get isPremium {
    if (status != 'active' || plan == 'free') return false;
    return validUntil == null || validUntil!.isAfter(DateTime.now());
  }

  bool get isMonthly => isPremium && plan == 'premium_monthly';
  bool get isYearly => isPremium && plan == 'premium_yearly';
}

class PremiumRequest {
  final String uid;
  final String email;
  final String requestedPlan;
  final String status;
  final DateTime? requestedAt;
  final DateTime? reviewedAt;

  const PremiumRequest({
    required this.uid,
    required this.email,
    required this.requestedPlan,
    required this.status,
    required this.requestedAt,
    required this.reviewedAt,
  });

  factory PremiumRequest.fromMap(String id, Map<String, dynamic> value) =>
      PremiumRequest(
        uid: '${value['uid'] ?? id}',
        email: '${value['email'] ?? ''}',
        requestedPlan: '${value['requestedPlan'] ?? 'premium_monthly'}',
        status: '${value['status'] ?? 'pending'}',
        requestedAt: firestoreDate(value['requestedAt']),
        reviewedAt: firestoreDate(value['reviewedAt']),
      );
}

class AdminSnapshot {
  final List<AdminUser> users;
  final List<PremiumRequest> requests;

  const AdminSnapshot({required this.users, required this.requests});

  List<PremiumRequest> get pendingRequests =>
      requests.where((item) => item.status == 'pending').toList()
        ..sort(
          (a, b) => (a.requestedAt ?? DateTime(2000)).compareTo(
            b.requestedAt ?? DateTime(2000),
          ),
        );

  int get premium => users.where((item) => item.isPremium).length;
  int get free => users.length - premium;
  int get monthly => users.where((item) => item.isMonthly).length;
  int get yearly => users.where((item) => item.isYearly).length;
  int get expiringSoon => users.where((item) {
    final until = item.validUntil;
    return item.isPremium &&
        until != null &&
        until.isBefore(DateTime.now().add(const Duration(days: 30)));
  }).length;
}

