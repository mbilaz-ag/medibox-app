import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/medicine_price_service.dart';

class MedicinePriceCard extends StatefulWidget {
  final Med medicine;

  const MedicinePriceCard({super.key, required this.medicine});

  @override
  State<MedicinePriceCard> createState() => _MedicinePriceCardState();
}

class _MedicinePriceCardState extends State<MedicinePriceCard> {
  late Future<MedicinePriceComparison> _comparison;
  late String _loadedIdentity;
  bool _showAll = false;

  bool get _english => Localizations.localeOf(context).languageCode == 'en';
  String _text(String lt, String en) => _english ? en : lt;

  @override
  void initState() {
    super.initState();
    _loadedIdentity = _identity(widget.medicine);
    _comparison = _load();
  }

  @override
  void didUpdateWidget(covariant MedicinePriceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identity = _identity(widget.medicine);
    if (_loadedIdentity != identity) {
      _loadedIdentity = identity;
      _comparison = _load();
      _showAll = false;
    }
  }

  String _identity(Med medicine) =>
      '${medicine.name}|${medicine.strength}|${medicine.dosageForm}|'
      '${medicine.packageSize}';

  Future<MedicinePriceComparison> _load({bool refresh = false}) async {
    final client = http.Client();
    try {
      return await MedicinePriceService(
        client,
      ).find(widget.medicine, forceRefresh: refresh);
    } finally {
      client.close();
    }
  }

  String _price(double value) =>
      '${value.toStringAsFixed(2).replaceAll('.', ',')} €';

  Future<void> _open(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _text(
              'Nepavyko atidaryti vaistinės puslapio.',
              'Could not open the pharmacy page.',
            ),
          ),
        ),
      );
    }
  }

  void _refresh() {
    setState(() {
      _loadedIdentity = _identity(widget.medicine);
      _comparison = _load(refresh: true);
      _showAll = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.price_check_rounded, color: Color(0xff079b7a)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _text('Kainos vaistinėse', 'Pharmacy prices'),
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _text('Atnaujinti kainas', 'Refresh prices'),
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            FutureBuilder<MedicinePriceComparison>(
              future: _comparison,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return Row(
                    children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Text(_text('Tikrinamos kainos…', 'Checking prices…')),
                    ],
                  );
                }
                final comparison = snapshot.data;
                if (comparison == null || comparison.offers.isEmpty) {
                  return Text(
                    _text(
                      'Šiai tiksliai vaisto pakuotei kainų palyginimo rasti nepavyko.',
                      'No price comparison was found for this exact package.',
                    ),
                  );
                }
                final visible = _showAll
                    ? comparison.offers
                    : comparison.offers.take(3).toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_text('Geriausia rasta kaina', 'Best price found')}: '
                      '${_price(comparison.best.price)}',
                      style: const TextStyle(
                        color: Color(0xff079b7a),
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (comparison.packageLabel.isNotEmpty)
                      Text(
                        comparison.packageLabel,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    const Divider(height: 22),
                    ...visible.map(
                      (offer) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(offer.pharmacy),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _price(offer.price),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.open_in_new_rounded, size: 18),
                          ],
                        ),
                        onTap: () => _open(offer.url),
                      ),
                    ),
                    if (comparison.offers.length > 3)
                      TextButton(
                        onPressed: () => setState(() => _showAll = !_showAll),
                        child: Text(
                          _showAll
                              ? _text('Rodyti mažiau', 'Show less')
                              : _text(
                                  'Rodyti visas (${comparison.offers.length})',
                                  'Show all (${comparison.offers.length})',
                                ),
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () => _open(comparison.productUrl),
                      icon: const Icon(Icons.source_outlined, size: 18),
                      label: const Text('Vaistai.lt'),
                    ),
                    Text(
                      _text(
                        'Kainos gali keistis. Galutinę kainą, likutį ir recepto sąlygas patikrinkite vaistinėje.',
                        'Prices may change. Check the final price, availability and prescription terms with the pharmacy.',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
