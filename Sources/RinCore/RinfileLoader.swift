import Foundation

enum RinfileLoaderError: Error, LocalizedError {
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Rinfile.swift not found at \(path)."
        }
    }
}

struct RinfileLoader {
    private let decoder: RinfileSyntaxDecoder

    init(decoder: RinfileSyntaxDecoder = .init()) {
        self.decoder = decoder
    }

    func load(at url: URL) throws -> RinPolicy {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RinfileLoaderError.fileNotFound(url.path)
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        return try decoder.decode(source: source)
    }
}
