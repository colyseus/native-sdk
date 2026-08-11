/// How well the client's prediction is tracking the server.
enum DriftStatus {
  /// Corrections are at the rounding floor — the two simulations agree.
  matched,

  /// A spike over an otherwise quiet average: network jitter, not
  /// disagreement.
  jitter,

  /// A persistently non-zero average: the step function no longer matches the
  /// server's, or inputs are being dropped.
  diverging,
}

/// Prediction-error telemetry.
///
/// Each reconcile folds its largest field correction into both numbers. A
/// steady non-zero [ema] means genuine divergence; a [peak] over a quiet [ema]
/// means one bad round trip. [classifyDrift] turns them into a verdict.
class Drift {
  /// Exponential moving average of correction magnitude, in world units.
  final double ema;

  /// Decaying maximum correction magnitude.
  final double peak;

  const Drift(this.ema, this.peak);

  @override
  String toString() =>
      'Drift(ema: ${ema.toStringAsFixed(4)}, peak: ${peak.toStringAsFixed(4)})';
}

/// Classifies [drift] against a world-space [tolerance].
///
/// A Dart port of the C `colyseus_drift_classify`, which is header-only and
/// therefore absent from the generated bindings. Values at or below the floor
/// are float rounding: replay reproduces the server exactly, so real
/// disagreement shows up well above it.
///
/// [tolerance] at or below 1e-3 uses the 1e-3 noise floor.
DriftStatus classifyDrift(Drift drift, {double tolerance = 0}) {
  final floor = tolerance > 1e-3 ? tolerance : 1e-3;
  if (drift.ema >= floor) return DriftStatus.diverging;
  if (drift.peak >= floor) return DriftStatus.jitter;
  return DriftStatus.matched;
}
