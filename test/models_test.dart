import 'package:flutter_test/flutter_test.dart';
import 'package:medibox/models/models.dart';

void main() {
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
    );
    final restoredReminder = Reminder.fromJson(reminder.toJson());
    expect(restoredReminder.weekdays, [1, 3, 5]);
    expect(restoredReminder.memberId, 'm1');
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
}
