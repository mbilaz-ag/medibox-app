# Firebase leaflet drafts — first increment

Based on the accepted v0.17.5 release. No APK build or main-branch release is
performed by the validation workflow for this feature branch.

## Configuration

- Firebase project: `medibox-6d80d`, Android package: `lt.medibox.medibox`.
- `config/google-services.json` is the user-provided **Android client config**,
  intentionally bundled as a Flutter asset. It is not an Admin SDK credential or
  a Gemini API key. `Firebase.initializeApp(options: ...)` uses these values
  explicitly, so a generated native Google Services Gradle plugin is not needed
  for this AI-only increment. Google sign-in/FCM are not implemented here.
- Firebase AI Logic uses the Gemini Developer API (Spark), not Vertex AI.
- Default model: `gemini-3.5-flash-lite`; override with
  `--dart-define=MEDIBOX_LEAFLET_MODEL=...` when a supported replacement is needed.
  No automatic switch to a paid backend or model is implemented.
- Firebase starts only on explicit import, not app startup. Existing local
  medicine data works without Firebase, network access, or on other platforms.
- Android release uses App Check Play Integrity; debug uses the debug provider.
  Never distribute a shared App Check debug token or disable enforcement to make
  an APK work. No service-account or Gemini secret belongs in the repository.

## Console tasks before a live Android test

AI Logic/Gemini Developer API was enabled by the owner. This has **not** been
verified by a live inference request. Register the Android app under App Check
with the SHA-256 of the certificate that signs the actual APK. Check Play
Integrity requirements for the intended distribution channel: a sideloaded APK
must not be assumed to pass Play Store licensing/recognition checks. Keep
enforcement and configure only the attestation settings appropriate for the
authorized distribution. A stable release signing key is required for a durable
release configuration; the current generated Flutter release setup uses the
debug signing configuration. Do not claim production attestation is complete.

Documentation:
- https://firebase.google.com/docs/ai-logic/get-started
- https://firebase.google.com/docs/ai-logic/pricing
- https://firebase.google.com/docs/app-check/android/play-integrity-provider
- https://firebase.google.com/docs/app-check/flutter/default-providers
- https://firebase.google.com/docs/ai-logic/models

## User flow and boundaries

Medicine editor → Import leaflet with AI → paste public leaflet text and its
HTTPS URL → consent → AI draft → select passages → compare and approve → return
to editor → Save medicine.

Only name, strength, form and deliberately pasted public text are submitted.
There is no Member/Med serialization and no access to family names, weight,
allergies, prescriptions, stock, dates, notes or reminders. The source URL stays
local. The user must ensure their pasted text is public and contains no health
records. No clipboard, document or camera data is automatically submitted.

AI locates original-language **verbatim passages**, not free-form dosing advice.
Every returned quote is checked against the source (whitespace normalization
only); any unsupported quote or mismatched identity rejects the entire draft.
The name, strength and form must also occur with word boundaries in the source
before a network request. Matching is intentionally conservative: spelling or
inflection differences may require correcting the editor or source text.

Passage containment does not prove clinical correctness, completeness, document
authenticity, absence of omitted contraindications, or correct classification.
UI explicitly requires comparison with the complete leaflet. A source URL is
user-supplied attribution, **not** proof it was fetched or verified by MediBox.
The entire pasted source is not retained after closing the import screen.

Selected passages and their source, model, identity and user-approval time are
saved as a separate optional `leafletRecord`. Existing manual fields, doctor
instructions and `registryVerified` stay unchanged. Changing medicine identity
invalidates this record at save; nonmatching records are hidden in the card.
No selected passages means no apply. Back/cancel never saves the medicine.

## Not implemented in this increment

Automatic leaflet discovery/download/PDF extraction; vaistai.lt scraping or mass
catalog ingestion; clinician validation; personalized dosing; Firebase Auth,
Firestore sync; live symptom assessment; iOS Firebase setup; production signing.
Missing extracts are marked missing, not treated as evidence of no risks.

## Checks

`flutter analyze` and `flutter test` in `ai-checks.yml` (no Android/iOS build).
Tests cover config identity, hallucinated quotes, identity/strength mismatch,
invalid inputs, duplicate/unknown fields, explicit approval, service failure,
legacy JSON and preserving manual medicine fields. A live signed-device App
Check/inference test remains necessary before calling the AI feature operational.
