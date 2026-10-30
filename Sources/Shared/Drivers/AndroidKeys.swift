import Foundation

/// Android key codes, shared by Google TV and Fire TV.
enum AndroidKeys {
    static func code(for key: RemoteKey) -> Int {
        switch key {
        case .power: 26
        case .home: 3
        case .back: 4
        case .input: 178
        case .up: 19
        case .down: 20
        case .left: 21
        case .right: 22
        case .ok: 23
        case .volumeUp: 24
        case .volumeDown: 25
        case .mute: 164
        case .channelUp: 166
        case .channelDown: 167
        case .playPause: 85
        case .tv: 170
        case .nextHDMI: 178
        case .hdmi1: 243
        case .hdmi2: 244
        case .hdmi3: 245
        case .hdmi4: 246
        case .settings: 176
        case .search: 84
        case .exit: 4 // Android TV has no exit key; Back closes menus
        }
    }

    /// Characters that can be typed with key events (lowercase letters, digits, common symbols).
    static let typing: [Character: Int] = {
        var map: [Character: Int] = [" ": 62, ".": 56, ",": 55, "-": 69, "@": 77, "'": 75, "/": 76]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { map[c] = 29 + i }
        for (i, c) in "0123456789".enumerated() { map[c] = 7 + i }
        return map
    }()
}
