# MediBox Release Candidate

## Producto moduliai
1. Pagrindinis: šiandienos dozės, likučiai, galiojimo įspėjimai.
2. Vaistinėlė: paieška, kategorijos, vaisto kortelė, receptinis/nereceptinis, likutis, galiojimas.
3. Skenavimas: kamera/galerija, on-device OCR, barcode/QR.
4. Čekio srautas: OCR tekstas paruoštas parseriui; prieš įrašymą vartotojas privalo patvirtinti rezultatą.
5. „Man bloga“: simptomų kategorijos, red-flag saugumo vartai, tik turimų nereceptinių preparatų atitikmenys.
6. Šeima: atskirų profilių UI.
7. Priminimai: dienos grafiko UI; pranešimų planavimas dar neįgyvendintas.
8. Duomenys: local-first. Cloud/eSveikata neprivalomi programos veikimui.

## Oficialaus vaistų katalogo kontraktas
Produkcinis katalogas turi importuoti VVKT atvirus duomenis ir saugoti bent:
- NPAKID / registracijos identifikatorių
- pavadinimą
- veikliąją medžiagą
- stiprumą
- farmacinę formą
- pakuotės dydį
- recepto statusą
- ATC
- oficialaus pakuotės lapelio nuorodą / dokumento identifikatorių
- duomenų versiją ir atnaujinimo datą

AI negali būti autoritetingas šių laukų šaltinis.

## Saugumo taisyklė
Simptomų funkcija yra navigacija po oficialiai aprašytas indikacijas, ne diagnozavimo sistema. Receptiniai vaistai iš automatinio „ką turiu nuo to“ rezultato atmetami. Red flags sustabdo vaisto parinkimą.
