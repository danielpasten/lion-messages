import Foundation
import MessagesModel

/// Sends messages by scripting Messages.app. All NSAppleScript use happens on one dedicated
/// serial queue (NSAppleScript is not thread-safe).
final class MessageSender: @unchecked Sendable {
    /// Outcome of running one script: nil on success, otherwise (error number, safe message).
    typealias ScriptRunner = (String) -> (number: Int, message: String)?

    private let queue = DispatchQueue(label: "LionMessages.applescript", qos: .userInitiated)
    private let runScript: ScriptRunner

    init(runner: @escaping ScriptRunner = MessageSender.runAppleScript) {
        runScript = runner
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

    static func sendToParticipant(text: String, handle: String, useSMS: Bool) -> String {
        """
        tell application "Messages"
        set targetService to 1st account whose service type = \(useSMS ? "SMS" : "iMessage")
        send "\(escape(text))" to participant "\(escape(handle))" of targetService
        end tell
        """
    }
}
