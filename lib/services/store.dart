import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

class Store {
  static const _meds = 'medibox_meds_v2',
      _members = 'medibox_members_v1',
      _reminders = 'medibox_reminders_v1',
      _shopping = 'medibox_shopping_v1',
      _appointments = 'medibox_appointments_v1',
      _profile = 'medibox_profile_v1',
      _language = 'medibox_language_v1',
      _onboarded = 'medibox_onboarded_v1';
  static const _privacyLock = 'medibox_privacy_lock_v1';
  static const _aiConsent = 'medibox_ai_consent_v1';
  static const _aiConsentChoice = 'medibox_ai_consent_choice_v1';
  static const _cameraPermissionAsked = 'medibox_camera_permission_asked_v1';
  static const _permissionsChoice = 'medibox_permissions_choice_v2';
  static const _cameraConsent = 'medibox_camera_consent_v2';
  static const _medicationNotifications =
      'medibox_medication_notifications_consent_v2';
  static const _repeatUnconfirmedMedicationReminders =
      'medibox_repeat_unconfirmed_medication_reminders_v1';
  static const _appointmentNotifications =
      'medibox_appointment_notifications_consent_v2';
  static const _householdId = 'medibox_household_id_v1';
  static const _householdName = 'medibox_household_name_v1';
  static const _householdRole = 'medibox_household_role_v1';
  static const _linkedMemberId = 'medibox_linked_member_id_v1';
  static Future<AppData> load() async {
    final p = await SharedPreferences.getInstance();
    List<T> list<T>(String key, T Function(Map<String, dynamic>) parse) {
      try {
        final raw = p.getString(key);
        if (raw == null) return [];
        return (jsonDecode(raw) as List)
            .map((x) => parse(Map<String, dynamic>.from(x)))
            .toList();
      } catch (_) {
        return [];
      }
    }

    final meds = list(_meds, Med.fromJson),
        members = list(_members, Member.fromJson),
        reminders = list(_reminders, Reminder.fromJson);
    final shopping = list(_shopping, ShoppingItem.fromJson);
    final appointments = list(_appointments, HealthAppointment.fromJson);
    var profile = UserProfile();
    try {
      final raw = p.getString(_profile);
      if (raw != null)
        profile = UserProfile.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw)),
        );
    } catch (_) {}
    return AppData(
      meds: meds.isEmpty
          ? seed.map((x) => Med.fromJson(x.toJson())).toList()
          : meds,
      members: members,
      reminders: reminders,
      shopping: shopping,
      appointments: appointments,
      profile: profile,
      language: p.getString(_language) ?? 'system',
      onboarded: p.getBool(_onboarded) ?? false,
      privacyLock: p.getBool(_privacyLock) ?? false,
      aiConsentGranted: p.getBool(_aiConsent) ?? false,
      aiConsentChoiceMade: p.getBool(_aiConsentChoice) ?? false,
      permissionsChoiceMade: p.getBool(_permissionsChoice) ?? false,
      cameraConsentGranted: p.getBool(_cameraConsent) ?? false,
      medicationNotificationsGranted:
          p.getBool(_medicationNotifications) ?? false,
      repeatUnconfirmedMedicationReminders:
          p.getBool(_repeatUnconfirmedMedicationReminders) ?? true,
      appointmentNotificationsGranted:
          p.getBool(_appointmentNotifications) ?? false,
      cameraPermissionAsked: p.getBool(_cameraPermissionAsked) ?? false,
      householdId: p.getString(_householdId) ?? '',
      householdName: p.getString(_householdName) ?? '',
      householdRole: p.getString(_householdRole) ?? '',
      linkedMemberId: p.getString(_linkedMemberId) ?? '',
    );
  }

  static Future<void> save(AppData d) async {
    final p = await SharedPreferences.getInstance();
    await Future.wait([
      p.setString(_meds, jsonEncode(d.meds.map((x) => x.toJson()).toList())),
      p.setString(
        _members,
        jsonEncode(d.members.map((x) => x.toJson()).toList()),
      ),
      p.setString(
        _reminders,
        jsonEncode(d.reminders.map((x) => x.toJson()).toList()),
      ),
      p.setString(
        _shopping,
        jsonEncode(d.shopping.map((x) => x.toJson()).toList()),
      ),
      p.setString(
        _appointments,
        jsonEncode(d.appointments.map((x) => x.toJson()).toList()),
      ),
      p.setString(_profile, jsonEncode(d.profile.toJson())),
      p.setString(_language, d.language),
      p.setBool(_onboarded, d.onboarded),
      p.setBool(_privacyLock, d.privacyLock),
      p.setBool(_aiConsent, d.aiConsentGranted),
      p.setBool(_aiConsentChoice, d.aiConsentChoiceMade),
      p.setBool(_permissionsChoice, d.permissionsChoiceMade),
      p.setBool(_cameraConsent, d.cameraConsentGranted),
      p.setBool(
        _medicationNotifications,
        d.medicationNotificationsGranted,
      ),
      p.setBool(
        _repeatUnconfirmedMedicationReminders,
        d.repeatUnconfirmedMedicationReminders,
      ),
      p.setBool(
        _appointmentNotifications,
        d.appointmentNotificationsGranted,
      ),
      p.setBool(_cameraPermissionAsked, d.cameraPermissionAsked),
      p.setString(_householdId, d.householdId),
      p.setString(_householdName, d.householdName),
      p.setString(_householdRole, d.householdRole),
      p.setString(_linkedMemberId, d.linkedMemberId),
    ]);
  }

  /// Only user-created content is synchronized. Device permissions, app lock
  /// and language remain local because they can differ between phones.
  static Map<String, dynamic> cloudPayload(
    AppData data, {
    bool includeProfile = true,
  }) => {
    'schemaVersion': 1,
    'meds': data.meds.map((item) {
      final json = item.toJson();
      json['imagePath'] = '';
      json['cloudImagePath'] = '';
      json['cloudImageVersion'] = '';
      return json;
    }).toList(),
    'members': data.members.map((item) {
      final json = item.toJson();
      json['imagePath'] = '';
      json['cloudImagePath'] = '';
      json['cloudImageVersion'] = '';
      return json;
    }).toList(),
    'reminders': data.reminders.map((item) => item.toJson()).toList(),
    'shopping': data.shopping.map((item) => item.toJson()).toList(),
    'appointments': data.appointments.map((item) => item.toJson()).toList(),
    if (includeProfile) 'profile': data.profile.toJson(),
  };

  static void applyCloudPayload(
    AppData data,
    Map<String, dynamic> payload, {
    bool applyProfile = true,
  }) {
    final medicineImages = {
      for (final item in data.meds) item.id: item.imagePath,
    };
    final memberImages = {
      for (final item in data.members) item.id: item.imagePath,
    };
    List<T> readList<T>(
      String key,
      T Function(Map<String, dynamic>) parse,
    ) => (payload[key] as List? ?? const [])
        .whereType<Map>()
        .map((item) => parse(Map<String, dynamic>.from(item)))
        .toList();

    final medicines = readList('meds', Med.fromJson);
    for (final item in medicines) {
      item.imagePath = medicineImages[item.id] ?? '';
    }
    final members = readList('members', Member.fromJson);
    for (final item in members) {
      item.imagePath = memberImages[item.id] ?? '';
    }

    data
      ..meds = medicines
      ..members = members
      ..reminders = readList('reminders', Reminder.fromJson)
      ..shopping = readList('shopping', ShoppingItem.fromJson)
      ..appointments = readList('appointments', HealthAppointment.fromJson);
    final profile = payload['profile'];
    if (applyProfile && profile is Map) {
      data.profile = UserProfile.fromJson(Map<String, dynamic>.from(profile));
    }
  }

  static bool containsPersonalContent(AppData data) {
    if (data.members.isNotEmpty ||
        data.reminders.isNotEmpty ||
        data.shopping.isNotEmpty ||
        data.appointments.isNotEmpty) {
      return true;
    }
    final seedIds = seed.map((item) => item.id).toSet();
    return data.meds.any((item) => !seedIds.contains(item.id));
  }

  static final seed = <Med>[
    Med(
      id: 'euth',
      name: 'Euthyrox',
      substance: 'levotiroksinas',
      strength: '50 µg',
      purpose: 'Skydliaukės hormonų pakaitinei terapijai.',
      category: 'Kita',
      expiry: '2028-01',
      stock: 73,
      prescription: true,
    ),
    Med(
      id: 'ibu',
      name: 'Ibumetin',
      substance: 'ibuprofenas',
      strength: '400 mg',
      purpose: 'Skausmui ir karščiavimui mažinti.',
      category: 'Skausmas',
      expiry: '2028-04',
      stock: 6,
    ),
    Med(
      id: 'lor',
      name: 'Loratadine',
      substance: 'loratadinas',
      strength: '10 mg',
      purpose: 'Alergijos simptomams lengvinti.',
      category: 'Alergija',
      expiry: '2027-09',
      stock: 12,
    ),
    Med(
      id: 'esp',
      name: 'Espumisan',
      substance: 'simetikonas',
      strength: '40 mg',
      purpose: 'Simptomams, susijusiems su dujų kaupimusi virškinimo trakte.',
      category: 'Virškinimas',
      expiry: '2027-11',
      stock: 14,
    ),
  ];
}
