import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'admin_models.dart';
import 'firebase_options.dart';

class AdminRepository {
  static const allowedEmails = {
    'andrius.grudinskas@gmail.com',
    'mbilaz@gmail.com',
  };

  final FirebaseFirestore firestore;
  final FirebaseAuth auth;

  AdminRepository({FirebaseFirestore? firestore, FirebaseAuth? auth})
    : firestore = firestore ?? FirebaseFirestore.instance,
      auth = auth ?? FirebaseAuth.instance;

  User? get currentUser => auth.currentUser;

  bool get isAdmin => allowedEmails.contains(
    (currentUser?.email ?? '').trim().toLowerCase(),
  );

  Future<User> signIn() async {
    await GoogleSignIn.instance.initialize(
      serverClientId: AdminFirebaseOptions.googleWebClientId,
    );
    final googleUser = await GoogleSignIn.instance.authenticate();
    final authentication = googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      idToken: authentication.idToken,
    );
    final result = await auth.signInWithCredential(credential);
    final user = result.user;
    if (user == null) throw StateError('Prisijungti nepavyko.');
    if (!allowedEmails.contains((user.email ?? '').toLowerCase())) {
      await auth.signOut();
      await GoogleSignIn.instance.signOut();
      throw StateError('Šiai paskyrai administratoriaus prieiga nesuteikta.');
    }
    return user;
  }

  Future<void> signOut() async {
    await auth.signOut();
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }

  Future<AdminSnapshot> load() async {
    if (!isAdmin) throw StateError('Administratoriaus prieiga nesuteikta.');
    final results = await Future.wait([
      firestore.collection('userProfiles').get(),
      firestore.collection('premiumRequests').get(),
    ]);
    final profiles = results[0];
    final requests = results[1];
    final subscriptions = await Future.wait(
      profiles.docs.map(
        (profile) => firestore
            .doc('users/${profile.id}/subscription/current')
            .get(),
      ),
    );
    final users = <AdminUser>[];
    for (var index = 0; index < profiles.docs.length; index++) {
      final profile = profiles.docs[index];
      final value = profile.data();
      final subscription = subscriptions[index].data() ?? const {};
      users.add(
        AdminUser(
          uid: profile.id,
          email: '${value['email'] ?? ''}',
          name: '${value['displayName'] ?? ''}',
          createdAt: firestoreDate(value['createdAt']),
          lastSeenAt: firestoreDate(value['lastSeenAt']),
          plan: '${subscription['plan'] ?? 'free'}',
          status: '${subscription['status'] ?? 'active'}',
          provider: '${subscription['provider'] ?? 'manual'}',
          validUntil: firestoreDate(subscription['validUntil']),
        ),
      );
    }
    users.sort(
      (a, b) => (b.lastSeenAt ?? DateTime(2000)).compareTo(
        a.lastSeenAt ?? DateTime(2000),
      ),
    );
    return AdminSnapshot(
      users: users,
      requests: requests.docs
          .map((item) => PremiumRequest.fromMap(item.id, item.data()))
          .toList(),
    );
  }

  Future<List<PremiumRequest>> pendingRequests() async {
    if (!isAdmin) return const [];
    final result = await firestore
        .collection('premiumRequests')
        .where('status', isEqualTo: 'pending')
        .get();
    return result.docs
        .map((item) => PremiumRequest.fromMap(item.id, item.data()))
        .toList();
  }

  Future<void> approve(
    PremiumRequest request, {
    required String plan,
    DateTime? validUntil,
  }) async {
    if (!isAdmin) throw StateError('Administratoriaus prieiga nesuteikta.');
    final reviewer = currentUser!;
    final batch = firestore.batch();
    batch.set(firestore.doc('users/${request.uid}/subscription/current'), {
      'plan': plan,
      'status': 'active',
      'provider': 'manual',
      'validUntil': validUntil == null ? null : Timestamp.fromDate(validUntil),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': reviewer.email ?? reviewer.uid,
    });
    batch.set(
      firestore.doc('premiumRequests/${request.uid}'),
      {
        'status': 'approved',
        'approvedPlan': plan,
        'validUntil': validUntil == null
            ? null
            : Timestamp.fromDate(validUntil),
        'reviewedAt': FieldValue.serverTimestamp(),
        'reviewedBy': reviewer.email ?? reviewer.uid,
      },
      SetOptions(merge: true),
    );
    await batch.commit();
  }

  Future<void> reject(PremiumRequest request) async {
    if (!isAdmin) throw StateError('Administratoriaus prieiga nesuteikta.');
    await firestore.doc('premiumRequests/${request.uid}').set({
      'status': 'rejected',
      'reviewedAt': FieldValue.serverTimestamp(),
      'reviewedBy': currentUser?.email ?? currentUser?.uid,
    }, SetOptions(merge: true));
  }

  Future<void> setPlan(
    AdminUser user, {
    required String plan,
    required String status,
    DateTime? validUntil,
  }) async {
    if (!isAdmin) throw StateError('Administratoriaus prieiga nesuteikta.');
    await firestore.doc('users/${user.uid}/subscription/current').set({
      'plan': plan,
      'status': status,
      'provider': 'manual',
      'validUntil': validUntil == null ? null : Timestamp.fromDate(validUntil),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': currentUser?.email ?? currentUser?.uid,
    });
  }

  Future<void> deleteUser(AdminUser user) async {
    if (!isAdmin) throw StateError('Administratoriaus prieiga nesuteikta.');
    final email = user.email.trim().toLowerCase();
    if (user.uid == currentUser?.uid || allowedEmails.contains(email)) {
      throw StateError('Administratoriaus paskyros ištrinti negalima.');
    }

    final membershipRef = firestore.doc('users/${user.uid}/settings/household');
    final membership = await membershipRef.get();
    final householdId = '${membership.data()?['householdId'] ?? ''}';
    final batch = firestore.batch();

    if (householdId.isNotEmpty) {
      final householdRef = firestore.doc('households/$householdId');
      final household = await householdRef.get();
      final value = household.data() ?? const <String, dynamic>{};
      final members = List<String>.from(value['memberUids'] as List? ?? const []);
      final isOwner = value['ownerUid'] == user.uid;
      if (isOwner && members.any((uid) => uid != user.uid)) {
        throw StateError(
          'Pirmiausia perduokite šio namų ūkio administravimą kitam nariui.',
        );
      }
      if (isOwner) {
        final inviteCode = '${value['inviteCode'] ?? ''}';
        if (inviteCode.isNotEmpty) {
          batch.delete(firestore.doc('householdInvites/$inviteCode'));
        }
        batch.delete(firestore.doc('households/$householdId/data/state'));
        batch.delete(householdRef);
      } else {
        final accounts = Map<String, dynamic>.from(
          value['accounts'] as Map? ?? const {},
        )..remove(user.uid);
        batch.update(householdRef, {
          'memberUids': FieldValue.arrayRemove([user.uid]),
          'accounts': accounts,
        });
      }
    }

    batch.set(firestore.doc('deletedUsers/${user.uid}'), {
      'uid': user.uid,
      'email': user.email,
      'deletedAt': FieldValue.serverTimestamp(),
      'deletedBy': currentUser?.email ?? currentUser?.uid,
    });
    batch.delete(firestore.doc('users/${user.uid}/medibox/state'));
    batch.delete(membershipRef);
    batch.delete(firestore.doc('users/${user.uid}/subscription/current'));
    batch.delete(firestore.doc('premiumRequests/${user.uid}'));
    batch.delete(firestore.doc('userProfiles/${user.uid}'));
    await batch.commit();
  }
}
