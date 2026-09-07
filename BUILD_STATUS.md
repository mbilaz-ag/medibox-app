# Android ir iOS kūrimo pataisymas — 2026-09-07

## Patvirtinta iš GitHub žurnalo
Paleidimas 34065906367 sustojo ties Analyze: main.dart turėjo 7 sintaksės / argumentų klaidas ir nenaudojamą dart:io importą. Android projekto katalogo repozitoriume nėra.

## Šio pakeitimo apimtis
- Pataisyti Dart skliaustai ir nenaudojamas importas.
- Teste imituojama SharedPreferences saugykla ir laukiama programos užkrovimo.
- OCR klaidos apdorojamos, resursai uždaromi; apsaugota nuo setState po ekrano uždarymo ir kelių vieno kodo nuskaitymo navigacijų.
- Android ir iOS projektai generuojami atskirame laikiname kataloge. Nukopijuojami tik native katalogai, todėl Flutter pavyzdžio kodas ir testai nepakeičia MediBox failų.
- Android kameros leidimas, iOS kameros ir nuotraukų paaiškinimai, iOS 15.5 target ir CocoaPods konfigūracija.
- Atskiri Android APK ir nepasirašyto iOS kompiliavimo workflow. Analyzer klaidos ir perspėjimai neslepiami.

## Patikros ribos
Dart 3.13.3 sėkmingai suformatavo visus Dart failus. Keturi parserio patikrinimai vykdyti Dart su įjungtais assert — sėkmingi. Platformų paruošimo scenarijus patikrintas laikinais native failais, įskaitant pakartotinį vykdymą; abu workflow YAML failai perskaityti be klaidų. Tai nepakeičia flutter analyze, flutter test ar tikro Android/iOS build. Pilna patikra laukia GitHub prieigos. Sukurto APK ir įdiegiamo iOS leidimo dar nėra.

## Prieiga
GitHub create_tree grąžino 403 Resource not accessible by integration. GitHub list_installations grąžino tuščią sąrašą. Todėl negalima tiksliai teigti, kad problema yra vien konkretaus repozitoriumo pasirinkimas: reikia atkurti GitHub App ryšį ir suteikti jam prieigą prie mbilaz-ag/medibox-app bei failų ir workflow keitimo teises.

## Dar neįgyvendinta
Šeimos profiliai ir priminimų ekranai demonstraciniai. Pranešimų planavimo, vartojimo istorijos, HealthKit / Health Connect ir debesų sinchronizacijos nėra. Dabartinis pradinis vaistų sąrašas ir šiandienos dozės yra demonstraciniai duomenys. Tai nėra baigtas produktas.

iOS įtrauktas į kūrimo eigą, tačiau nepasirašytas Runner.app nėra įdiegiamas iPhone. TestFlight etapui reikės Apple Developer paskyros ir pasirašymo konfigūracijos. Android naudoja Flutter šablono testinį pasirašymą; viešam leidimui būtinas stabilus privatus pasirašymo raktas.

## Šaltiniai
- https://pub.dev/packages/google_mlkit_text_recognition/versions/0.15.0 — iOS 15.5 ir native konfigūracija.
- https://docs.flutter.dev/deployment/ios — iOS pasirašymas ir leidimas.
