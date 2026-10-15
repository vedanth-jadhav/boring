// Native-client artifact parsing adapted from steipete/CodexBar (MIT).
// Copyright (c) 2026 Peter Steinberger. License in THIRD_PARTY_LICENSES.
import Foundation

enum AntigravityOAuthClientDiscovery {
    static let consumerClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"

    static func secret() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            "/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            "/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
            home.appendingPathComponent(".local/bin/agy").path, "/opt/homebrew/bin/agy", "/usr/local/bin/agy"
        ]
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  let secret = secretFromBinary(data) else { continue }
            return secret
        }
        throw AccountFailure.missingCLI
    }

    static func secretFromBinary(_ data: Data) -> String? {
        func word(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
        }
        guard data.count >= 32, word(0) == 0xFEED_FACF,
              [0x0100_000C, 0x0100_0007].contains(word(4)),
              Int(word(20)) <= data.count - 32 else { return nil }
        let commandsEnd = 32 + Int(word(20))
        var command = 32
        for _ in 0..<min(word(16), 4096) {
            guard command <= commandsEnd - 8 else { return nil }
            let size = Int(word(command + 4))
            guard size >= 8, size <= commandsEnd - command else { return nil }
            defer { command += size }
            guard word(command) == 0x19, size >= 72,
                  data[command + 8..<command + 24].starts(with: Data("__TEXT\0".utf8)),
                  word(command + 24) & 4095 == 0,
                  word(command + 40) == 0, word(command + 44) == 0,
                  word(command + 52) == 0,
                  Int(word(command + 48)) <= data.count else { continue }
            let textEnd = Int(word(command + 48))
            let sections = Int(word(command + 64))
            guard sections <= (size - 72) / 80 else { return nil }
            for index in 0..<sections {
                let section = command + 72 + index * 80
                guard data[section..<section + 16].starts(with: Data("__text\0".utf8)),
                      word(section + 44) == 0 else { continue }
                let start = Int(word(section + 48))
                let length = Int(word(section + 40))
                guard start >= commandsEnd, start <= textEnd, length <= textEnd - start else { return nil }
                let intel = word(4) == 0x0100_0007
                let marker = Data(intel ? [0x48, 0xC7, 0x40, 0x08] : [0x01, 0x08, 0x00, 0xA9])
                var range = start..<(start + length)
                while let match = data.range(of: marker, in: range) {
                    range = match.upperBound..<range.upperBound
                    let record = match.lowerBound - (intel ? 0 : 12)
                    guard record >= start, record <= start + length - (intel ? 37 : 32) else { continue }
                    /// __TEXT has an aligned VM base and file offset 0,
                    /// so PC-relative addresses map to file offsets.
                    func reference(_ offset: Int) -> (Int, Int)? {
                        if intel {
                            guard word(offset) & 0x00FF_FFFF == 0x000D_8D48 else { return nil }
                            return (offset + 7 + Int(Int32(bitPattern: word(offset + 3))), 0)
                        }
                        let page = word(offset)
                        let add = word(offset + 4)
                        let count = word(offset + 8)
                        guard offset % 4 == 0, page & 0x9F00_001F == 0x9000_0001,
                              add & 0xFFC0_03FF == 0x9100_0021,
                              count & 0xFFE0_001F == 0xD280_0002 else { return nil }
                        let immediate = ((page >> 5) & 0x7FFFF) << 2 | ((page >> 29) & 3)
                        let pages = Int(Int32(bitPattern: immediate << 11) >> 11)
                        return (
                            (offset & ~4095) + pages * 4096 + Int((add >> 10) & 4095),
                            Int((count >> 5) & 0xFFFF))
                    }
                    let id: (Int, Int)
                    let secret: (Int, Int)
                    if intel {
                        guard let idRef = reference(record + 8), let secretRef = reference(record + 26),
                              data[record + 15..<record + 22] == Data([0x48, 0x89, 0x08, 0x48, 0xC7, 0x40, 0x18]),
                              word(record + 33) == 0x1048_8948 else { continue }
                        id = (idRef.0, Int(word(record + 4)))
                        secret = (secretRef.0, Int(word(record + 22)))
                    } else {
                        guard let idRef = reference(record), let secretRef = reference(record + 16),
                              word(record + 28) == 0xA901_0801 else { continue }
                        id = idRef
                        secret = secretRef
                    }
                    guard (30...256).contains(id.1), secret.1 == 35,
                          id.0 >= commandsEnd, id.0 <= textEnd - id.1,
                          secret.0 >= commandsEnd, secret.0 <= textEnd - secret.1,
                          let clientID = String(data: data[id.0..<id.0 + id.1], encoding: .ascii),
                          let clientSecret = String(data: data[secret.0..<secret.0 + secret.1], encoding: .ascii),
                          clientID.range(
                              of: #"^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#,
                              options: .regularExpression) != nil,
                          clientSecret.range(
                              of: #"^GOCSPX-[A-Za-z0-9_-]{28}$"#,
                              options: .regularExpression) != nil else { continue }
                    if clientID == Self.consumerClientID { return clientSecret }
                }
            }
        }
        return nil
    }
}
