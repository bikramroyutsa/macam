import SwiftUI

/// Tiny stand-in for `@State`. The command line tools SDK ships `@State` as a macro whose
/// plugin only exists inside Xcode, so local view state lives in a `@StateObject` box instead.
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
