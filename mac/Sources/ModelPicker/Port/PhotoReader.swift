import Foundation

extension FileTools2 {
    /// Local Photo Reader (OpenAI-compatible) at 127.0.0.1:8093. Never leaves this Mac.
    static func askPhotoReader(path rawPath: String, question rawQuestion: String) async -> String {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return "Missing question." }
        switch resolve(rawPath) {
        case .failure(let reason):
            return refusal(reason)
        case .success(let path):
            return await PhotoAsk.send(path: path, question: question)
        }
    }
}

private enum PhotoAsk {
    private static let chatURL = URL(string: "http://127.0.0.1:8093/v1/chat/completions")!
    private static let modelsURL = URL(string: "http://127.0.0.1:8093/v1/models")!
    private static let maxBytes = 20 * 1024 * 1024
    private static let offline = "Photo Reader is offline. Open it on this Mac (127.0.0.1:8093) and try again."

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func send(path: String, question: String) async -> String {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return "No file at \(path)."
        }
        guard !isDirectory.boolValue else { return "\(path) is a folder, not an image." }
        guard let mime = mimeType(path) else {
            return "That file isn't an image Photo Reader can take. Use a jpg, png, heic, gif, webp, or tiff."
        }
        if let size = fileByteCount(path), size > maxBytes {
            return "That image is too large to send to Photo Reader."
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return "Couldn't read that image."
        }
        if bytes.isEmpty { return "That image is empty." }
        if bytes.count > maxBytes { return "That image is too large to send to Photo Reader." }

        let model: String
        switch await modelName() {
        case .failure(let message):
            return message
        case .success(let name):
            model = name
        }
        return await complete(model: model, mime: mime, image: bytes, question: question, path: path)
    }

    private static func modelName() async -> Result<String, String> {
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
               let id = firstModelID(data) {
                return .success(id)
            }
            return .success("local")
        } catch {
            return .failure(transportMessage(error))
        }
    }

    private static func complete(model: String, mime: String, image: Data, question: String, path: String) async -> String {
        let dataURL = "data:\(mime);base64,\(image.base64EncodedString())"
        let content: [[String: Any]] = [
            ["type": "text", "text": question],
            ["type": "image_url", "image_url": ["url": dataURL]]
        ]
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "max_tokens": 512,
            "messages": [
                [
                    "role": "user",
                    "content": content
                ] as [String: Any]
            ]
        ]
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return "Couldn't send that image to Photo Reader."
        }
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return transportMessage(error)
        }
        guard let http = response as? HTTPURLResponse else {
            return "Photo Reader sent a reply I couldn't read."
        }
        guard (200 ... 299).contains(http.statusCode) else {
            if let message = serverMessage(data) {
                return "Photo Reader couldn't answer (HTTP \(http.statusCode)): \(message)"
            }
            return "Photo Reader couldn't answer (HTTP \(http.statusCode))."
        }
        guard let text = replyText(data) else {
            if let message = serverMessage(data) {
                return "Photo Reader couldn't answer: \(message)"
            }
            return "Photo Reader sent a reply I couldn't read."
        }
        if text.isEmpty { return "Photo Reader returned an empty reply." }
        return "\(path)\n\(text)"
    }

    private static func mimeType(_ path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return nil
        }
    }

    private static func fileByteCount(_ path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attrs[.size] as? NSNumber
        else { return nil }
        return number.intValue
    }

    private static func firstModelID(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rows: [Any]
        if let root = json as? [String: Any] {
            rows = root["data"] as? [Any] ?? []
        } else if let array = json as? [Any] {
            rows = array
        } else {
            return nil
        }
        for row in rows {
            if let id = row as? String {
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let object = row as? [String: Any], let id = object["id"] as? String {
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func replyText(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let choices = root["choices"] as? [Any], let first = choices.first as? [String: Any] else {
            return nil
        }
        if let message = first["message"] as? [String: Any] {
            return contentText(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = first["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func contentText(_ value: Any?) -> String {
        if value == nil || value is NSNull { return "" }
        if let text = value as? String { return text }
        guard let parts = value as? [Any] else { return "" }
        return parts.compactMap { part -> String? in
            if let text = part as? String { return text }
            return (part as? [String: Any])?["text"] as? String
        }.joined()
    }

    private static func serverMessage(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let raw: String?
        if let error = root["error"] as? [String: Any] {
            raw = error["message"] as? String
        } else if let error = root["error"] as? String {
            raw = error
        } else {
            raw = root["message"] as? String
        }
        guard let raw else { return nil }
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.isEmpty { return nil }
        if oneLine.count <= 180 { return oneLine }
        return String(oneLine.prefix(180))
    }

    private static func transportMessage(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled." }
        guard let urlError = error as? URLError else { return offline }
        if urlError.code == .cancelled { return "Cancelled." }
        if urlError.code == .timedOut { return "Photo Reader took too long to answer." }
        return offline
    }
}

extension String: @retroactive Error {}
