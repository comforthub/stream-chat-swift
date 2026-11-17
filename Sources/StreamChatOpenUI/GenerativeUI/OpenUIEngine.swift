//
// Copyright © 2026 Stream.io Inc. All rights reserved.
//

import Foundation
import StreamChatAI
import SwiftUI

// The OpenUI replies of one conversation, each with a runtime of its own.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
final class OpenUIEngine: AIUIEngine {
    private weak var host: (any AIUIHosting)?
    private let toolProvider: any OpenUIToolProvider
    private let mediaURL: @Sendable (URL) -> URL?
    private let theme: OpenUITheme?
    private let onError: (@MainActor (OpenUIError, _ messageID: String) -> Void)?
    private(set) var library: ComponentLibrary
    private(set) var runtimes: [String: OpenUIRuntime] = [:]
    private var messageIDs: [ObjectIdentifier: String] = [:]

    init(
        library: ComponentLibrary,
        host: any AIUIHosting,
        toolProvider: any OpenUIToolProvider,
        mediaURL: @escaping @Sendable (URL) -> URL? = { $0 },
        theme: OpenUITheme? = nil,
        onError: (@MainActor (OpenUIError, _ messageID: String) -> Void)? = nil
    ) {
        self.host = host
        self.toolProvider = toolProvider
        self.mediaURL = mediaURL
        self.theme = theme
        self.onError = onError
        self.library = library
        let components = OpenUIRenderer.placeableSchemas(of: host.components, in: library).map { placeable -> OpenUIComponentDefinition in
            let component: any AIUIComponent = placeable.component
            return definition(of: component, schema: placeable.schema)
        }
        self.library = library.withEntrances.addingContent(components)
    }

    func remove(messageID: String) {
        guard let runtime = runtimes.removeValue(forKey: messageID) else { return }
        messageIDs[ObjectIdentifier(runtime)] = nil
        runtime.dispose()
    }

    func view(for document: AIUIDocument, messageID: String) -> OpenUIMessageView? {
        guard let program = document.text else { return nil }
        let runtime = runtimes[messageID] ?? makeRuntime(messageID: messageID, program: program, isStreaming: document.isStreaming)
        return OpenUIMessageView(runtime: runtime, program: program, isStreaming: document.isStreaming, mediaURL: mediaURL, theme: theme)
    }

    // A reply's runtime starts with its program, before any view follows it.
    private func makeRuntime(messageID: String, program: String, isStreaming: Bool) -> OpenUIRuntime {
        let state = host?.state(for: messageID)?.dictionaryValue.map(OpenUIObject.init(rawJSON:))
        let runtime = OpenUIRuntime(library: library, toolProvider: toolProvider, initialState: state)
        runtime.onAction = { [weak self] event in
            self?.handle(event, messageID: messageID)
        }
        runtime.onError = { [weak self] errors in
            self?.report(errors, messageID: messageID)
        }
        runtime.onStateUpdate = { [weak self] state in
            self?.host?.setState(.dictionary(state.withoutSecrets.rawJSON), for: messageID)
        }
        runtimes[messageID] = runtime
        messageIDs[ObjectIdentifier(runtime)] = messageID
        runtime.update(response: program, isStreaming: isStreaming)
        return runtime
    }

    // The problems with a reply's program, for the app, or for the log without its hook.
    private func report(_ errors: [OpenUIError], messageID: String) {
        for error in errors {
            if let onError {
                onError(error, messageID)
            } else {
                log.error("A reply's OpenUI has a problem: \(error.code) \(error.message)")
            }
        }
    }

    // The OpenUI component that shows one of the app's, with the app's view as it is.
    private func definition(of component: some AIUIComponent, schema: ComponentSchema) -> OpenUIComponentDefinition {
        OpenUIComponentDefinition(schema) { [weak self] context in
            self.map { AppComponentView(engine: $0, component: component, context: context) }
        }
    }

    // What one of the app's components gets besides its arguments, while the host is there:
    // inside a `Form`, that form, so the component can hold one of its fields.
    fileprivate func context(
        of component: some AIUIComponent,
        in context: ComponentContext,
        formName: String?,
        validation: FormValidationModel?
    ) -> AIUIComponentContext? {
        guard let host else { return nil }
        let messageID = messageIDs[ObjectIdentifier(context.runtime)] ?? ""
        let name = component.name
        let form = validation.map { validation in
            Self.form(runtime: context.runtime, formName: formName, componentType: name, validation: validation)
        }
        return AIUIComponentContext(messageID: messageID, isStreaming: context.isStreaming, host: host, form: form) { event, label, payload in
            var payload = payload
            payload["component"] = .string(name)
            host.send(AIUIAction(messageID: messageID, format: .openUI, name: event, label: label, payload: payload))
        }
    }

    // The enclosing form, as an app's component reaches it: its values in the reply's state,
    // where the form's own fields keep theirs, and a required field checked when it is sent.
    private static func form(
        runtime: OpenUIRuntime,
        formName: String?,
        componentType: String,
        validation: FormValidationModel
    ) -> AIUIForm {
        AIUIForm(
            value: { name in runtime.fieldValue(formName: formName, name: name)?.rawJSON },
            setValue: { name, value in
                runtime.setFieldValue(formName: formName, componentType: componentType, name: name, value: value?.openUIValue)
                if value != nil { validation.clearError(name) }
            },
            setRequired: { name, required in
                if required {
                    validation.register(name, rules: [ValidationRule(type: "required")]) {
                        runtime.fieldValue(formName: formName, name: name)
                    }
                } else {
                    validation.unregister(name)
                    validation.clearError(name)
                }
            },
            error: { name in validation.error(for: name) }
        )
    }

    func handle(_ event: ActionEvent, messageID: String) {
        guard let host else { return }
        if event.isOpenURL {
            if let url = event.url {
                host.open(url)
            }
            return
        }
        // A step of the library's own is for the device, not the agent, and a chat has nowhere
        // to run it.
        guard !library.customActions.contains(where: { $0.name == event.type }) else {
            log.error("A reply's OpenUI ran the step \(event.type), which only an app's own OpenUI view runs")
            return
        }
        var payload: [String: RawJSON] = [:]
        var params = event.params
        if let context = event.context {
            payload["context"] = context.rawJSON
        }
        params["context"] = nil
        if !params.isEmpty {
            payload["params"] = .dictionary(params.rawJSON)
        }
        // The person's message is the control they tapped; the model's words for it go to the
        // agent only.
        if !event.humanFriendlyMessage.isEmpty, event.humanFriendlyMessage != event.label {
            payload["message"] = .string(event.humanFriendlyMessage)
        }
        // Only the values of the form the action belongs to go to the agent, as the person's next
        // message: outside a form, the action carries none, and a password never.
        if let form = event.formName {
            payload["form"] = .string(form)
            if let values = event.formState?.withoutSecrets, !values.isEmpty {
                payload["values"] = .dictionary(values.rawJSON)
            }
        }
        let label = event.label.isEmpty ? L10n.Action.untitled : event.label
        let action = AIUIAction(messageID: messageID, format: .openUI, name: event.type, label: label, payload: payload)
        // A button that waits on an action for the app tries again when the app refused it.
        host.send(action) { [weak self] in
            self?.runtimes[messageID].map(AppActionLock.release)
        }
    }
}

// One of the app's components, given the form it is placed in.
@available(iOS 17.0, macOS 14.0, *)
private struct AppComponentView<Component: AIUIComponent>: View {
    let engine: OpenUIEngine
    let component: Component
    let context: ComponentContext
    @Environment(\.openUIFormName) private var formName
    @Environment(\.openUIFormValidation) private var validation

    var body: some View {
        engine.context(of: component, in: context, formName: formName, validation: validation).flatMap { componentContext in
            component.view(arguments: context.props.values.rawJSON, context: componentContext)
        }
    }
}
