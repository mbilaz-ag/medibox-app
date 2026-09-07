import 'leaflet_draft.dart';

class MedicineStockBatch {
  final String id;
  double quantity;
  String expiry, batchNumber, storageLocation;
  MedicineStockBatch({
    required this.id,
    required this.quantity,
    this.expiry = '',
    this.batchNumber = '',
    this.storageLocation = '',
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'quantity': quantity,
    'expiry': expiry,
    'batchNumber': batchNumber,
    'storageLocation': storageLocation,
  };
  factory MedicineStockBatch.fromJson(Map<String, dynamic> json) =>
      MedicineStockBatch(
        id: '${json['id']}',
        quantity: (json['quantity'] as num?)?.toDouble() ?? 0,
        expiry: '${json['expiry'] ?? ''}',
        batchNumber: '${json['batchNumber'] ?? ''}',
        storageLocation: '${json['storageLocation'] ?? ''}',
      );
}

class Med {
  final String id;
  String name,
      substance,
      strength,
      purpose,
      category,
      expiry,
      prescriptionValidUntil,
      treatmentUntil,
      leaflet,
      imagePath,
      manufacturer,
      dosageForm,
      batchNumber,
      barcode,
      storageLocation,
      notes,
      packageSize,
      dosage,
      warnings,
      sideEffects,
      interactions,
      atcCode,
      registrationNumber,
      supplyStatus;
  double stock;
  double lowStockThreshold;
  bool prescription;
  bool registryVerified;
  List<String> memberIds;
  List<MedicineStockBatch> batches;
  LeafletRecord? leafletRecord;
  Med({
    required this.id,
    required this.name,
    required this.substance,
    required this.strength,
    required this.purpose,
    required this.category,
    required this.expiry,
    this.prescriptionValidUntil = '',
    this.treatmentUntil = '',
    required this.stock,
    this.lowStockThreshold = 10,
    this.prescription = false,
    this.leaflet = '',
    this.imagePath = '',
    this.manufacturer = '',
    this.dosageForm = '',
    this.batchNumber = '',
    this.barcode = '',
    this.storageLocation = '',
    this.notes = '',
    this.packageSize = '',
    this.dosage = '',
    this.warnings = '',
    this.sideEffects = '',
    this.interactions = '',
    this.atcCode = '',
    this.registrationNumber = '',
    this.supplyStatus = '',
    this.registryVerified = false,
    this.leafletRecord,
    List<String>? memberIds,
    List<MedicineStockBatch>? batches,
  }) : memberIds = memberIds ?? [],
       batches = batches ?? [];
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'substance': substance,
    'strength': strength,
    'purpose': purpose,
    'category': category,
    'expiry': expiry,
    'prescriptionValidUntil': prescriptionValidUntil,
    'treatmentUntil': treatmentUntil,
    'stock': stock,
    'lowStockThreshold': lowStockThreshold,
    'prescription': prescription,
    'leaflet': leaflet,
    'imagePath': imagePath,
    'manufacturer': manufacturer,
    'dosageForm': dosageForm,
    'batchNumber': batchNumber,
    'barcode': barcode,
    'storageLocation': storageLocation,
    'notes': notes,
    'packageSize': packageSize,
    'dosage': dosage,
    'warnings': warnings,
    'sideEffects': sideEffects,
    'interactions': interactions,
    'memberIds': memberIds,
    'atcCode': atcCode,
    'registrationNumber': registrationNumber,
    'supplyStatus': supplyStatus,
    'registryVerified': registryVerified,
    'leafletRecord': leafletRecord?.toJson(),
    'batches': batches.map((batch) => batch.toJson()).toList(),
  };
  factory Med.fromJson(Map<String, dynamic> j) => Med(
    id: '${j['id']}',
    name: '${j['name']}',
    substance: '${j['substance'] ?? ''}',
    strength: '${j['strength'] ?? ''}',
    purpose: '${j['purpose'] ?? ''}',
    category: '${j['category'] ?? 'Kita'}',
    expiry: '${j['expiry'] ?? ''}',
    prescriptionValidUntil: '${j['prescriptionValidUntil'] ?? ''}',
    treatmentUntil: '${j['treatmentUntil'] ?? ''}',
    stock: (j['stock'] as num?)?.toDouble() ?? 0,
    lowStockThreshold: (j['lowStockThreshold'] as num?)?.toDouble() ?? 10,
    prescription: j['prescription'] == true,
    leaflet: '${j['leaflet'] ?? ''}',
    imagePath: '${j['imagePath'] ?? ''}',
    manufacturer: '${j['manufacturer'] ?? ''}',
    dosageForm: '${j['dosageForm'] ?? ''}',
    batchNumber: '${j['batchNumber'] ?? ''}',
    barcode: '${j['barcode'] ?? ''}',
    storageLocation: '${j['storageLocation'] ?? ''}',
    notes: '${j['notes'] ?? ''}',
    packageSize: '${j['packageSize'] ?? ''}',
    dosage: '${j['dosage'] ?? ''}',
    warnings: '${j['warnings'] ?? ''}',
    sideEffects: '${j['sideEffects'] ?? ''}',
    interactions: '${j['interactions'] ?? ''}',
    memberIds: (j['memberIds'] as List?)?.map((x) => '$x').toList(),
    atcCode: '${j['atcCode'] ?? ''}',
    registrationNumber: '${j['registrationNumber'] ?? ''}',
    supplyStatus: '${j['supplyStatus'] ?? ''}',
    registryVerified: j['registryVerified'] == true,
    leafletRecord: LeafletRecord.tryRead(j['leafletRecord']),
    batches: (j['batches'] as List?)
        ?.map((item) => MedicineStockBatch.fromJson(
            Map<String, dynamic>.from(item)))
        .toList(),
  );
}

class Member {
  final String id;
  String name,
      relation,
      gender,
      ageGroup,
      birthDate,
      imagePath,
      bloodType,
      height,
      weight,
      allergies,
      conditions,
      intolerantMedicines,
      healthcareFacility,
      familyDoctor,
      facilityPhone,
      facilityAddress,
      notes;
  Member({
    required this.id,
    required this.name,
    required this.relation,
    this.gender = 'unspecified',
    this.ageGroup = 'adult',
    this.birthDate = '',
    this.imagePath = '',
    this.bloodType = '',
    this.height = '',
    this.weight = '',
    this.allergies = '',
    this.conditions = '',
    this.intolerantMedicines = '',
    this.healthcareFacility = '',
    this.familyDoctor = '',
    this.facilityPhone = '',
    this.facilityAddress = '',
    this.notes = '',
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'relation': relation,
    'gender': gender,
    'ageGroup': ageGroup,
    'birthDate': birthDate,
    'imagePath': imagePath,
    'bloodType': bloodType,
    'height': height,
    'weight': weight,
    'allergies': allergies,
    'conditions': conditions,
    'intolerantMedicines': intolerantMedicines,
    'healthcareFacility': healthcareFacility,
    'familyDoctor': familyDoctor,
    'facilityPhone': facilityPhone,
    'facilityAddress': facilityAddress,
    'notes': notes,
  };
  factory Member.fromJson(Map<String, dynamic> j) => Member(
    id: '${j['id']}',
    name: '${j['name']}',
    relation: '${j['relation']}',
    gender: '${j['gender'] ?? _legacyGender('${j['relation']}')}',
    ageGroup: '${j['ageGroup'] ?? ('${j['relation']}' == 'child' ? 'child' : 'adult')}',
    birthDate: '${j['birthDate'] ?? ''}',
    imagePath: '${j['imagePath'] ?? ''}',
    bloodType: '${j['bloodType'] ?? ''}',
    height: '${j['height'] ?? ''}',
    weight: '${j['weight'] ?? ''}',
    allergies: '${j['allergies'] ?? ''}',
    conditions: '${j['conditions'] ?? ''}',
    intolerantMedicines: '${j['intolerantMedicines'] ?? ''}',
    healthcareFacility: '${j['healthcareFacility'] ?? ''}',
    familyDoctor: '${j['familyDoctor'] ?? ''}',
    facilityPhone: '${j['facilityPhone'] ?? ''}',
    facilityAddress: '${j['facilityAddress'] ?? ''}',
    notes: '${j['notes'] ?? ''}',
  );
}

String _legacyGender(String relation) => switch (relation) {
  'mother' || 'sister' => 'female',
  'father' || 'brother' => 'male',
  _ => 'unspecified',
};

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

class ShoppingItem {
  final String id;
  String medId, name;
  double quantity;
  bool prescription, purchased;
  ShoppingItem({
    required this.id,
    this.medId = '',
    required this.name,
    this.quantity = 1,
    this.prescription = false,
    this.purchased = false,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'medId': medId,
    'name': name,
    'quantity': quantity,
    'prescription': prescription,
    'purchased': purchased,
  };
  factory ShoppingItem.fromJson(Map<String, dynamic> json) => ShoppingItem(
    id: '${json['id']}',
    medId: '${json['medId'] ?? ''}',
    name: '${json['name'] ?? ''}',
    quantity: (json['quantity'] as num?)?.toDouble() ?? 1,
    prescription: json['prescription'] == true,
    purchased: json['purchased'] == true,
  );
}

class HealthAppointment {
  final String id;
  String memberId,
      title,
      doctor,
      facility,
      address,
      date,
      time,
      reason,
      notes;
  int remindBeforeMinutes;
  bool completed;
  HealthAppointment({
    required this.id,
    this.memberId = '',
    required this.title,
    this.doctor = '',
    this.facility = '',
    this.address = '',
    required this.date,
    required this.time,
    this.reason = '',
    this.notes = '',
    this.remindBeforeMinutes = 1440,
    this.completed = false,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'memberId': memberId,
    'title': title,
    'doctor': doctor,
    'facility': facility,
    'address': address,
    'date': date,
    'time': time,
    'reason': reason,
    'notes': notes,
    'remindBeforeMinutes': remindBeforeMinutes,
    'completed': completed,
  };
  factory HealthAppointment.fromJson(Map<String, dynamic> json) =>
      HealthAppointment(
        id: '${json['id']}',
        memberId: '${json['memberId'] ?? ''}',
        title: '${json['title'] ?? ''}',
        doctor: '${json['doctor'] ?? ''}',
        facility: '${json['facility'] ?? ''}',
        address: '${json['address'] ?? ''}',
        date: '${json['date'] ?? ''}',
        time: '${json['time'] ?? ''}',
        reason: '${json['reason'] ?? ''}',
        notes: '${json['notes'] ?? ''}',
        remindBeforeMinutes:
            (json['remindBeforeMinutes'] as num?)?.toInt() ?? 1440,
        completed: json['completed'] == true,
      );
}

class AppData {
  List<Med> meds;
  List<Member> members;
  List<Reminder> reminders;
  List<ShoppingItem> shopping;
  List<HealthAppointment> appointments;
  UserProfile profile;
  String language;
  bool onboarded;
  bool privacyLock;
  AppData({
    required this.meds,
    required this.members,
    required this.reminders,
    List<ShoppingItem>? shopping,
    List<HealthAppointment>? appointments,
    required this.profile,
    this.language = 'system',
    this.onboarded = false,
    this.privacyLock = false,
  }) : shopping = shopping ?? [],
       appointments = appointments ?? [];
}
