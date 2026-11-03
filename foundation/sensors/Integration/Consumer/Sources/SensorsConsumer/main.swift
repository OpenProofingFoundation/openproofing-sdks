import Foundation
import KenshikiSensors

enum ConsumerFailure: Error {
  case assertion(String)
}

func require(_ condition: Bool, _ name: String) throws {
  guard condition else { throw ConsumerFailure.assertion(name) }
}

let anchor = SensorClockAnchor(
  sensorTimestamp: 0, wallClock: Date(timeIntervalSince1970: 1_700_000_000))
var window = TumblingSensorWindow<DeviceMotionWindowReducer>(
  sourceSessionID: SensorSourceSessionID(rawValue: "external-consumer-fixture"),
  clockAnchor: anchor,
  specification: SensorWindowSpecification(duration: 4, nominalPeriod: 1)
)

func sample(_ timestamp: Double) -> TimestampedSensorSample<DeviceMotionAggregateSample> {
  TimestampedSensorSample(
    sensorTimestamp: timestamp,
    receivedAt: anchor.wallClockDate(for: timestamp + 0.125),
    systemUptimeAtReceipt: timestamp + 0.125,
    value: DeviceMotionAggregateSample(
      userAcceleration: SensorVector3(x: timestamp + 0.5, y: 0, z: 0),
      rotationRate: SensorVector3(x: 0, y: 0, z: 2),
      gravity: SensorVector3(x: 0, y: 0, z: -1),
      attitudeReferenceFrame: "fixture-frame",
      magneticCalibrationAccuracy: "fixture-calibration",
      sensorLocation: "fixture-device"
    )
  )
}

for timestamp in 0..<4 {
  try require(window.ingest(sample(Double(timestamp) + 0.5)) == nil, "premature-close")
}
guard let completed = window.ingest(sample(4)), let values = completed.measurements else {
  throw ConsumerFailure.assertion("missing-completed-window")
}
try require(completed.monotonicBounds == 0..<4, "half-open-bounds")
try require(
  completed.timing.sampleCount == 4 && completed.timing.acquisitionQuality == .observed,
  "observed-window")
try require(completed.timing.temporalCoverageFraction == 1, "complete-coverage")
try require(values.userAccelerationMagnitudeG.median == 2.5, "r7-median")
try require(abs(values.userAccelerationMagnitudeG.rootMeanSquare - sqrt(7.5)) < 1e-12, "rms")
guard let trailing = window.flush(completion: .sourceStopped) else {
  throw ConsumerFailure.assertion("missing-trailing-window")
}
try require(
  trailing.monotonicBounds == 4..<8 && trailing.timing.sampleCount == 1, "half-open-routing")
try require(trailing.timing.acquisitionQuality == .partial, "partial-window")
try require(EmpiricalDistribution(values: [.nan]) == nil, "invalid-distribution-rejected")

print(
  #"""
  {"schemaVersion":1,"consumer":"SensorsConsumer","passed":true,
  "assertions":["observed-window","complete-coverage","r7-median","rms",
  "half-open-routing","partial-window","invalid-distribution-rejected"]}
  """#
)
