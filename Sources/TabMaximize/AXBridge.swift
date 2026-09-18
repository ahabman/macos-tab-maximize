import ApplicationServices

extension AXError: @retroactive Error {}

/// The only place in the project that touches `CFTypeRef`. Everything above this
/// layer deals in Swift values and `Result`.
enum AX {
    static func copyValue<T>(_ element: AXUIElement, _ attribute: String, as type: T.Type = T.self) -> Result<T, AXError> {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard err == .success else { return .failure(err) }
        guard let value = raw as? T else { return .failure(.noValue) }
        return .success(value)
    }

    @discardableResult
    static func setValue(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    static func setTimeout(_ element: AXUIElement, _ seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    /// Applies to every AX call this process makes. The default is multiple seconds,
    /// which is long enough for one beachballed app to stall the worker queue.
    static func setProcessWideTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }
}

extension AXError {
    var name: String {
        switch self {
        case .success: return "success"
        case .apiDisabled: return "apiDisabled(-25211)"
        case .cannotComplete: return "cannotComplete(-25204)"
        case .notImplemented: return "notImplemented(-25208)"
        case .attributeUnsupported: return "attributeUnsupported(-25205)"
        case .actionUnsupported: return "actionUnsupported"
        case .invalidUIElement: return "invalidUIElement"
        case .noValue: return "noValue"
        case .notEnoughPrecision: return "notEnoughPrecision"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        @unknown default: return "unknown(\(rawValue))"
        }
    }

    /// The app does not speak Accessibility at all — retrying will not help.
    var isTerminalForApp: Bool {
        self == .notImplemented || self == .attributeUnsupported || self == .invalidUIElement
    }
}
