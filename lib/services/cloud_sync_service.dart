import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'firebase_leaflet_service.dart';
import 'store.dart';
import 'subscription_service.dart';

enum CloudSyncState { signedOut, syncing, synced, offline, error }

class HouseholdInfo {
  final String id;
  final String name;
  final String role;
  final String inviteCode;
  final List<Map<String, String>> accounts;
  const HouseholdInfo({
    required this.id,
    required this.name,
    required this.role,
    this.inviteCode = '',
    this.accounts = const [],
  });
}

class CloudSyncService {
  CloudSyncService._();
  static final instance = CloudSyncService._();

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subscription;
  Timer? _uploadTimer;
  String _writer = '';
  bool _applyingRemote = false;
  bool _uploading = false;
  bool _uploadAgain = false;
  CloudSyncState state = CloudSyncState.signedOut;
  String message = '';

  User? get user {
    try {
      return FirebaseAuth.instance.currentUser;
    } catch (_) {
      return null;
    }
  }

  Future<void> initialize() async {
    await FirebaseLeafletService.initialize();
    await SubscriptionService.instance.initialize();
    final config = jsonDecode(
      await rootBundle.loadString('config/google-services.json'),
    );
    final client = (config['client'] as List).firstWhere(
      (value) =>
          value['client_info']['android_client_info']['package_name'] ==
          'lt.medibox.medibox',
    );
    final oauthClients = (client['oauth_client'] as List? ?? const []);
    final webClient = oauthClients.where(
      (value) => value['client_type'] == 3,
    );
    if (webClient.isEmpty) throw StateError('google_oauth_not_configured');
    String? appleClientId;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      final iosConfig = jsonDecode(
        await rootBundle.loadString('config/firebase-ios.json'),
      );
      appleClientId = '${iosConfig['clientId']}';
    }
    await GoogleSignIn.instance.initialize(
      clientId: appleClientId,
      serverClientId: '${webClient.first['client_id']}',
    );
  }

  DocumentReference<Map<String, dynamic>> _personalDocument(String uid) =>
      FirebaseFirestore.instance.doc('users/$uid/medibox/state');

  DocumentReference<Map<String, dynamic>> _membershipDocument(String uid) =>
      FirebaseFirestore.instance.doc('users/$uid/settings/household');

  DocumentReference<Map<String, dynamic>> _householdDocument(String id) =>
      FirebaseFirestore.instance.doc('households/$id');

  DocumentReference<Map<String, dynamic>> _householdStateDocument(String id) =>
      FirebaseFirestore.instance.doc('households/$id/data/state');

  DocumentReference<Map<String, dynamic>> _activeDocument(AppData data) {
    final current = user;
    if (current == null) throw StateError('signed_out');
    return data.householdId.isEmpty
        ? _personalDocument(current.uid)
        : _householdStateDocument(data.householdId);
  }

  Future<void> resume(
    AppData data, {
    required Future<void> Function() onRemoteApplied,
  }) async {
    // Widget tests run with a fake clock. Firebase initialization owns a
    // real-world timeout, which would otherwise remain pending after the test
    // tree is disposed. Cloud sync is an integration concern and is exercised
    // separately from the application smoke test.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      await initialize();
      final current = FirebaseAuth.instance.currentUser;
      if (current == null) {
        state = CloudSyncState.signedOut;
        return;
      }
      await _loadMembership(current.uid, data);
      await _connect(data, onRemoteApplied: onRemoteApplied);
    } catch (error) {
      state = CloudSyncState.offline;
      message = readableError(error);
    }
  }

  Future<User> signIn(
    AppData data, {
    required Future<void> Function() onRemoteApplied,
  }) async {
    state = CloudSyncState.syncing;
    message = '';
    await initialize();
    final googleUser = await GoogleSignIn.instance.authenticate();
    final googleAuth = googleUser.authentication;
    final credential = GoogleAuthProvider.credential(idToken: googleAuth.idToken);
    final result = await FirebaseAuth.instance.signInWithCredential(credential);
    final current = result.user;
    if (current == null) throw StateError('google_user_missing');
    await _loadMembership(current.uid, data);
    await _connect(data, onRemoteApplied: onRemoteApplied);
    return current;
  }

  Future<void> _loadMembership(String uid, AppData data) async {
    final membership = await _membershipDocument(uid).get();
    final value = membership.data();
    if (value == null || '${value['householdId'] ?? ''}'.isEmpty) {
      data
        ..householdId = ''
        ..householdName = ''
        ..householdRole = '';
      return;
    }
    data
      ..householdId = '${value['householdId']}'
      ..householdName = '${value['householdName'] ?? ''}'
      ..linkedMemberId = '${value['linkedMemberId'] ?? ''}';
    final household = await _householdDocument(data.householdId).get();
    data.householdRole = household.data()?['ownerUid'] == uid ? 'owner' : 'member';
  }

  Future<void> _connect(
    AppData data, {
    required Future<void> Function() onRemoteApplied,
  }) async {
    final current = user!;
    state = CloudSyncState.syncing;
    _writer = _writer.isEmpty
        ? '${DateTime.now().microsecondsSinceEpoch}-${current.uid.hashCode.abs()}'
        : _writer;
    if (data.householdId.isNotEmpty) {
      await _loadPersonalProfile(current.uid, data);
    }
    final reference = _activeDocument(data);
    final remote = await reference.get();
    if (remote.exists && remote.data()?['payload'] is Map) {
      final payload = Map<String, dynamic>.from(remote.data()!['payload'] as Map);
      if (Store.containsPersonalContent(data) && data.householdId.isEmpty) {
        _mergeRemoteIntoLocal(data, payload);
        await _uploadNow(data);
      } else {
        Store.applyCloudPayload(
          data,
          payload,
          applyProfile: data.householdId.isEmpty,
        );
        await Store.save(data);
        await onRemoteApplied();
      }
    } else {
      await _uploadNow(data);
    }
    await _listen(data, onRemoteApplied);
    state = CloudSyncState.synced;
  }

  Future<void> _loadPersonalProfile(String uid, AppData data) async {
    final snapshot = await _personalDocument(uid).get();
    final payload = snapshot.data()?['payload'];
    if (payload is! Map) return;
    final profile = payload['profile'];
    if (profile is Map) {
      data.profile = UserProfile.fromJson(Map<String, dynamic>.from(profile));
    }
  }

  Future<void> _listen(
    AppData data,
    Future<void> Function() onRemoteApplied,
  ) async {
    await _subscription?.cancel();
    _subscription = _activeDocument(data).snapshots().listen((snapshot) async {
      final value = snapshot.data();
      if (_applyingRemote ||
          value == null ||
          value['writer'] == _writer ||
          value['payload'] is! Map) {
        return;
      }
      try {
        _applyingRemote = true;
        Store.applyCloudPayload(
          data,
          Map<String, dynamic>.from(value['payload'] as Map),
          applyProfile: data.householdId.isEmpty,
        );
        await Store.save(data);
        await onRemoteApplied();
        state = CloudSyncState.synced;
        message = '';
      } catch (error) {
        state = CloudSyncState.error;
        message = readableError(error);
      } finally {
        _applyingRemote = false;
      }
    });
  }

  void queueUpload(AppData data) {
    if (_applyingRemote || user == null) return;
    _uploadTimer?.cancel();
    _uploadTimer = Timer(const Duration(milliseconds: 900), () async {
      try {
        await _uploadNow(data);
      } catch (_) {}
    });
  }

  Future<void> syncNow(AppData data) => _uploadNow(data);

  Future<void> _uploadNow(AppData data) async {
    final current = user;
    if (current == null || _applyingRemote) return;
    if (_uploading) {
      _uploadAgain = true;
      return;
    }
    _uploading = true;
    state = CloudSyncState.syncing;
    try {
      await _activeDocument(data).set({
        'payload': Store.cloudPayload(
          data,
          includeProfile: data.householdId.isEmpty,
        ),
        'updatedAt': FieldValue.serverTimestamp(),
        'writer': _writer,
      });
      if (data.householdId.isNotEmpty) {
        await _savePersonalProfile(current.uid, data.profile);
      }
      if (data.householdId.isNotEmpty && data.householdRole == 'owner') {
        await _syncHouseholdAccountNames(data);
      }
      await Store.save(data);
      state = CloudSyncState.synced;
      message = '';
    } catch (error) {
      state = CloudSyncState.error;
      message = readableError(error);
      rethrow;
    } finally {
      _uploading = false;
      if (_uploadAgain) {
        _uploadAgain = false;
        queueUpload(data);
      }
    }
  }

  Future<void> _syncHouseholdAccountNames(AppData data) async {
    final reference = _householdDocument(data.householdId);
    final snapshot = await reference.get();
    final rawAccounts = snapshot.data()?['accounts'];
    if (rawAccounts is! Map) return;
    final updates = <String, Object>{};
    for (final entry in rawAccounts.entries) {
      if (entry.value is! Map) continue;
      final account = Map<String, dynamic>.from(entry.value as Map);
      final linkedMemberId = '${account['linkedMemberId'] ?? ''}';
      final linked = data.members.where((member) => member.id == linkedMemberId);
      if (linked.isEmpty || linked.first.name == '${account['name'] ?? ''}') {
        continue;
      }
      updates['accounts.${entry.key}.name'] = linked.first.name;
    }
    if (updates.isNotEmpty) await reference.update(updates);
  }

  Future<void> _savePersonalProfile(String uid, UserProfile profile) async {
    final reference = _personalDocument(uid);
    try {
      await reference.update({
        'payload.profile': profile.toJson(),
        'updatedAt': FieldValue.serverTimestamp(),
        'writer': _writer,
      });
    } on FirebaseException catch (error) {
      if (error.code != 'not-found') rethrow;
      await reference.set({
        'payload': {'schemaVersion': 1, 'profile': profile.toJson()},
        'updatedAt': FieldValue.serverTimestamp(),
        'writer': _writer,
      });
    }
  }

  Future<HouseholdInfo> createHousehold(
    String name,
    AppData data, {
    required bool shareExistingData,
    required Future<void> Function() onRemoteApplied,
  }) async {
    final current = user;
    if (current == null) throw StateError('signed_out');
    await _personalDocument(current.uid).set({
      'payload': Store.cloudPayload(data),
      'updatedAt': FieldValue.serverTimestamp(),
      'writer': _writer,
    });
    final household = FirebaseFirestore.instance.collection('households').doc();
    final code = await _newInviteCode();
    final self = _ensureSelfMember(data, current);
    await household.set({
      'name': name.trim(),
      'ownerUid': current.uid,
      'memberUids': [current.uid],
      'accounts': {
        current.uid: {
          'name': current.displayName ?? self.name,
          'email': current.email ?? '',
          'linkedMemberId': self.id,
        },
      },
      'inviteCode': code,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await FirebaseFirestore.instance.doc('householdInvites/$code').set({
      'householdId': household.id,
      'householdName': name.trim(),
      'ownerUid': current.uid,
      'active': true,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await _membershipDocument(current.uid).set({
      'householdId': household.id,
      'householdName': name.trim(),
      'role': 'owner',
      'linkedMemberId': self.id,
    });
    data
      ..householdId = household.id
      ..householdName = name.trim()
      ..householdRole = 'owner'
      ..linkedMemberId = self.id;
    if (!shareExistingData) {
      data
        ..meds = []
        ..reminders = []
        ..shopping = []
        ..appointments = []
        ..members = [self];
    }
    await _uploadNow(data);
    await _listen(data, onRemoteApplied);
    await Store.save(data);
    return householdInfo(data);
  }

  Future<HouseholdInfo> joinHousehold(
    String rawCode,
    AppData data, {
    required bool shareExistingData,
    required Future<void> Function() onRemoteApplied,
  }) async {
    final current = user;
    if (current == null) throw StateError('signed_out');
    final code = rawCode.trim().toUpperCase();
    final invite = await FirebaseFirestore.instance
        .doc('householdInvites/$code')
        .get();
    final invitation = invite.data();
    if (invitation == null || invitation['active'] != true) {
      throw StateError('invalid_invite');
    }
    final householdId = '${invitation['householdId']}';
    final householdName = '${invitation['householdName'] ?? ''}';
    final personalPayload = Store.cloudPayload(data);
    final personalProfile = UserProfile.fromJson(data.profile.toJson());
    final accountMember = _newAccountMember(data, current);
    await _householdDocument(householdId).update({
      'memberUids': FieldValue.arrayUnion([current.uid]),
      'accounts.${current.uid}': {
        'name': accountMember.name,
        'email': current.email ?? '',
        'linkedMemberId': accountMember.id,
      },
    });
    await _membershipDocument(current.uid).set({
      'householdId': householdId,
      'householdName': householdName,
      'role': 'member',
      'linkedMemberId': accountMember.id,
    });
    data
      ..householdId = householdId
      ..householdName = householdName
      ..householdRole = 'member'
      ..linkedMemberId = accountMember.id;
    final remote = await _householdStateDocument(householdId).get();
    if (remote.data()?['payload'] is Map) {
      final payload = Map<String, dynamic>.from(remote.data()!['payload'] as Map);
      Store.applyCloudPayload(data, payload, applyProfile: false);
      if (shareExistingData) _mergePayloadIntoLocal(data, personalPayload);
    }
    if (!data.members.any((member) => member.id == accountMember.id)) {
      data.members.add(accountMember);
    }
    data.profile = personalProfile;
    await _uploadNow(data);
    await _listen(data, onRemoteApplied);
    await Store.save(data);
    await onRemoteApplied();
    return householdInfo(data);
  }

  Future<String> regenerateInvite(AppData data) async {
    final current = user;
    if (current == null || data.householdRole != 'owner') {
      throw StateError('owner_required');
    }
    final household = await _householdDocument(data.householdId).get();
    final oldCode = '${household.data()?['inviteCode'] ?? ''}';
    final code = await _newInviteCode();
    await _householdDocument(data.householdId).update({'inviteCode': code});
    await FirebaseFirestore.instance.doc('householdInvites/$code').set({
      'householdId': data.householdId,
      'householdName': data.householdName,
      'ownerUid': current.uid,
      'active': true,
      'createdAt': FieldValue.serverTimestamp(),
    });
    if (oldCode.isNotEmpty) {
      await FirebaseFirestore.instance
          .doc('householdInvites/$oldCode')
          .update({'active': false});
    }
    return code;
  }

  Future<void> transferOwnership(String newOwnerUid, AppData data) async {
    final current = user;
    if (current == null || data.householdRole != 'owner') {
      throw StateError('owner_required');
    }
    final meta = await _householdDocument(data.householdId).get();
    final members = List<String>.from(meta.data()?['memberUids'] ?? const []);
    if (!members.contains(newOwnerUid) || newOwnerUid == current.uid) {
      throw StateError('invalid_new_owner');
    }
    await _householdDocument(data.householdId).update({'ownerUid': newOwnerUid});
    data.householdRole = 'member';
    await _membershipDocument(current.uid).update({'role': 'member'});
    await Store.save(data);
  }

  Future<HouseholdInfo> householdInfo(AppData data) async {
    if (data.householdId.isEmpty) throw StateError('no_household');
    final snapshot = await _householdDocument(data.householdId).get();
    final value = snapshot.data() ?? const <String, dynamic>{};
    final accounts = <Map<String, String>>[];
    final rawAccounts = value['accounts'];
    if (rawAccounts is Map) {
      for (final entry in rawAccounts.entries) {
        final account = entry.value is Map
            ? Map<String, dynamic>.from(entry.value as Map)
            : const <String, dynamic>{};
        accounts.add({
          'uid': '${entry.key}',
          'name': '${account['name'] ?? ''}',
          'email': '${account['email'] ?? ''}',
        });
      }
    }
    return HouseholdInfo(
      id: data.householdId,
      name: '${value['name'] ?? data.householdName}',
      role: data.householdRole,
      inviteCode: data.householdRole == 'owner'
          ? '${value['inviteCode'] ?? ''}'
          : '',
      accounts: accounts,
    );
  }

  Future<void> leaveHousehold(
    AppData data, {
    required Future<void> Function() onRemoteApplied,
  }) async {
    final current = user;
    if (current == null || data.householdId.isEmpty) return;
    final meta = await _householdDocument(data.householdId).get();
    final memberUids = List<String>.from(meta.data()?['memberUids'] ?? const []);
    if (data.householdRole == 'owner' && memberUids.length > 1) {
      throw StateError('transfer_owner_first');
    }
    await _personalDocument(current.uid).set({
      'payload': Store.cloudPayload(data),
      'updatedAt': FieldValue.serverTimestamp(),
      'writer': _writer,
    });
    if (data.householdRole == 'owner') {
      final code = '${meta.data()?['inviteCode'] ?? ''}';
      if (code.isNotEmpty) {
        await FirebaseFirestore.instance.doc('householdInvites/$code').delete();
      }
      await _householdStateDocument(data.householdId).delete();
      await _householdDocument(data.householdId).delete();
    } else {
      await _householdDocument(data.householdId).update({
        'memberUids': FieldValue.arrayRemove([current.uid]),
        'accounts.${current.uid}': FieldValue.delete(),
      });
    }
    await _membershipDocument(current.uid).delete();
    data
      ..householdId = ''
      ..householdName = ''
      ..householdRole = ''
      ..linkedMemberId = '';
    await _subscription?.cancel();
    await _listen(data, onRemoteApplied);
    await Store.save(data);
    await onRemoteApplied();
  }

  Member _ensureSelfMember(AppData data, User current) {
    if (data.linkedMemberId.isNotEmpty) {
      final linked = data.members.where(
        (member) => member.id == data.linkedMemberId,
      );
      if (linked.isNotEmpty) return linked.first;
    }
    final existing = data.members.where((member) => member.relation == 'self');
    if (existing.isNotEmpty) return existing.first;
    final member = Member(
      id: 'self-${current.uid}',
      name: data.profile.name.isNotEmpty
          ? data.profile.name
          : (current.displayName ?? 'Aš'),
      relation: 'self',
      birthDate: data.profile.birthDate,
      bloodType: data.profile.bloodType,
      allergies: data.profile.allergies,
      conditions: data.profile.conditions,
      intolerantMedicines: data.profile.medications,
    );
    data.members.add(member);
    return member;
  }

  Member _newAccountMember(AppData data, User current) {
    final id = 'account-${current.uid}';
    final existing = data.members.where((member) => member.id == id);
    if (existing.isNotEmpty) return existing.first;
    final googleName = current.displayName?.trim() ?? '';
    return Member(
      id: id,
      name: googleName.isNotEmpty
          ? googleName
          : (data.profile.name.trim().isNotEmpty
                ? data.profile.name.trim()
                : 'Naujas narys'),
      relation: 'member',
      ageGroup: 'adult',
      birthDate: data.profile.birthDate,
      bloodType: data.profile.bloodType,
      allergies: data.profile.allergies,
      conditions: data.profile.conditions,
      intolerantMedicines: data.profile.medications,
    );
  }

  Future<String> _newInviteCode() async {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    for (var attempt = 0; attempt < 8; attempt++) {
      final code = List.generate(
        8,
        (_) => alphabet[random.nextInt(alphabet.length)],
      ).join();
      final exists = await FirebaseFirestore.instance
          .doc('householdInvites/$code')
          .get();
      if (!exists.exists) return code;
    }
    throw StateError('invite_generation_failed');
  }

  void _mergeRemoteIntoLocal(AppData local, Map<String, dynamic> payload) {
    final remote = AppData(
      meds: [],
      members: [],
      reminders: [],
      profile: UserProfile(),
    );
    Store.applyCloudPayload(remote, payload);
    _mergeAppData(local, remote);
  }

  void _mergePayloadIntoLocal(AppData local, Map<String, dynamic> payload) {
    final personal = AppData(
      meds: [],
      members: [],
      reminders: [],
      profile: UserProfile(),
    );
    Store.applyCloudPayload(personal, payload);
    _mergeAppData(local, personal);
  }

  void _mergeAppData(AppData destination, AppData additions) {
    List<T> merge<T>(List<T> first, List<T> second, String Function(T) id) {
      final items = <String, T>{for (final item in first) id(item): item};
      for (final item in second) {
        items[id(item)] = item;
      }
      return items.values.toList();
    }
    destination
      ..meds = merge(destination.meds, additions.meds, (item) => item.id)
      ..members = merge(
        destination.members,
        additions.members,
        (item) => item.id,
      )
      ..reminders = merge(
        destination.reminders,
        additions.reminders,
        (item) => item.id,
      )
      ..shopping = merge(
        destination.shopping,
        additions.shopping,
        (item) => item.id,
      )
      ..appointments = merge(
        destination.appointments,
        additions.appointments,
        (item) => item.id,
      );
    if (destination.profile.toJson().values.every((value) => '$value'.isEmpty)) {
      destination.profile = additions.profile;
    }
  }

  Future<void> signOut() async {
    _uploadTimer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    await FirebaseAuth.instance.signOut();
    await GoogleSignIn.instance.signOut();
    state = CloudSyncState.signedOut;
    message = '';
  }

  Future<void> deleteAccountAndCloudData(AppData data) async {
    final current = user;
    if (current == null) return;
    if (data.householdId.isNotEmpty) {
      throw StateError('leave_household_first');
    }
    final googleUser = await GoogleSignIn.instance.authenticate();
    final authentication = googleUser.authentication;
    await current.reauthenticateWithCredential(
      GoogleAuthProvider.credential(idToken: authentication.idToken),
    );
    await _personalDocument(current.uid).delete();
    await _membershipDocument(current.uid).delete();
    await current.delete();
    await GoogleSignIn.instance.signOut();
    await _subscription?.cancel();
    _subscription = null;
    state = CloudSyncState.signedOut;
  }

  String readableError(Object error) {
    final value = error.toString().toLowerCase();
    if (value.contains('invalid_invite')) return 'Kvietimo kodas negalioja.';
    if (value.contains('name_required')) return 'Įrašykite namų ūkio pavadinimą.';
    if (value.contains('transfer_owner_first')) {
      return 'Pirmiausia perduokite namų ūkio administravimą kitam nariui.';
    }
    if (value.contains('leave_household_first')) {
      return 'Pirmiausia išeikite iš bendro namų ūkio.';
    }
    if (value.contains('network')) return 'Nėra interneto ryšio.';
    if (value.contains('permission-denied')) {
      return 'Firebase saugos taisyklės neleido pasiekti duomenų.';
    }
    if (value.contains('sign_in_failed') || value.contains('developer_error')) {
      return 'Google prisijungimas dar nesukonfigūruotas šiam programėlės parašui.';
    }
    if (value.contains('google_oauth_not_configured')) {
      return 'Google prisijungimo konfigūracija dar neįjungta Firebase projekte.';
    }
    return 'Veiksmo atlikti nepavyko. Bandykite dar kartą.';
  }
}
