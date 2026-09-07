class Med {
  final String id,
      name,
      substance,
      strength,
      purpose,
      category,
      expiry,
      leaflet;
  double stock;
  final bool prescription;
  Med({
    required this.id,
    required this.name,
    required this.substance,
    required this.strength,
    required this.purpose,
    required this.category,
    required this.expiry,
    required this.stock,
    this.prescription = false,
    this.leaflet = '',
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'substance': substance,
    'strength': strength,
    'purpose': purpose,
    'category': category,
    'expiry': expiry,
    'stock': stock,
    'prescription': prescription,
    'leaflet': leaflet,
  };
  factory Med.fromJson(Map<String, dynamic> j) => Med(
    id: '${j['id']}',
    name: '${j['name']}',
    substance: '${j['substance'] ?? ''}',
    strength: '${j['strength'] ?? ''}',
    purpose: '${j['purpose'] ?? ''}',
    category: '${j['category'] ?? 'Kita'}',
    expiry: '${j['expiry'] ?? ''}',
    stock: (j['stock'] as num?)?.toDouble() ?? 0,
    prescription: j['prescription'] == true,
    leaflet: '${j['leaflet'] ?? ''}',
  );
}

class Member {
  final String id;
  String name, relation, birthDate, allergies, conditions, notes;
  Member({
    required this.id,
    required this.name,
    required this.relation,
    this.birthDate = '',
    this.allergies = '',
    this.conditions = '',
    this.notes = '',
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'relation': relation,
    'birthDate': birthDate,
    'allergies': allergies,
    'conditions': conditions,
    'notes': notes,
  };
  factory Member.fromJson(Map<String, dynamic> j) => Member(
    id: '${j['id']}',
    name: '${j['name']}',
    relation: '${j['relation']}',
    birthDate: '${j['birthDate'] ?? ''}',
    allergies: '${j['allergies'] ?? ''}',
    conditions: '${j['conditions'] ?? ''}',
    notes: '${j['notes'] ?? ''}',
  );
}

class Reminder {
  final String id;
  String title,
      medId,
      memberId,
      time,
      dose,
      doseUnit,
      instructions,
      startDate,
      endDate;
  List<int> weekdays;
  List<String> takenDates, skippedDates;
  Map<String, String> takenTimes;
  double quantityPerDose;
  bool enabled;
  Reminder({
    required this.id,
    required this.title,
    this.medId = '',
    this.memberId = '',
    required this.time,
    this.dose = '',
    this.doseUnit = 'vnt.',
    this.quantityPerDose = 1,
    this.instructions = '',
    this.startDate = '',
    this.endDate = '',
    List<int>? weekdays,
    List<String>? takenDates,
    List<String>? skippedDates,
    Map<String, String>? takenTimes,
    this.enabled = true,
  }) : weekdays = weekdays ?? [1, 2, 3, 4, 5, 6, 7],
       takenDates = takenDates ?? [],
       skippedDates = skippedDates ?? [],
       takenTimes = takenTimes ?? {};
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'medId': medId,
    'memberId': memberId,
    'time': time,
    'dose': dose,
    'doseUnit': doseUnit,
    'quantityPerDose': quantityPerDose,
    'instructions': instructions,
    'startDate': startDate,
    'endDate': endDate,
    'weekdays': weekdays,
    'takenDates': takenDates,
    'skippedDates': skippedDates,
    'takenTimes': takenTimes,
    'enabled': enabled,
  };
  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
    id: '${j['id']}',
    title: '${j['title']}',
    medId: '${j['medId'] ?? ''}',
    memberId: '${j['memberId'] ?? ''}',
    time: '${j['time'] ?? '08:00'}',
    dose: '${j['dose'] ?? ''}',
    doseUnit: '${j['doseUnit'] ?? 'vnt.'}',
    quantityPerDose: (j['quantityPerDose'] as num?)?.toDouble() ?? 1,
    instructions: '${j['instructions'] ?? ''}',
    startDate: '${j['startDate'] ?? ''}',
    endDate: '${j['endDate'] ?? ''}',
    weekdays: (j['weekdays'] as List?)?.map((x) => (x as num).toInt()).toList(),
    takenDates: (j['takenDates'] as List?)?.map((x) => '$x').toList(),
    skippedDates: (j['skippedDates'] as List?)?.map((x) => '$x').toList(),
    takenTimes: (j['takenTimes'] as Map?)?.map(
      (key, value) => MapEntry('$key', '$value'),
    ),
    enabled: j['enabled'] != false,
  );
}

class UserProfile {
  String name,
      birthDate,
      phone,
      email,
      bloodType,
      allergies,
      conditions,
      medications,
      emergencyName,
      emergencyPhone,
      notes;
  UserProfile({
    this.name = '',
    this.birthDate = '',
    this.phone = '',
    this.email = '',
    this.bloodType = '',
    this.allergies = '',
    this.conditions = '',
    this.medications = '',
    this.emergencyName = '',
    this.emergencyPhone = '',
    this.notes = '',
  });
  Map<String, dynamic> toJson() => {
    'name': name,
    'birthDate': birthDate,
    'phone': phone,
    'email': email,
    'bloodType': bloodType,
    'allergies': allergies,
    'conditions': conditions,
    'medications': medications,
    'emergencyName': emergencyName,
    'emergencyPhone': emergencyPhone,
    'notes': notes,
  };
  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
    name: '${j['name'] ?? ''}',
    birthDate: '${j['birthDate'] ?? ''}',
    phone: '${j['phone'] ?? ''}',
    email: '${j['email'] ?? ''}',
    bloodType: '${j['bloodType'] ?? ''}',
    allergies: '${j['allergies'] ?? ''}',
    conditions: '${j['conditions'] ?? ''}',
    medications: '${j['medications'] ?? ''}',
    emergencyName: '${j['emergencyName'] ?? ''}',
    emergencyPhone: '${j['emergencyPhone'] ?? ''}',
    notes: '${j['notes'] ?? ''}',
  );
}

class AppData {
  List<Med> meds;
  List<Member> members;
  List<Reminder> reminders;
  UserProfile profile;
  String language;
  bool onboarded;
  AppData({
    required this.meds,
    required this.members,
    required this.reminders,
    required this.profile,
    this.language = 'system',
    this.onboarded = false,
  });
}
