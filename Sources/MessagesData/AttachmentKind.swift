import Foundation
import MessagesModel
import UniformTypeIdentifiers

/// Classifies attachments from what chat.db recorded: MIME type first, then UTI, then the
/// file extension. Never touches the file.
enum AttachmentKind {
    static func kind(mimeType: String?, uti: String?, path: String?) -> MessageAttachment.Kind {
        if let mime = mimeType?.lowercased(), let kind = fromMIME(mime) { return kind }
        if let uti, !uti.hasPrefix("dyn."), let type = UTType(uti), let kind = fromType(type) { return kind }
        if let path {
            let ext = (path as NSString).pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext), let kind = fromType(type) { return kind }
        }
        return .other
    }

    private static func fromMIME(_ mime: String) -> MessageAttachment.Kind? {
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        return nil
    }

    private static func fromType(_ type: UTType) -> MessageAttachment.Kind? {
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }
}
