# Nuolatinis MediBox Android pasirašymas

Pasirašymo konfigūracija paruošta atskiroje šakoje, remiantis v0.17.5 ir
Firebase lapelio juodraščių pakeitimais. APK šiuo etapu nekuriamas.

## Viešas sertifikato SHA-256

```
D5:84:F3:16:AE:E2:1C:AE:7A:8E:60:D3:04:F5:83:E0:C4:56:11:1C:D2:0D:D7:76:91:1D:45:32:22:24:4C:0A
```

Alias: `medibox-release`. Saugyklos formatas: `PKCS12`.
Viešas kontrolinis atspaudas saugomas `config/android-signing.json`.

## Savininko veiksmai prieš kitą APK

Privatus raktas sukurtas vieną kartą, patikrintas ir perduotas atskirais failais.
Jų nėra repozitorijoje. Išsaugokite `MediBox-release-keystore.p12` ir
`MediBox-signing-password.txt` saugioje atsarginėje kopijoje / slaptažodžių tvarkyklėje.
Neperkurkite rakto kiekvienam leidimui.

[GitHub Actions Secrets](https://github.com/mbilaz-ag/medibox-app/settings/secrets/actions)
sukurkite du Repository Secrets:

| Pavadinimas | Reikšmė |
| --- | --- |
| `MEDIBOX_KEYSTORE_BASE64` | Visas `MediBox-keystore-base64.txt` turinys |
| `MEDIBOX_KEYSTORE_PASSWORD` | `MediBox-signing-password.txt` slaptažodis |

Šie Secrets dar nenustatyti. Slaptažodis ir raktas negali būti įkelti į GitHub failus,
komentarus, darbo eigos tekstą ar komandų žurnalus.

Firebase projekte `medibox-6d80d`, App Check → Android MediBox → Play Integrity
įrašykite aukščiau pateiktą SHA-256. APK platinant už Google Play ribų,
oficiali Firebase lentelė nurodo nereikalauti `PLAY_RECOGNIZED` ir `LICENSED`,
o minimaliam įrenginio patikrinimui reikalauti Device integrity.
App Check enforcement neišjunkite kaip problemų sprendimo būdo.

Gyva AI užklausa ir tikro įrenginio atestacija dar nepatikrintos.

## Darbo eiga

Pasirašymo saugykla atkuriama privačiame runner laikinajame kataloge, už checkout
ribų. Prieš kompiliuojant tikrinamas sertifikato SHA-256. Gradle gauna slaptažodį
iš aplinkos; į failus jis nerašomas. Be rakto release užduotis turi sustoti.
Prieš pateikiant APK `apksigner` patikrina parašo galiojimą ir tikėtiną sertifikatą.
Laikinas privatus raktas pašalinamas ir nepatenka į native source artefaktą.
Pull request patikros negauna privataus rakto ir nekuria pasirašyto APK.

`signing-checks.yml` tikrina Python saugiklius, Dart analizę, Flutter testus ir
`gradlew help` konfigūraciją. APK ir iOS paketo jis nekompiliuoja.

## Senos versijos atnaujinimas

v0.17.5 buvo pasirašyta Android Debug sertifikatu. Dėl pasikeitusio sertifikato
gali tekti iš naujo įdiegti programėlę. Prieš šalinant seną versiją būtina
eksportuoti vietinius duomenis ir patikrinti atsarginę kopiją. Kol naujas APK
neparuoštas ir duomenys neišsaugoti, senos programėlės nešalinkite.

## Šaltiniai

- https://firebase.google.com/docs/app-check/android/play-integrity-provider
- https://developer.android.com/studio/publish/app-signing
- https://docs.flutter.dev/deployment/android
- https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets
