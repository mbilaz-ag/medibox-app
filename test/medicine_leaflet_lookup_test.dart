import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medibox/services/medicine_leaflet_lookup.dart';
import 'package:medibox/services/vvkt_service.dart';

void main() {
  const medicine = VvktMedicine(
    name: 'Espumisan', substance: 'Simetikonas', strength: '40 mg',
    dosageForm: 'minkštosios kapsulės', administrationRoute: 'Vartoti per burną',
    packageDescription: 'N25', prescriptionStatus: 'Nereceptinis',
    registrationNumber: 'LT/1/00/0000/001', registrant: 'Berlin-Chemie',
    supplyStatus: 'Tiekiama', registrationStatus: 'Registruotas', atcCode: 'A03AX13',
  );

  test('selects an exact medicine and extracts leaflet sections', () async {
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/paieska/')) {
        return http.Response.bytes(utf8.encode('''<div class="card__title"><a href="/espumisan-240mg.html">Espumisan 240 mg minkštosios kapsulės</a></div>
          <div class="card__title"><a href="/espumisan-40mg.html">Espumisan 40 mg minkštosios kapsulės N25</a></div>'''), 200);
      }
      return http.Response('''<main id="modal-info-sheet-content">
        <p>Espumisan 40 mg minkštosios kapsulės</p>
        <article data-nodeindex="1"><p>Kas yra vaistas ir kam vartojamas. ${List.filled(90, 'a').join()}</p></article>
        <article data-nodeindex="2"><p>Įspėjimai. ${List.filled(90, 'b').join()}</p></article>
        <article data-nodeindex="3"><p>Kaip vartoti. ${List.filled(90, 'c').join()}</p></article>
      </main>'''), 200);
    });
    final result = await MedicineLeafletLookup(client).find(medicine);
    expect(result.url, 'https://vaistai.lt/espumisan-40mg.html');
    expect(result.sections['3'], contains('Kaip vartoti'));
  });

  test('does not confuse 40 mg with 240 mg', () async {
    final client = MockClient((_) async => http.Response.bytes(utf8.encode(
      '<div class="card__title"><a href="/wrong">Espumisan 240 mg minkštosios kapsulės</a></div>'), 200));
    await expectLater(MedicineLeafletLookup(client).find(medicine), throwsFormatException);
  });
}
