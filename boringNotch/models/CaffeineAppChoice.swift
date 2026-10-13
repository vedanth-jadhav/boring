import AppKit

struct CaffeineAppChoice: Identifiable {
    let id: String
    let name: String
    let url: URL
    let icon: NSImage
    let running: Bool
    let alwaysOn: Bool
}
