//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import StreamCore

/// The form a component is placed in, when its format has forms: the component can hold one of
/// its fields, such as a day and time picked on a calendar, so the form sends and checks it with
/// the fields the format draws itself.
@available(iOS 15.0, macOS 12.0, *)
@MainActor
public struct AIUIForm {
    private let read: @MainActor (String) -> RawJSON?
    private let write: @MainActor (String, RawJSON?) -> Void
    private let mark: @MainActor (String, Bool) -> Void
    private let problem: @MainActor (String) -> String?

    /// - Parameters:
    ///   - value: The field's value, or `nil` when it has none.
    ///   - setValue: Stores the field's value, `nil` clearing it.
    ///   - setRequired: Whether the form can be sent without the field.
    ///   - error: Why the field stops the form being sent, after the person tried to.
    public init(
        value: @escaping @MainActor (String) -> RawJSON?,
        setValue: @escaping @MainActor (String, RawJSON?) -> Void,
        setRequired: @escaping @MainActor (String, Bool) -> Void,
        error: @escaping @MainActor (String) -> String?
    ) {
        read = value
        write = setValue
        mark = setRequired
        problem = error
    }

    /// The field's value, or `nil` when it has none.
    public func value(_ name: String) -> RawJSON? {
        read(name)
    }

    /// Stores the field's value; `nil` clears it.
    public func setValue(_ value: RawJSON?, for name: String) {
        write(name, value)
    }

    /// Makes the form refuse to send while the field is empty, or lifts that.
    public func setRequired(_ name: String, _ required: Bool = true) {
        mark(name, required)
    }

    /// Why the field stops the form being sent, after the person tried to send it.
    public func error(_ name: String) -> String? {
        problem(name)
    }
}
