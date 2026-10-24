import Foundation

/// Burns CPU on the 4 performance cores at an adjustable duty cycle (0 = idle, 1 = full load).
final class Heater {
    /// Utility QoS runs on the performance cores (efficiency cores make little heat)
    /// but still yields to the apps you are using.
    private static let threadQoS = [QualityOfService](repeating: .utility, count: 4)

    private let lock = NSLock()
    private var _duty = 0.0
    private var generation = 0
    private let period = 0.1 // seconds per on/off cycle

    var duty: Double {
        get { lock.withLock { _duty } }
        set { lock.withLock { _duty = min(max(newValue, 0), 1) } }
    }

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let myGeneration = lock.withLock { generation += 1; return generation }
        for qos in Self.threadQoS {
            let thread = Thread { [weak self] in self?.burn(generation: myGeneration) }
            thread.qualityOfService = qos
            thread.start()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lock.withLock { generation += 1; _duty = 0 }
    }

    private func burn(generation myGeneration: Int) {
        // Four independent vector multiply-adds keep every FP unit busy, which draws far more
        // power (and heat) than one scalar chain. The values settle at 1 and never overflow.
        var a = SIMD16<Float>(repeating: 1), b = a + 1, c = a + 2, d = a + 3
        let m = SIMD16<Float>(repeating: 0.999), k = SIMD16<Float>(repeating: 0.001)
        while true {
            let (duty, current) = lock.withLock { (_duty, generation) }
            if current != myGeneration { break }
            if duty <= 0 {
                Thread.sleep(forTimeInterval: period)
                continue
            }
            let end = Date().addingTimeInterval(period * duty)
            while Date() < end {
                for _ in 0..<10_000 {
                    a = k.addingProduct(a, m); b = k.addingProduct(b, m)
                    c = k.addingProduct(c, m); d = k.addingProduct(d, m)
                }
            }
            if duty < 1 { Thread.sleep(forTimeInterval: period * (1 - duty)) }
        }
        if (a + b + c + d).sum() == 0 { print(a) } // keeps the optimiser from deleting the loop
    }
}
