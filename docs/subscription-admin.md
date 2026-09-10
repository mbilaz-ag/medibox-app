# MediBox planų valdymas per Firebase

Kol mokėjimai neprijungti, naudotojo planas valdomas `Firebase Console` →
`Firestore Database` dokumente:

`users/{firebaseUid}/subscription/current`

## Numatytoji būsena

Jei dokumento nėra arba `plan` reikšmė neatpažįstama, naudotojas turi `Free`
planą. Programėlė pati šio dokumento kurti ar keisti negali.

## Mėnesinis Premium

```text
plan: premium_monthly
status: active
provider: manual
validUntil: 2026-10-10 23:59:59 (Timestamp)
```

## Metinis Premium

```text
plan: premium_yearly
status: active
provider: manual
validUntil: 2027-09-10 23:59:59 (Timestamp)
```

`validUntil` galima praleisti suteikiant neterminuotą dovanų planą. Norint
atšaukti prieigą, dokumentą ištrinkite, pakeiskite `plan` į `free` arba
`status` į `cancelled`.

Vėliau patikimas Stripe, Google Play ar App Store serveris atnaujins tą patį
dokumentą ir nustatys `provider` į `stripe`, `google_play` arba `app_store`.
