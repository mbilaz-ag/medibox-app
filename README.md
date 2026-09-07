# MediBox — Android ir iOS prototipas

Flutter šeimos vaistinėlė. Dabartinė versija dar nėra baigtas produktas.

Veikia / įgyvendinta kode: vietinė vaistų saugykla, vaistų ir šeimos narių redagavimas, vartojimo priminimai, likučių bei galiojimo stebėjimas, kameros / galerijos OCR, kodų nuskaitymas, pasirenkamos kategorijos ir nuskaityto vaisto tikrinimas oficialiame VVKT atvirų duomenų rinkinyje. Native funkcijas būtina išbandyti telefone.

## Kūrimas

GitHub Actions turi Android APK ir atskirą iOS kompiliavimo workflow. Native projektai generuojami atskirai ir konfigūruojami `tool/prepare_platforms.py`, nekeičiant Dart programos ar testų.

Android artifact: `MediBox-Android-APK`. iOS artifact: `MediBox-iOS-unsigned` — nepasirašyta programa, netinkama tiesiogiai diegti iPhone. TestFlight reikės Apple pasirašymo.

Pataisymų, atliktų patikrų ir prieigos informacija: [BUILD_STATUS.md](BUILD_STATUS.md).
