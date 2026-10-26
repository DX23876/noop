#if !canImport(Combine)
/// The shared journal and caffeine stores publish state for SwiftUI on Apple. Android reads them through JNI.
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif
