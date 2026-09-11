import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/models/models.dart';

void main() {
  test('unconfirmed medicine reminder repetition is enabled by default', () {
    final data = AppData(
      meds: [],
      members: [],
      reminders: [],
      profile: UserProfile(),
    );
    expect(data.repeatUnconfirmedMedicationReminders, isTrue);
    expect(data.loudMedicationReminders, isFalse);
  });

  test('member and reminder survive JSON round trip', () {
    final member = Member(
      id: 'm1',
      name: 'Aronas',
      relation: 'child',
      allergies: 'beržas',
    );
    final restoredMember = Member.fromJson(member.toJson());
    expect(restoredMember.name, 'Aronas');
    expect(restoredMember.relation, 'child');
    final reminder = Reminder(
      id: 'r1',
      title: 'Vitaminas',
      memberId: member.id,
      time: '08:30',
      dose: '1',
      weekdays: [1, 3, 5],
      takenDates: ['2026-09-07'],
    );
    final restoredReminder = Reminder.fromJson(reminder.toJson());
    expect(restoredReminder.weekdays, [1, 3, 5]);
    expect(restoredReminder.memberId, 'm1');
    expect(restoredReminder.takenDates, ['2026-09-07']);
  });

  test('profile survives JSON round trip', () {
    final profile = UserProfile(
      name: 'Andrius',
      bloodType: 'A+',
      emergencyPhone: '+370',
    );
    final restored = UserProfile.fromJson(profile.toJson());
    expect(restored.name, 'Andrius');
    expect(restored.bloodType, 'A+');
    expect(restored.emergencyPhone, '+370');
  });

  test('medicine threshold and appointment survive JSON round trip', () {
    final medicine = Med(
      id: 'm1', name: 'Vaistas', substance: '', strength: '', purpose: '',
      category: '', expiry: '2028-01', stock: 20, lowStockThreshold: 7,
      stockUnit: 'ml',
      prescription: true,
      prescriptionValidUntil: '2026-10-01',
      treatmentUntil: '2026-10-15',
    );
    final restoredMedicine = Med.fromJson(medicine.toJson());
    expect(restoredMedicine.lowStockThreshold, 7);
    expect(restoredMedicine.stockUnit, 'ml');
    expect(restoredMedicine.prescriptionValidUntil, '2026-10-01');
    expect(restoredMedicine.treatmentUntil, '2026-10-15');
    final appointment = HealthAppointment(
      id: 'a1', title: 'Kardiologas', date: '2026-10-10', time: '09:30',
      doctor: 'Gydytojas', remindBeforeMinutes: 2880,
    );
    final restored = HealthAppointment.fromJson(appointment.toJson());
    expect(restored.title, 'Kardiologas');
    expect(restored.remindBeforeMinutes, 2880);
  });

  test('medicine can be assigned to several family members', () {
    final medicine = Med(
      id: 'm2',
      name: 'Ibuprofenas',
      substance: 'ibuprofenas',
      strength: '400 mg',
      purpose: '',
      category: '',
      expiry: '2028-01',
      stock: 12,
      memberIds: ['adult', 'child'],
    );
    final restored = Med.fromJson(medicine.toJson());
    expect(restored.memberIds, ['adult', 'child']);
  });

  test('shopping item keeps quantity and purchased state', () {
    final item = ShoppingItem(
      id: 's1',
      medId: 'm2',
      name: 'Ibuprofenas 400 mg',
      quantity: 3,
      prescription: true,
      purchased: true,
    );
    final restored = ShoppingItem.fromJson(item.toJson());
    expect(restored.quantity, 3);
    expect(restored.purchased, isTrue);
    expect(restored.medId, 'm2');
  });
}
