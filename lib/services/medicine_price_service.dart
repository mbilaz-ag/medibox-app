import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../models/models.dart';

class MedicinePriceOffer {
  final String pharmacy;
  final double price;
  final String url;

  const MedicinePriceOffer({
    required this.pharmacy,
    required this.price,
    required this.url,
  });
}

class MedicinePriceComparison {
  final String productUrl;
  final String packageLabel;
  final DateTime fetchedAt;
  final List<MedicinePriceOffer> offers;

  const MedicinePriceComparison({
    required this.productUrl,
    required this.packageLabel,
    required this.fetchedAt,
    required this.offers,
  });

  MedicinePriceOffer get best => offers.first;
}

class MedicinePriceService {
  final http.Client client;
  MedicinePriceService(this.client);

  static final _cache = <String, MedicinePriceComparison>{};
  static const _cacheDuration = Duration(minutes: 30);

  static String normalize(String value) {
    var result = value.toLowerCase();
    const lt = 'ąčęėįšųūž';
    const ascii = 'aceeisuuz';
    for (var index = 0; index < lt.length; index++) {
      result = result.replaceAll(lt[index], ascii[index]);
    }
    return result.replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  Future<Document> _get(Uri uri) async {
    for (var redirects = 0; redirects < 5; redirects++) {
      if (uri.scheme != 'https' || uri.host != 'vaistai.lt') {
        throw const FormatException('Unexpected price source');
      }
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['User-Agent'] =
            'MediBox/1.0 (+https://github.com/mbilaz-ag/medibox-app)'
        ..headers['Accept-Language'] = 'lt,en;q=0.8';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        await response.stream.drain<void>();
        final location = response.headers['location'];
        if (location == null) throw const FormatException('Missing redirect');
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        throw StateError('Medicine price HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 2000000) {
          throw const FormatException('Oversized price page');
        }
      }
      return html.parse(utf8.decode(bytes));
    }
    throw const FormatException('Too many redirects');
  }

  Future<MedicinePriceComparison> find(
    Med medicine, {
    bool forceRefresh = false,
  }) async {
    final key = normalize(
      '${medicine.name}|${medicine.strength}|${medicine.dosageForm}|'
      '${medicine.packageSize}',
    );
    final cached = _cache[key];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _cacheDuration) {
      return cached;
    }

    final search = Uri.https(
      'vaistai.lt',
      '/paieska/${medicine.name.trim()}.html',
    );
    final results = await _get(search);
    var productUrl = _selectProductUrl(results, search, medicine);
    var page = await _get(productUrl);

    final variantUrl = _selectPackageVariant(page, productUrl, medicine);
    if (variantUrl != null && variantUrl != productUrl) {
      productUrl = variantUrl;
      page = await _get(productUrl);
    }

    final offers = parseOffers(page);
    if (offers.isEmpty) throw const FormatException('No medicine prices');
    final result = MedicinePriceComparison(
      productUrl: productUrl.toString(),
      packageLabel: _packageLabel(page, medicine),
      fetchedAt: DateTime.now(),
      offers: offers,
    );
    if (_cache.length >= 40) _cache.remove(_cache.keys.first);
    _cache[key] = result;
    return result;
  }

  static Uri _selectProductUrl(Document page, Uri search, Med medicine) {
    final identity = normalize(
      '${medicine.name}${medicine.strength}${medicine.dosageForm}',
    );
    final fallbackIdentity = normalize('${medicine.name}${medicine.strength}');
    final matches = <Uri>{};
    for (final link in page.querySelectorAll('a[href]')) {
      final title = normalize(link.text);
      final expected = identity.isNotEmpty ? identity : fallbackIdentity;
      if (expected.isEmpty ||
          (title != expected && !title.startsWith(expected))) {
        continue;
      }
      final uri = search.resolve(link.attributes['href']!);
      if (uri.scheme == 'https' &&
          uri.host == 'vaistai.lt' &&
          uri.path.endsWith('.html') &&
          !uri.path.startsWith('/paieska/')) {
        matches.add(uri.replace(query: '', fragment: ''));
      }
    }
    if (matches.length != 1) {
      throw const FormatException('No unique exact medicine price page');
    }
    return matches.single;
  }

  static Uri? _selectPackageVariant(
    Document page,
    Uri productUrl,
    Med medicine,
  ) {
    final package = normalize(medicine.packageSize);
    if (package.isEmpty) return null;
    final identity = normalize(
      '${medicine.name}${medicine.strength}${medicine.dosageForm}',
    );
    final variants = <Uri>{};
    for (final link in page.querySelectorAll('a[href]')) {
      final title = normalize(link.text);
      if (!title.startsWith(identity) || !title.endsWith(package)) continue;
      final uri = productUrl.resolve(link.attributes['href']!);
      if (uri.scheme == 'https' && uri.host == 'vaistai.lt') {
        variants.add(uri.replace(query: '', fragment: ''));
      }
    }
    if (variants.length == 1) return variants.single;
    final currentLabel = normalize(
      '${page.querySelector('title')?.text ?? ''} '
      '${_packageLabel(page, medicine)}',
    );
    if (currentLabel.contains(package)) return null;
    throw const FormatException('Exact medicine package not found');
  }

  static String _packageLabel(Document page, Med medicine) {
    final title = (page.querySelector('title')?.text ?? '').trim();
    if (normalize(title).startsWith(normalize(medicine.name))) return title;
    return medicine.packageSize.trim();
  }

  static List<MedicinePriceOffer> parseOffers(Document page) {
    final offers = <MedicinePriceOffer>[];
    final seen = <String>{};
    for (final row in page.querySelectorAll('ul.pharmacy-block li.list__item')) {
      final priceNode = row.querySelector('.price__amount[data-price]');
      final buy = row.querySelector('a.buy-button[href]');
      final rawPrice = priceNode?.attributes['data-price'];
      final price = double.tryParse(rawPrice?.replaceAll(',', '.') ?? '');
      final uri = Uri.tryParse(buy?.attributes['href'] ?? '');
      if (price == null ||
          price <= 0 ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty) {
        continue;
      }
      final tracker = buy?.attributes['data-urltracker'] ?? '';
      final imageName = row.querySelector('img[alt]')?.attributes['alt'] ?? '';
      final pharmacy = _pharmacyName(
        tracker.isNotEmpty ? tracker : imageName,
        uri.host,
      );
      final unique = '$pharmacy|${uri.toString()}';
      if (!seen.add(unique)) continue;
      offers.add(
        MedicinePriceOffer(
          pharmacy: pharmacy,
          price: price,
          url: uri.toString(),
        ),
      );
    }
    offers.sort((first, second) => first.price.compareTo(second.price));
    return offers;
  }

  static String _pharmacyName(String value, String host) {
    return switch (normalize(value)) {
      'eurovaistine' => 'Eurovaistinė',
      'camelia' => 'Camelia',
      'limedika' => 'Gintarinė vaistinė',
      'tamro' => 'BENU',
      '100metu' => '100 metų',
      'entafarma' => 'Mano vaistinė',
      'rxvaistine' => 'RX vaistinė',
      'apotheka' => 'Apotheka',
      'internetinevaistine' => 'Internetinė vaistinė',
      _ => host.replaceFirst('www.', ''),
    };
  }
}
