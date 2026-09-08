import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import 'vvkt_service.dart';

class RetrievedMedicineLeaflet {
  final String text;
  final String url;
  final Map<String, String> sections;
  final String imageUrl;
  const RetrievedMedicineLeaflet(this.text, this.url, this.sections,
      {this.imageUrl = ''});
}

/// Retrieves the published leaflet, not a search snippet or generated facts.
class MedicineLeafletLookup {
  final http.Client client;
  MedicineLeafletLookup(this.client);

  static String normalize(String value) {
    var result = value.toLowerCase();
    const lt = 'ąčęėįšųūž';
    const ascii = 'aceeisuuz';
    for (var i = 0; i < lt.length; i++) {
      result = result.replaceAll(lt[i], ascii[i]);
    }
    return result.replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  Future<String> _get(Uri uri) async {
    for (var redirects = 0; redirects < 5; redirects++) {
      if (uri.scheme != 'https' || uri.host != 'vaistai.lt') {
        throw const FormatException('Unexpected leaflet host');
      }
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['User-Agent'] = 'MediBox/1.0 (+https://github.com/mbilaz-ag/medibox-app)'
        ..headers['Accept-Language'] = 'lt,en;q=0.8';
      final response = await client.send(request).timeout(const Duration(seconds: 20));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        await response.stream.drain<void>();
        final location = response.headers['location'];
        if (location == null) throw const FormatException('Missing redirect');
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        throw StateError('Leaflet HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 2000000) throw const FormatException('Oversized leaflet page');
      }
      return utf8.decode(bytes);
    }
    throw const FormatException('Too many leaflet redirects');
  }

  static String plainText(String markup) => html.parseFragment(markup
      .replaceAll(RegExp(r'</(?:p|li|tr|h[1-6])>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n'))
      .text!.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n+'), '\n').trim();

  static String _imageUrl(Document page, Uri pageUri) {
    final candidates = <String>[
      ...page.querySelectorAll('meta[property="og:image"], meta[name="twitter:image"]')
          .map((node) => node.attributes['content'] ?? ''),
      ...page.querySelectorAll('.product-info img[src], .product-title img[src]')
          .map((node) => node.attributes['src'] ?? ''),
    ];
    for (final value in candidates) {
      final uri = pageUri.resolve(value.trim());
      if (uri.scheme == 'https' && uri.host == 'vaistai.lt') return uri.toString();
    }
    return '';
  }

  Future<RetrievedMedicineLeaflet> find(VvktMedicine medicine) async {
    if (medicine.name.trim().isEmpty || medicine.strength.trim().isEmpty ||
        medicine.dosageForm.trim().isEmpty) {
      throw const FormatException('Exact medicine identity required');
    }
    final search = Uri.https('vaistai.lt', '/paieska/${medicine.name.trim()}.html');
    final results = html.parse(await _get(search));
    final identity = normalize('${medicine.name}${medicine.strength}${medicine.dosageForm}');
    final matches = <String>{};
    for (final link in results.querySelectorAll('.card__title a[href]')) {
      final title = normalize(link.text);
      // 40 mg must not match 240 mg or 40 mg/ml; form must also match.
      if (title != identity && !title.startsWith('${identity}n')) continue;
      final uri = search.resolve(link.attributes['href']!);
      if (uri.scheme == 'https' && uri.host == 'vaistai.lt') matches.add(uri.toString());
    }
    if (matches.length != 1) throw const FormatException('No unique exact leaflet');
    final url = matches.single;
    final page = html.parse(await _get(Uri.parse(url)));
    final leaflet = page.querySelector('#modal-info-sheet-content');
    if (leaflet == null) throw const FormatException('Leaflet missing');
    final text = plainText(leaflet.innerHtml);
    if (text.length < 300 || text.length > 60000 ||
        !normalize(text.substring(0, text.length < 700 ? text.length : 700)).contains(identity)) {
      throw const FormatException('Leaflet identity mismatch');
    }
    final sections = <String, String>{};
    for (final article in leaflet.querySelectorAll('article[data-nodeindex]')) {
      sections[article.attributes['data-nodeindex']!] = plainText(article.innerHtml);
    }
    return RetrievedMedicineLeaflet(text, url, sections,
        imageUrl: _imageUrl(page, Uri.parse(url)));
  }
}
