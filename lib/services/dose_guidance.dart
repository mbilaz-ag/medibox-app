import '../models/models.dart';

class DoseGuidance {
  final double doseMg;
  final double? volumeMl;
  final double? units;
  final double? maxDailyMg;
  final double? intervalHours;
  final String source;

  const DoseGuidance({
    required this.doseMg,
    required this.source,
    this.volumeMl,
    this.units,
    this.maxDailyMg,
    this.intervalHours,
  });
}

double? _number(String value) =>
    double.tryParse(value.trim().replaceAll(',', '.'));

/// Calculates only from an explicitly approved structured leaflet rule.
/// Gemini/free text is never evaluated as a formula.
DoseGuidance? calculateDoseGuidance(Med medicine, Member member) {
  if (!medicine.doseRuleVerified || medicine.doseRuleSource.trim().isEmpty) {
    return null;
  }
  final weight = _number(member.weight);
  final perKg = _number(medicine.doseMgPerKg);
  final fixed = _number(medicine.doseFixedMg);
  if (perKg == null && fixed == null) return null;
  if (perKg != null && (weight == null || weight <= 0)) return null;

  var dose = perKg != null ? perKg * weight! : fixed!;
  final maxSingle = _number(medicine.doseMaxSingleMg);
  if (maxSingle != null && maxSingle > 0 && dose > maxSingle) {
    dose = maxSingle;
  }
  if (!dose.isFinite || dose <= 0) return null;

  final concentration = _number(medicine.concentrationMgPerMl);
  final unitStrength = _number(medicine.unitStrengthMg);
  return DoseGuidance(
    doseMg: dose,
    volumeMl: concentration != null && concentration > 0
        ? dose / concentration
        : null,
    units: unitStrength != null && unitStrength > 0
        ? dose / unitStrength
        : null,
    maxDailyMg: _number(medicine.doseMaxDailyMg),
    intervalHours: _number(medicine.doseIntervalHours),
    source: medicine.doseRuleSource.trim(),
  );
}
