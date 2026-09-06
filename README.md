# MediBox — Release Candidate

Local-first Android išmanios šeimos vaistinėlės projektas.

### Jau įgyvendinta
- vaistinėlė ir išsaugojimas telefone;
- rankinis vaisto pridėjimas;
- likučio apskaita;
- kamera / galerija + Google ML Kit OCR;
- barcode/QR skenavimas;
- galiojimo datos parserio branduolys;
- čekio vaistų eilučių parserio branduolys;
- vaisto kortelės;
- simptomų vedlys ir red-flag saugumo vartai;
- receptinių vaistų atmetimo logika simptomų rezultate;
- šeimos ir priminimų UI;
- testai ir GitHub Actions release APK.

### Prieš viešą leidimą
VVKT duomenų importas ir oficialių lapelių susiejimas turi būti užbaigtas bei validuotas. Simptomų taisykles turi peržiūrėti medicinos specialistas. eSveikata nėra šio RC priklausomybė.

### Build
GitHub Actions workflow sukuria `app-release.apk` ir įkelia jį kaip artifact.
