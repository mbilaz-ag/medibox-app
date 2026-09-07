import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

class Store {
  static const key = 'medibox_meds_v2';
  static Future<List<Med>> load() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(key);
    if (s == null) return seed.map((x) => Med.fromJson(x.toJson())).toList();
    return (jsonDecode(s) as List).map((x) => Med.fromJson(x)).toList();
  }

  static Future<void> save(List<Med> m) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(m.map((x) => x.toJson()).toList()));
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
