import Foundation

/// Thread-safe generation tokens for camera actions that may queue behind newer user input.
/// A caller asks for a token, then checks it before applying hardware state. Newer requests of
/// the same kind automatically make older work stale.
final class CaptureRequestGate {
    enum Kind: Hashable {
        case zoom
        case cameraSwitch
        case whiteBalance
        case modeChange
        case recordingStart
    }

    struct Token: Equatable {
        fileprivate let kind: Kind
        fileprivate let generation: UInt64
    }

    private let lock = NSLock()
    private var generations: [Kind: UInt64] = [:]

    func next(_ kind: Kind) -> Token {
        lock.lock()
        defer { lock.unlock() }
        let generation = (generations[kind] ?? 0) &+ 1
        generations[kind] = generation
        return Token(kind: kind, generation: generation)
    }

    func invalidate(_ kind: Kind) {
        _ = next(kind)
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[token.kind] == token.generation
    }
}
