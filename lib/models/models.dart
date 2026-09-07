class Med {
  final String id,
      name,
      substance,
      strength,
      purpose,
      category,
      expiry,
      leaflet;
  int stock;
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
    id: j['id'],
    name: j['name'],
    substance: j['substance'],
    strength: j['strength'],
    purpose: j['purpose'],
    category: j['category'],
    expiry: j['expiry'],
    stock: j['stock'],
    prescription: j['prescription'] ?? false,
    leaflet: j['leaflet'] ?? '',
  );
}

class Dose {
  final String id, medId, time;
  bool taken;
  Dose(this.id, this.medId, this.time, {this.taken = false});
  Map<String, dynamic> toJson() => {
    'id': id,
    'medId': medId,
    'time': time,
    'taken': taken,
  };
  factory Dose.fromJson(Map<String, dynamic> j) =>
      Dose(j['id'], j['medId'], j['time'], taken: j['taken'] ?? false);
}
