import Foundation

// MARK: - Errors

enum TTSError: LocalizedError {
    case invalidURL
    case requestFailed(statusCode: Int, body: String)
    case invalidResponse
    case decodingError(String)
    case invalidHexData
    case apiError(statusCode: Int, message: String)
    case emptyText
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid TTS API endpoint URL."
        case .requestFailed(let statusCode, let body):
            return "TTS request failed with status \(statusCode): \(body)"
        case .invalidResponse:
            return "Received an invalid response from the TTS server."
        case .decodingError(let detail):
            return "Failed to decode TTS response: \(detail)"
        case .invalidHexData:
            return "Received invalid hex-encoded audio data."
        case .apiError(let statusCode, let message):
            return "MiniMax API error (\(statusCode)): \(message)"
        case .emptyText:
            return "Cannot synthesize empty text."
        case .unauthorized:
            return "Invalid or missing TTS API key."
        }
    }
}

// MARK: - Protocol

protocol TTSServiceProtocol: Sendable {
    func synthesize(text: String, emotion: Emotion) -> AsyncThrowingStream<Data, Error>
}

// MARK: - Implementation

final class TTSService: TTSServiceProtocol, Sendable {
    private let apiKey: String
    private let groupId: String
    private let voiceId: String
    private let model: String
    private let session: URLSession

    init(apiKey: String, groupId: String, voiceId: String = "Chinese (Mandarin)_Crisp_Girl", model: String = "speech-02-turbo") {
        self.apiKey = apiKey
        self.groupId = groupId
        self.voiceId = voiceId
        self.model = model

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    func synthesize(text: String, emotion: Emotion) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continuation.finish(throwing: TTSError.emptyText)
                        return
                    }

                    let request = try buildRequest(text: text, emotion: emotion)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: TTSError.invalidResponse)
                        return
                    }


                    guard httpResponse.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count > 2000 { break }
                        }

                        if httpResponse.statusCode == 401 {
                            continuation.finish(throwing: TTSError.unauthorized)
                        } else {
                            continuation.finish(throwing: TTSError.requestFailed(
                                statusCode: httpResponse.statusCode,
                                body: errorBody
                            ))
                        }
                        return
                    }

                    var lineCount = 0
                    for try await line in bytes.lines {
                        lineCount += 1

                        // // Log first few lines for debugging.
                        // if lineCount <= 3 {
                        //     let preview = line.prefix(200)
                        // }

                        // Skip empty lines.
                        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmedLine.isEmpty else { continue }

                        // Handle non-SSE error responses (plain JSON without "data:" prefix).
                        if trimmedLine.hasPrefix("{"), !trimmedLine.hasPrefix("data:") {
                            if let jsonData = trimmedLine.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let baseResp = json["base_resp"] as? [String: Any],
                               let statusCode = baseResp["status_code"] as? Int,
                               statusCode != 0 {
                                let message = baseResp["status_msg"] as? String ?? "Unknown error"
                                continuation.finish(throwing: TTSError.apiError(
                                    statusCode: statusCode,
                                    message: message
                                ))
                                return
                            }
                            continue
                        }

                        // Skip non-SSE lines.
                        guard trimmedLine.hasPrefix("data:") else { continue }

                        // Handle both "data: {...}" and "data:{...}" formats.
                        let payload: String
                        if line.hasPrefix("data: ") {
                            payload = String(line.dropFirst(6))
                        } else {
                            payload = String(line.dropFirst(5))
                        }

                        guard let jsonData = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                            continue
                        }

                        // Check for API-level errors in base_resp.
                        if let baseResp = json["base_resp"] as? [String: Any],
                           let statusCode = baseResp["status_code"] as? Int,
                           statusCode != 0 {
                            let message = baseResp["status_msg"] as? String ?? "Unknown error"
                            continuation.finish(throwing: TTSError.apiError(
                                statusCode: statusCode,
                                message: message
                            ))
                            return
                        }

                        // MiniMax streaming T2A v2 sends incremental audio chunks, then
                        // a final event containing the COMPLETE audio. The final event
                        // has "extra_info" at the top level. Skip it to avoid doubling.
                        if json["extra_info"] != nil {
                            continue
                        }

                        // Extract hex-encoded audio from data.audio.
                        guard let dataObject = json["data"] as? [String: Any],
                              let hexString = dataObject["audio"] as? String else {
                            continue
                        }

                        // Skip empty audio chunks (final event may have empty audio).
                        guard !hexString.isEmpty else { continue }

                        // Decode hex string to raw MP3 bytes.
                        guard let audioData = Data(hexString: hexString) else {
                            continuation.finish(throwing: TTSError.invalidHexData)
                            return
                        }

                        continuation.yield(audioData)
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private Helpers

    private func buildRequest(text: String, emotion: Emotion) throws -> URLRequest {
        let urlString = "https://api.minimax.io/v1/t2a_v2"
        guard let url = URL(string: urlString) else {
            throw TTSError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Build voice_setting.
        var voiceSetting: [String: Any] = [
            "voice_id": voiceId,
            "speed": 1.0
        ]

        // When an emotion category is available, add timber_weights for emotional voice.
        if emotion.ttsEmotionCategory != nil {
            voiceSetting["timber_weights"] = [
                ["timber_id": voiceId, "weight": 100]
            ]
        }

        let body: [String: Any] = [
            "model": model,
            "text": text,
            "stream": true,
            "voice_setting": voiceSetting,
            "audio_setting": [
                "sample_rate": 32000,
                "bitrate": 128000,
                "format": "mp3"
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

// MARK: - Hex Decoding

extension Data {
    /// Initialize Data from a hex-encoded string (e.g., "48656c6c6f" -> bytes for "Hello").
    /// Returns nil if the string contains invalid hex characters or has an odd length.
    init?(hexString: String) {
        let chars = Array(hexString)
        let length = chars.count

        // Hex string must have even length.
        guard length % 2 == 0 else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(length / 2)

        var index = 0
        while index < length {
            guard let high = chars[index].hexDigitValue,
                  let low = chars[index + 1].hexDigitValue else {
                return nil
            }
            bytes.append(UInt8(high << 4 | low))
            index += 2
        }

        self.init(bytes)
    }
}

private extension Character {
    /// Convert a single hex character to its integer value (0-15), or nil if invalid.
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(asciiValue! - Character("0").asciiValue!)
        case "a"..."f": return Int(asciiValue! - Character("a").asciiValue!) + 10
        case "A"..."F": return Int(asciiValue! - Character("A").asciiValue!) + 10
        default: return nil
        }
    }
}
