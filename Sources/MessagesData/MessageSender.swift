import Foundation
import MessagesModel

/// Sends messages by scripting Messages.app. All NSAppleScript use happens on one dedicated
/// serial queue (NSAppleScript is not thread-safe).
final class MessageSender: @unchecked Sendable {
    /// Outcome of running one script: nil on success, otherwise (error number, safe message).
    typealias ScriptRunner = (String) -> (number: Int, message: String)?

    private let queue = DispatchQueue(label: "LionMessages.applescript", qos: .userInitiated)
    private let runScript: ScriptRunner
    let outbox: AttachmentOutbox

    init(runner: @escaping ScriptRunner = MessageSender.runAppleScript,
         outbox: AttachmentOutbox = AttachmentOutbox()) {
        runScript = runner
        self.outbox = outbox
    }

    func send(_ text: String, to conversation: Conversation) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw SendError.scriptFailed("Message is empty.") }
        // Send exactly what the user typed (minus surrounding whitespace).
        let result: Result<Void, SendError> = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.sendSync(body, to: conversation)) }
        }
        if case .failure(let error) = result {
            dataLog.error("send failed: \(String(describing: error.errorCode), privacy: .public)")
            throw error
        }
        dataLog.info("message sent")
    }

    private func sendSync(_ text: String, to conversation: Conversation) -> Result<Void, SendError> {
        guard var failure = runScript(AppleScriptBuilder.sendToChat(text: text, chatGUID: conversation.guid)) else {
            return .success(())
        }
        if !Self.isPermissionError(failure.number), !conversation.isGroup {
            let handle = conversation.participantHandles.first ?? conversation.chatIdentifier
            if !handle.isEmpty {
                let script = AppleScriptBuilder.sendToParticipant(
                    text: text, handle: handle, useSMS: Self.usesSMSAccount(conversation.serviceName))
                guard let second = runScript(script) else { return .success(()) }
                failure = second
            }
        }
        if Self.isPermissionError(failure.number) { return .failure(.automationDenied) }
        return .failure(.scriptFailed(failure.message))
    }

    /// Sends the files first, in order, then the text (if not blank). Files first matches what
    /// Messages itself does when a picture and a caption are sent together (the caption arrives
    /// under the picture). Each file is checked before anything runs, then copied into the
    /// outbox (see `AttachmentOutbox`) and the copy is sent.
    func send(attachments: [URL], text: String, to conversation: Conversation) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else {
            try await send(body, to: conversation)
            return
        }
        try AttachmentOutbox.validate(attachments)
        let result: Result<Void, SendError> = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.sendItemsSync(attachments, text: body, to: conversation)) }
        }
        if case .failure(let error) = result {
            dataLog.error("attachment send failed: \(String(describing: error.errorCode), privacy: .public)")
            throw error
        }
        dataLog.info("attachments sent: \(attachments.count, privacy: .public)")
    }

    private enum Payload {
        case text(String)
        case file(String)
    }

    private func sendItemsSync(_ files: [URL], text: String, to conversation: Conversation) -> Result<Void, SendError> {
        var payloads: [Payload] = []
        for url in files {
            do { payloads.append(.file(try outbox.stage(url).path)) } catch {
                return .failure(error as? SendError ?? .scriptFailed("“\(url.lastPathComponent)” couldn’t be prepared for sending."))
            }
        }
        if !text.isEmpty { payloads.append(.text(text)) }
        // Once the participant fallback was needed, use it for the remaining items too.
        var useParticipant = false
        for (index, payload) in payloads.enumerated() {
            switch sendOne(payload, to: conversation, preferParticipant: useParticipant) {
            case .success(let viaParticipant):
                useParticipant = useParticipant || viaParticipant
            case .failure(let error):
                guard index > 0, case .scriptFailed(let message) = error else { return .failure(error) }
                let note = index == 1 ? "1 item was sent before the error." : "\(index) items were sent before the error."
                return .failure(.scriptFailed(message + " " + note))
            }
        }
        return .success(())
    }

    /// Success carries whether the participant fallback delivered it.
    private func sendOne(_ payload: Payload, to conversation: Conversation,
                         preferParticipant: Bool) -> Result<Bool, SendError> {
        let handle = conversation.participantHandles.first ?? conversation.chatIdentifier
        let canFallBack = !conversation.isGroup && !handle.isEmpty
        let useSMS = Self.usesSMSAccount(conversation.serviceName)
        func chatScript() -> String {
            switch payload {
            case .text(let t): return AppleScriptBuilder.sendToChat(text: t, chatGUID: conversation.guid)
            case .file(let p): return AppleScriptBuilder.sendFileToChat(path: p, chatGUID: conversation.guid)
            }
        }
        func participantScript() -> String {
            switch payload {
            case .text(let t): return AppleScriptBuilder.sendToParticipant(text: t, handle: handle, useSMS: useSMS)
            case .file(let p): return AppleScriptBuilder.sendFileToParticipant(path: p, handle: handle, useSMS: useSMS)
            }
        }
        if preferParticipant && canFallBack {
            guard let failure = runScript(participantScript()) else { return .success(true) }
            return .failure(Self.map(failure))
        }
        guard var failure = runScript(chatScript()) else { return .success(false) }
        if !Self.isPermissionError(failure.number), canFallBack {
            guard let second = runScript(participantScript()) else { return .success(true) }
            failure = second
        }
        return .failure(Self.map(failure))
    }

    private static func map(_ failure: (number: Int, message: String)) -> SendError {
        isPermissionError(failure.number) ? .automationDenied : .scriptFailed(failure.message)
    }

    /// SMS, RCS and SatelliteSMS chats go through the SMS (text forwarding) account; everything
    /// else (iMessage, iMessageLite, unknown) through iMessage. chat.guid prefixes ("any;-;…") are
    /// never parsed: the guid is passed to `chat id` verbatim.
    static func usesSMSAccount(_ serviceName: String) -> Bool {
        let s = serviceName.uppercased()
        return s.contains("SMS") || s.contains("RCS")
    }

    static func isPermissionError(_ number: Int) -> Bool { number == -1743 || number == -1744 }

    /// Executes AppleScript source for real. Only ever called from `queue`.
    static func runAppleScript(_ source: String) -> (number: Int, message: String)? {
        guard let script = NSAppleScript(source: source) else {
            return (-1, "Could not create the AppleScript.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
        let message = (errorInfo[NSAppleScript.errorMessage] as? String)
            ?? (errorInfo[NSAppleScript.errorBriefMessage] as? String)
            ?? "Messages could not send the message (error \(number))."
        return (number, message)
    }
}

private extension SendError {
    var errorCode: String {
        switch self {
        case .automationDenied: return "automationDenied"
        case .scriptFailed: return "scriptFailed"
        }
    }
}

/// Pure AppleScript source generation (unit-tested; never executed in tests).
enum AppleScriptBuilder {
    /// Escapes a value for use inside an AppleScript double-quoted string literal.
    /// Backslash and double quote are escaped; newlines/tabs are left as-is (valid inside literals).
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func sendToChat(text: String, chatGUID: String) -> String {
        "tell application \"Messages\" to send \"\(escape(text))\" to chat id \"\(escape(chatGUID))\""
    }

    /// The file reference is made outside the `tell` block (the usual, most reliable form).
    static func sendFileToChat(path: String, chatGUID: String) -> String {
        """
        set theFile to POSIX file "\(escape(path))"
        tell application "Messages" to send theFile to chat id "\(escape(chatGUID))"
        """
    }

    static func sendFileToParticipant(path: String, handle: String, useSMS: Bool) -> String {
        """
        set theFile to POSIX file "\(escape(path))"
        tell application "Messages"
        set targetService to 1st account whose service type = \(useSMS ? "SMS" : "iMessage")
        send theFile to participant "\(escape(handle))" of targetService
        end tell
        """
    }

    static func sendToParticipant(text: String, handle: String, useSMS: Bool) -> String {
        """
        tell application "Messages"
        set targetService to 1st account whose service type = \(useSMS ? "SMS" : "iMessage")
        send "\(escape(text))" to participant "\(escape(handle))" of targetService
        end tell
        """
    }
}
