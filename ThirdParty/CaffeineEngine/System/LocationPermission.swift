import AppKit
@preconcurrency import CoreLocation
import Observation

/// Owns the Location Services authorization used by CoreWLAN for SSID
/// visibility. Constructing this object never prompts; callers request only
/// when a hotspot is configured or an applicable session starts.
@MainActor
@Observable
final class LocationPermission: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var authorizationStatus: CLAuthorizationStatus

    @ObservationIgnored private let manager: CLLocationManager?
    @ObservationIgnored private let requestOverride: (() -> Void)?

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        requestOverride = nil
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Test-only construction without touching the process-wide location
    /// service or presenting a permission prompt.
    init(authorizationStatus: CLAuthorizationStatus, request: @escaping () -> Void = {}) {
        manager = nil
        requestOverride = request
        self.authorizationStatus = authorizationStatus
        super.init()
    }

    /// `.authorizedWhenInUse` is unavailable on macOS: a granted
    /// `requestWhenInUseAuthorization` settles on `.authorizedAlways` here, so
    /// that is the only authorized case to check.
    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool { authorizationStatus == .denied }

    var statusDescription: String {
        switch authorizationStatus {
        case .authorizedAlways: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }

    func requestWhenInUse() {
        if let requestOverride {
            requestOverride()
        } else {
            manager?.requestWhenInUseAuthorization()
        }
    }

    func openLocationServicesSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }
}
