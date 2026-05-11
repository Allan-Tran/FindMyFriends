import Foundation

struct KalmanFilter {
    private(set) var estimate: Double
    private var errorEstimate: Double
    private let processNoise: Double
    private let measurementNoise: Double

    init(initial: Double, processNoise: Double = 0.5, measurementNoise: Double = 4.0) {
        self.estimate = initial
        self.errorEstimate = 1.0
        self.processNoise = processNoise
        self.measurementNoise = measurementNoise
    }

    mutating func update(_ measurement: Double) -> Double {
        errorEstimate += processNoise
        let gain = errorEstimate / (errorEstimate + measurementNoise)
        estimate += gain * (measurement - estimate)
        errorEstimate *= (1.0 - gain)
        return estimate
    }
}

enum RSSIDistance {
    static func meters(fromRssi rssi: Double, txPower: Double = -59.0) -> Double {
        let ratio = rssi / txPower
        if ratio < 1.0 {
            return pow(ratio, 10.0)
        }
        return 0.89976 * pow(ratio, 7.7095) + 0.111
    }
}
