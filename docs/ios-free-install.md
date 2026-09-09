# Nemokamas „MediBox“ diegimas į iPhone

„MediBox“ galima įdiegti be mokamos „Apple Developer“ narystės, naudojant
asmeninį nemokamą „Apple ID“. „Apple“ tokiam parašui taiko 7 dienų galiojimą,
todėl po 7 dienų programėlę reikia pasirašyti ir įdiegti iš naujo. Iš naujo
diegiant ant viršaus vietiniai duomenys paprastai lieka, tačiau prieš diegimą
rekomenduojama prisijungti prie „Google“ ir sulaukti sinchronizavimo.

## Windows: diegimas per Sideloadly

1. GitHub projekto skiltyje **Actions → Build MediBox iOS** atidarykite naujausią
   sėkmingą paleidimą ir iš **Artifacts** atsisiųskite
   `MediBox-iOS-free-install`.
2. Išarchyvuokite atsisiųstą ZIP. Viduje bus
   `MediBox-v0.20.1-unsigned.ipa`.
3. Įdiekite naujausią „iTunes“ ir „iCloud“ tiesiai iš „Apple“ svetainės (ne
   „Microsoft Store“ versijas), tada įdiekite „Sideloadly“ iš oficialios
   svetainės.
4. Prijunkite atrakintą iPhone USB laidu, telefone pasirinkite **Trust** ir
   įveskite telefono kodą.
5. Atidarykite „Sideloadly“, pasirinkite prijungtą telefoną, nutempkite
   `MediBox-v0.20.1-unsigned.ipa`, įveskite savo „Apple ID“ adresą ir spauskite
   **Start**. Slaptažodį arba dviejų veiksnių patvirtinimą įveskite tik
   „Sideloadly“ / „Apple“ lange; niekam jo nesiųskite.
6. iPhone atidarykite **Settings → General → VPN & Device Management** ir
   patvirtinkite savo „Apple ID“ kūrėjo profilį, jei iOS to paprašys.
7. Jei telefone įjungtas **Developer Mode**, perkraukite telefoną ir patvirtinkite
   jo įjungimą. Jei jo nėra, pirmiausia pabandykite paleisti „MediBox“ — iOS pati
   parodys, ar šis žingsnis būtinas.

Po 7 dienų tą patį IPA įdiekite dar kartą ant esamos programėlės. Programėlės
prieš tai netrinkite, nes ištrynus dingsta tik telefone laikomos nuotraukos ir
kiti dar nesinchronizuoti vietiniai duomenys.

## Mac: diegimas tiesiai iš Xcode

1. Įdiekite naujausią „Xcode“, „Flutter 3.47.2“ ir „CocoaPods“.
2. Projekto kataloge vykdykite:

   ```bash
   flutter pub get
   flutter create --no-pub --platforms=android,ios --project-name medibox --org lt.medibox /tmp/medibox-native
   python3 tool/prepare_platforms.py /tmp/medibox-native
   open ios/Runner.xcworkspace
   ```

3. Xcode pasirinkite **Runner → Signing & Capabilities**, įjunkite
   **Automatically manage signing** ir prie **Team** pasirinkite savo
   **Personal Team**.
4. Prijunkite iPhone, pasirinkite jį kaip paleidimo įrenginį ir spauskite Run.

Jei Xcode praneša, kad `lt.medibox.medibox` identifikatorius nepasiekiamas,
pakeiskite **Bundle Identifier** į unikalų, pavyzdžiui
`lt.medibox.asmeninis.vardas`. Tokiu atveju Firebase / Google prisijungimą taip
pat reikės užregistruoti naujam identifikatoriui; todėl pirmiausia naudokite
numatytąjį `lt.medibox.medibox`.

## Svarbios ribos

- Nemokamas „Apple ID“ nėra TestFlight ar App Store leidimas.
- Parašas galioja 7 dienas ir vienu metu leidžiamas ribotas asmeniškai pasirašytų
  programėlių skaičius.
- Programėlės ištrynimas pašalina telefone laikomas vaistų bei narių nuotraukas;
  jos sąmoningai nekeliamos į mokamą „Firebase Storage“.
- Duomenų sinchronizavimui telefone turi veikti prisijungimas su „Google“.
