import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/models/models.dart';
import 'package:medibox/services/store.dart';

void main() {
  AppData data() => AppData(
    meds: [
      Med(
        id: 'm1',
        name: 'Vaistas',
        substance: 'medžiaga',
        strength: '10 mg',
        purpose: 'paskirtis',
        category: 'Kita',
        expiry: '2028-01',
        stock: 4,
        imagePath: '/private/phone/photo.jpg',
        cloudImagePath: 'users/u/images/medicines/m1.jpg',
        cloudImageVersion: '123-456',
        memberIds: ['self'],
      ),
    ],
    members: [Member(id: 'self', name: 'Andrius', relation: 'self')],
    reminders: [Reminder(id: 'r1', title: 'Vaistas', time: '08:00')],
    shopping: [ShoppingItem(id: 's1', name: 'Vaistas')],
    appointments: [
      HealthAppointment(
        id: 'a1',
        title: 'Gydytojas',
        date: '2026-10-10',
        time: '10:00',
      ),
    ],
    profile: UserProfile(name: 'Andrius'),
    language: 'lt',
    privacyLock: true,
    aiConsentGranted: true,
    cameraConsentGranted: true,
    householdId: 'house-1',
  );

  test('cloud payload contains user content but not local-only settings', () {
    final payload = Store.cloudPayload(data());

    expect(payload['schemaVersion'], 1);
    expect((payload['meds'] as List).single['imagePath'], '');
    expect(
      (payload['meds'] as List).single['cloudImagePath'],
      '',
    );
    expect(payload.containsKey('privacyLock'), isFalse);
    expect(payload.containsKey('aiConsentGranted'), isFalse);
    expect(payload.containsKey('householdId'), isFalse);
  });

  test('applying cloud payload preserves this device settings', () {
    final original = data();
    final target = AppData(
      meds: [],
      members: [],
      reminders: [],
      profile: UserProfile(),
      language: 'en',
      privacyLock: false,
      aiConsentGranted: false,
      householdId: 'local-house',
    );

    Store.applyCloudPayload(target, Store.cloudPayload(original));

    expect(target.meds.single.name, 'Vaistas');
    expect(target.meds.single.imagePath, '');
    expect(target.members.single.name, 'Andrius');
    expect(target.reminders.single.id, 'r1');
    expect(target.shopping.single.id, 's1');
    expect(target.appointments.single.id, 'a1');
    expect(target.profile.name, 'Andrius');
    expect(target.language, 'en');
    expect(target.privacyLock, isFalse);
    expect(target.aiConsentGranted, isFalse);
    expect(target.householdId, 'local-house');
  });

  test('cloud refresh keeps photos local to this device', () {
    final source = data();
    final target = data();
    target.meds.single.imagePath = '/this-device/medicine.jpg';
    target.members.single.imagePath = '/this-device/member.jpg';

    Store.applyCloudPayload(target, Store.cloudPayload(source));

    expect(target.meds.single.imagePath, '/this-device/medicine.jpg');
    expect(target.members.single.imagePath, '/this-device/member.jpg');
  });

  test('personal content detection ignores untouched demo cabinet', () {
    final untouched = AppData(
      meds: Store.seed.map((item) => Med.fromJson(item.toJson())).toList(),
      members: [],
      reminders: [],
      profile: UserProfile(),
    );
    expect(Store.containsPersonalContent(untouched), isFalse);
    untouched.members.add(Member(id: 'self', name: 'Aš', relation: 'self'));
    expect(Store.containsPersonalContent(untouched), isTrue);
  });
}
