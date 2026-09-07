# MediBox — Android ir iOS prototipas

Flutter šeimos vaistinėlė. Dabartinė versija dar nėra baigtas produktas.

Veikia / įgyvendinta kode: vietinė vaistų saugykla, rankinis pridėjimas, likučio mažinimas, kameros / galerijos OCR ir kodų nuskaitymas. Native funkcijas būtina išbandyti telefone.

Šeimos ir priminimų ekranai bei šiandienos dozės yra demonstraciniai. HealthKit, Health Connect, pranešimų planavimas, vartojimo istorija ir VVKT importas neįgyvendinti.

## Kūrimas

GitHub Actions turi Android APK ir atskirą iOS kompiliavimo workflow. Native projektai generuojami atskirai ir konfigūruojami `tool/prepare_platforms.py`, nekeičiant Dart programos ar testų.

Android artifact: `MediBox-Android-APK`. iOS artifact: `MediBox-iOS-unsigned` — nepasirašyta programa, netinkama tiesiogiai diegti iPhone. TestFlight reikės Apple pasirašymo.

Sėkmingas build dar nepatvirtintas. Pataisymų, atliktų patikrų ir prieigos kliūties informacija: [BUILD_STATUS.md](BUILD_STATUS.md).
