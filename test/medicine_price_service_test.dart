import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:medibox/models/models.dart';
import 'package:medibox/services/medicine_price_service.dart';

void main() {
  final medicine = Med(
    id: 'espumisan',
    name: 'Espumisan',
    substance: 'Simetikonas',
    strength: '40 mg',
    purpose: '',
    category: 'Virškinimas',
    expiry: '',
    stock: 10,
    dosageForm: 'minkštosios kapsulės',
    packageSize: 'N25',
  );

  test('finds the exact package and sorts pharmacy prices', () async {
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/paieska/')) {
        return _html('''
          <a class="a link" href="/espumisan-240mg.html">
            Espumisan 240 mg minkštosios kapsulės
          </a>
          <a class="a link" href="/espumisan-40mg.html">
            Espumisan 40 mg minkštosios kapsulės
          </a>
        ''');
      }
      if (request.url.path == '/espumisan-40mg.html') {
        return _html('''
          <html><head><title>Espumisan 40mg minkštosios kapsulės N50</title></head>
          <body>
            <a class="layer1__link" href="/espumisan-40mg-n25.html">
              Espumisan 40mg minkštosios kapsulės N25
            </a>
          </body></html>
        ''');
      }
      return _html('''
        <html><head><title>Espumisan 40mg minkštosios kapsulės N25</title></head>
        <body><ul class="pharmacy-block">
          ${_offer('eurovaistine', '3.60', 'https://eurovaistine.lt/product')}
          ${_offer('camelia', '3.45', 'https://camelia.lt/product')}
          ${_offer('tamro', '3.70', 'http://unsafe.example/product')}
        </ul></body></html>
      ''');
    });

    final result = await MedicinePriceService(client).find(
      medicine,
      forceRefresh: true,
    );

    expect(result.productUrl, 'https://vaistai.lt/espumisan-40mg-n25.html');
    expect(result.packageLabel, contains('N25'));
    expect(result.offers, hasLength(2));
    expect(result.best.pharmacy, 'Camelia');
    expect(result.best.price, 3.45);
  });

  test('loads the dynamically rendered pharmacy table', () async {
    var postedForOffers = false;
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/paieska/')) {
        return _html(
          '<a href="/espumisan-40mg.html">'
          'Espumisan 40mg minkštosios kapsulės</a>',
          headers: {'set-cookie': 'PHPSESSID=test-session; path=/'},
        );
      }
      if (request.method == 'POST') {
        postedForOffers = true;
        expect(request.headers['cookie'], 'PHPSESSID=test-session');
        expect(request.bodyFields['task'], 'elvaistines');
        expect(request.bodyFields['0123456789abcdef'], '1');
        return _html('''
          <ul class="pharmacy-block">
            ${_offer('camelia', '4.39', 'https://camelia.lt/product')}
          </ul>
        ''');
      }
      return _html('''
        <html><head><title>Espumisan 40mg minkštosios kapsulės N50</title></head>
        <body><section id="section5" data-token="0123456789abcdef"></section></body>
        </html>
      ''');
    });

    final result = await MedicinePriceService(client).find(
      Med(
        id: 'dynamic-espumisan',
        name: 'Espumisan',
        substance: 'Simetikonas',
        strength: '40 mg',
        purpose: '',
        category: 'Virškinimas',
        expiry: '',
        stock: 10,
        dosageForm: 'minkštosios kapsulės',
        packageSize: '',
      ),
      forceRefresh: true,
    );

    expect(postedForOffers, isTrue);
    expect(result.best.price, 4.39);
  });
}

http.Response _html(String value, {Map<String, String>? headers}) =>
    http.Response.bytes(utf8.encode(value), 200, headers: headers);

String _offer(String pharmacy, String price, String url) => '''
  <li class="list__item">
    <img alt="$pharmacy">
    <span class="price__amount" data-price="$price">$price €</span>
    <a class="buy-button" data-urltracker="$pharmacy" href="$url">Pirkti</a>
  </li>
''';
