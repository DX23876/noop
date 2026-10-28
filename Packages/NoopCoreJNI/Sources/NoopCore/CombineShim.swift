#if !canImport(Combine)
/// The shared journal and caffeine stores publish state for SwiftUI on Apple. Android reads them through JNI.
public protocol ObservableObject: AnyObject {}

/// `objectWillChange.send()` is a no-op here: nothing on Android observes the stores through Combine.
public struct ObservableObjectPublisher {
    public init() {}
    public func send() {}
}

extension ObservableObject {
    public var objectWillChange: ObservableObjectPublisher { ObservableObjectPublisher() }
}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif
