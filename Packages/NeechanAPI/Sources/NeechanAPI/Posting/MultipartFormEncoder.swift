import Foundation

/// Builds `multipart/form-data` bodies.
///
/// 2ch takes posts, reports and searches as multipart forms, including repeated
/// `file[]` parts, which `URLComponents` cannot express.
public struct MultipartFormEncoder: Sendable {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Adds a plain text field. Repeat a name to send an array.
    public mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(escape(name))\"\r\n\r\n")
        append("\(value)\r\n")
    }

    /// Adds a file part.
    public mutating func addFile(
        _ name: String,
        fileName: String,
        mimeType: String,
        data: Data
    ) {
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"\(escape(name))\"; "
                + "filename=\"\(escape(fileName))\"\r\n"
        )
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    /// Closes the form and returns the body. Call once.
    public func finalizedBody() -> Data {
        var finished = body
        finished.append(Data("--\(boundary)--\r\n".utf8))
        return finished
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }

    /// Quotes inside a header parameter would end the value early.
    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
