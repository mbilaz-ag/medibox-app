import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/leaflet_draft.dart';
import '../services/firebase_leaflet_service.dart';

typedef LeafletGenerator = Future<LeafletDraft> Function({
  required LeafletIdentity identity,
  required String sourceText,
  required String sourceUrl,
});

String _t(BuildContext c, String lt, String en) =>
    Localizations.localeOf(c).languageCode == 'en' ? en : lt;

class LeafletImportPage extends StatefulWidget {
  final LeafletIdentity identity;
  final String initialUrl;
  final LeafletGenerator generate;
  const LeafletImportPage({
    super.key,
    required this.identity,
    this.initialUrl = '',
    this.generate = FirebaseLeafletService.generate,
  });

  @override
  State<LeafletImportPage> createState() => _LeafletImportPageState();
}

class _LeafletImportPageState extends State<LeafletImportPage> {
  late final url = TextEditingController(text: widget.initialUrl);
  final text = TextEditingController();
  bool consent = false, busy = false, reviewed = false;
  String? error;
  LeafletDraft? draft;
  final selected = <String>{};

  @override
  void dispose() {
    url.dispose();
    text.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (busy || !consent) return;
    try {
      validateLeafletInput(widget.identity, text.text, url.text);
    } on FormatException {
      setState(
        () => error = _t(
          context,
          'Įrašyk HTTPS šaltinio nuorodą ir 200–60 000 ženklų lapelio tekstą. '
              'Tekste turi būti tikslus pavadinimas, stiprumas ir vaisto forma.',
          'Enter an HTTPS source URL and 200–60,000 characters of leaflet text. '
              'The text must contain the exact medicine name, strength and form.',
        ),
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.generate(
        identity: widget.identity,
        sourceText: text.text,
        sourceUrl: url.text,
      );
      if (!mounted) return;
      setState(() {
        draft = result;
        selected.clear();
        reviewed = false;
      });
    } on TimeoutException {
      if (mounted)
        setState(
          () => error = _t(
            context,
            'AI neatsakė laiku. Duomenys nepakeisti. Bandyk vėliau.',
            'AI timed out. No data changed. Try again later.',
          ),
        );
    } on FormatException {
      if (mounted)
        setState(
          () => error = _t(
            context,
            'Nepavyko patvirtinti vaisto atitikimo arba ištraukų. '
                'Patikrink lapelį. Duomenys nepakeisti.',
            'Medicine identity or quotations could not be validated. '
                'Check the leaflet. No data changed.',
          ),
        );
    } catch (_) {
      // Never expose raw provider messages, tokens or submitted text.
      if (mounted)
        setState(
          () => error = _t(
            context,
            'AI nepasiekiamas. Patikrink internetą. Jei kartojasi, reikia patikrinti '
                'Firebase AI Logic, App Check ir nemokamo plano limitus. Duomenys nepakeisti.',
            'AI is unavailable. Check your connection. If this persists, check '
                'Firebase AI Logic, App Check and free-tier limits. No data changed.',
          ),
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = draft;
    return Scaffold(
      appBar: AppBar(
        title: Text(_t(context, 'Papildyti iš lapelio', 'Import from leaflet')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              '${widget.identity.name} • ${widget.identity.strength}\n${widget.identity.form}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(
              _t(
                context,
                'AI ištraukos nėra gydymo paskyrimas. Jos gali būti nepilnos arba '
                    'neteisingai suskirstytos. Dozės pagal amžių ar svorį neskaičiuojamos. '
                    'Visada skaityk visą konkretaus vaisto lapelį.',
                'AI extracts are not a prescription. They may be incomplete or '
                    'misclassified. No age- or weight-based doses are calculated. '
                    'Always read the complete leaflet for the exact medicine.',
              ),
            ),
            const SizedBox(height: 16),
            if (result == null) ...[
              TextField(
                controller: url,
                enabled: !busy,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: _t(
                    context,
                    'Lapeliui priklausanti HTTPS nuoroda',
                    'Leaflet HTTPS URL',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: text,
                enabled: !busy,
                minLines: 8,
                maxLines: 16,
                maxLength: 60000,
                decoration: InputDecoration(
                  labelText: _t(
                    context,
                    'Įklijuok viešo lapelio tekstą',
                    'Paste public leaflet text',
                  ),
                  alignLabelWithHint: true,
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: consent,
                onChanged: busy
                    ? null
                    : (v) => setState(() => consent = v == true),
                title: Text(
                  _t(
                    context,
                    'Patikrinau vaisto pavadinimą, stiprumą ir formą. Sutinku siųsti '
                        'įklijuotą tekstą ir šiuos vaisto duomenis „Google Gemini“ analizei. '
                        'Tekste nėra asmens ar sveikatos duomenų.',
                    'I checked the medicine name, strength and form. I agree to send '
                        'the pasted text and these medicine details to Google Gemini. '
                        'The text contains no personal or health records.',
                  ),
                ),
              ),
              Text(
                _t(
                  context,
                  'Nuorodos turinys automatiškai neatsisiunčiamas. Nesiunčiami šeimos '
                      'profiliai, svoris, receptai ar vaistinėlės sąrašas.',
                  'The URL is not downloaded automatically. Family profiles, weight, '
                      'prescriptions and your medicine inventory are not sent.',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: consent && !busy ? _generate : null,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: Text(
                  _t(context, 'Paruošti AI juodraštį', 'Prepare AI draft'),
                ),
              ),
            ] else ...[
              Text(
                _t(
                  context,
                  'Pasirink, ką pridėti į kortelę',
                  'Select sections to add',
                ),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                _t(
                  context,
                  'Bus pridėta atskira lapelio skiltis. Esami ranka įvesti laukai ir '
                      'gydytojo paskyrimai nesikeis. Ankstesnė AI lapelio skiltis bus pakeista.',
                  'A separate leaflet section will be added. Existing manual fields '
                      'and prescriptions stay unchanged. Any previous AI leaflet section is replaced.',
                ),
              ),
              ...leafletFields.entries.map((entry) {
                final quote = result.sections[entry.key];
                final label = _t(context, entry.value.$1, entry.value.$2);
                if (quote == null)
                  return ListTile(
                    title: Text(label),
                    subtitle: Text(
                      _t(
                        context,
                        'Ištrauka neparengta — tikrink visą lapelį',
                        'No extract prepared — check the complete leaflet',
                      ),
                    ),
                  );
                return Card(
                  child: Column(
                    children: [
                      CheckboxListTile(
                        value: selected.contains(entry.key),
                        title: Text(label),
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            selected.add(entry.key);
                          } else {
                            selected.remove(entry.key);
                          }
                          reviewed = false;
                        }),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: SelectableText(quote),
                      ),
                    ],
                  ),
                );
              }),
              ExpansionTile(
                title: Text(
                  _t(
                    context,
                    'Palyginti su įklijuotu tekstu',
                    'Compare with pasted source',
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(text.text),
                  ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: reviewed,
                onChanged: (v) => setState(() => reviewed = v == true),
                title: Text(
                  _t(
                    context,
                    'Palyginau pasirinktas ištraukas su lapeliu ir patvirtinu jų pridėjimą.',
                    'I compared the selected extracts with the leaflet and approve adding them.',
                  ),
                ),
              ),
              FilledButton(
                onPressed: reviewed && selected.isNotEmpty
                    ? () => Navigator.pop(
                        context,
                        result.accept(selected, DateTime.now()),
                      )
                    : null,
                child: Text(
                  _t(
                    context,
                    'Perkelti į redaguojamą kortelę',
                    'Apply to editor',
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  draft = null;
                  selected.clear();
                  reviewed = false;
                  consent = false;
                }),
                child: Text(_t(context, 'Keisti šaltinį', 'Change source')),
              ),
            ],
            if (busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              Text(_t(context, 'Ruošiamas juodraštis…', 'Preparing draft…')),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class LeafletRecordCard extends StatelessWidget {
  final LeafletRecord record;
  const LeafletRecordCard({super.key, required this.record});

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _t(
              context,
              'Iš lapelio · AI atrinktos ištraukos',
              'Leaflet · AI-selected extracts',
            ),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            _t(
              context,
              'Patvirtinta naudotojo, ne mediko. Ištraukos nepakeičia viso lapelio '
                  'ar gydytojo paskyrimo. Nepateikta informacija nereiškia, kad rizikos nėra.',
              'Reviewed by the user, not a clinician. Extracts do not replace the '
                  'complete leaflet or prescription. Missing information does not mean no risk.',
            ),
          ),
          ...leafletFields.entries.map(
            (entry) => ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(_t(context, entry.value.$1, entry.value.$2)),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SelectableText(
                    record.sections[entry.key] ??
                        _t(
                          context,
                          'Ištrauka nepridėta. Tikrink visą lapelį.',
                          'No extract added. Check the complete leaflet.',
                        ),
                  ),
                ),
              ],
            ),
          ),
          Text(
            _t(
              context,
              'Šaltinio nuoroda pateikta naudotojo; automatiškai nepatikrinta.',
              'Source URL provided by the user; not automatically verified.',
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: Text(
              _t(
                context,
                'Atverti nurodytą lapelį',
                'Open supplied leaflet link',
              ),
            ),
            onPressed: () async {
              if (!isLeafletUrl(record.sourceUrl)) return;
              try {
                if (await launchUrl(
                  Uri.parse(record.sourceUrl),
                  mode: LaunchMode.externalApplication,
                ))
                  return;
              } catch (_) {
                /* Report without revealing provider errors. */
              }
              if (context.mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      _t(
                        context,
                        'Nepavyko atverti nuorodos.',
                        'Could not open link.',
                      ),
                    ),
                  ),
                );
            },
          ),
          Text(
            '${record.model} • ${record.acceptedAt.substring(0, 10)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
