//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import StreamCore

/// Keeps the state a reply's UI was left in, such as a form's values, beyond its ``AIUIHost``:
/// on disk, for one, so a half-filled form survives the conversation screen being rebuilt.
@available(iOS 15.0, macOS 12.0, *)
@MainActor
public protocol AIUIStateStore: AnyObject {
    /// The state the reply's UI was last left in, or `nil`.
    func state(for messageID: String) -> RawJSON?
    /// Keeps the reply's state; `nil` forgets it.
    func setState(_ state: RawJSON?, for messageID: String)
}
