import Foundation

@objc protocol LyricsKeychainProtocol {
    func perform(_ operation: String, value: String?, reply: @escaping (String?, Int32) -> Void)
}
