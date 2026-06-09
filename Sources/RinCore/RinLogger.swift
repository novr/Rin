import Foundation

protocol RinLogger {
    func info(_ message: String)
    func debug(_ message: String)
    func success(_ message: String)
    func error(_ message: String)
}

struct ConsoleLogger: RinLogger {
    private let verbose: Bool

    init(verbose: Bool) {
        self.verbose = verbose
    }

    func info(_ message: String) {
        print("ℹ️  \(message)")
    }

    func debug(_ message: String) {
        guard verbose else { return }
        print("🔍 \(message)")
    }

    func success(_ message: String) {
        print("✅ \(message)")
    }

    func error(_ message: String) {
        fputs("❌ \(message)\n", stderr)
    }
}
