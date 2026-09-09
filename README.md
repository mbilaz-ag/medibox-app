# MediBox — Android ir iOS prototipas

Flutter šeimos vaistinėlė. Dabartinė versija dar nėra baigtas produktas.

Veikia / įgyvendinta kode: vietinė vaistų saugykla, vaistų ir šeimos narių redagavimas, vartojimo priminimai, likučių bei galiojimo stebėjimas, kameros / galerijos OCR, kodų nuskaitymas, pasirenkamos kategorijos ir nuskaityto vaisto tikrinimas oficialiame VVKT atvirų duomenų rinkinyje. Native funkcijas būtina išbandyti telefone.

## Kūrimas

GitHub Actions turi Android APK ir atskirą iOS kompiliavimo workflow. Native projektai generuojami atskirai ir konfigūruojami `tool/prepare_platforms.py`, nekeičiant Dart programos ar testų.

Android artifact: `MediBox-Android-APK`. iOS compilation artifact: `MediBox-iOS-unsigned`.

The manually triggered `Build and upload MediBox iOS to TestFlight` workflow
creates a signed `MediBox-iOS-signed-IPA` artifact and uploads it to TestFlight.
It requires an active Apple Developer membership, an App Store distribution
certificate, an App Store provisioning profile for `lt.medibox.medibox`, and an
App Store Connect API key configured as repository secrets.

Pataisymų, atliktų patikrų ir prieigos informacija: [BUILD_STATUS.md](BUILD_STATUS.md).
