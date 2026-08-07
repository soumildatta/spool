import Foundation

enum LLMError: LocalizedError {
    case badURL(String)
    case unreachable(String)
    case httpError(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .badURL(let url):
            return "\"\(url)\" isn't a valid server URL. Check Settings."
        case .unreachable(let url):
            return "Couldn't reach the model server at \(url).\n\nMake sure Ollama is running (`brew services start ollama`), or that whichever server is set in Settings is up."
        case .httpError(let code, let body):
            return "The model server returned an error (HTTP \(code)):\n\(body.prefix(300))"
        case .emptyResponse:
            return "The model returned an empty response. Check that the model name in Settings matches one loaded on the server."
        }
    }
}

enum LLMProgress {
    case loadingModel     // request sent, nothing back yet, model still loading
    case thinking         // reasoning tokens streaming, nothing visible yet
    case writing(Int)     // visible characters written so far
}

struct LLMClient {
    let config: Config

    func structure(_ raw: String, onProgress: @escaping (LLMProgress) -> Void) async throws -> String {
        let base = config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard let url = URL(string: base + "/chat/completions"), url.host != nil else {
            throw LLMError.badURL(config.serverURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "temperature": 0.7,
            "messages": [
                ["role": "system", "content": Prompt.system],
                ["role": "user", "content": raw],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 600      // idle gap between bytes
        sessionConfig.timeoutIntervalForResource = 3600    // whole generation, start to finish
        let session = URLSession(configuration: sessionConfig)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw LLMError.unreachable(base)
        }

        guard let http = response as? HTTPURLResponse else { throw LLMError.unreachable(base) }
        guard http.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 500 { break }
            }
            throw LLMError.httpError(http.statusCode, errorBody)
        }

        var output = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any]
            else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                output += content
            }
            // reasoning models stream their thinking inside a <think> block
            // before any visible output shows up
            let insideThinkBlock = output.contains("<think>") && !output.contains("</think>")
            let visible = insideThinkBlock ? 0 : Self.cleaned(output).count
            if visible > 0 {
                onProgress(.writing(visible))
            } else {
                onProgress(.thinking)
            }
        }

        let cleaned = Self.cleaned(output)
        guard !cleaned.isEmpty else { throw LLMError.emptyResponse }
        return cleaned
    }

    /// strips reasoning tags (qwen-style <think> blocks) and stray code fences
    static func cleaned(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>"),
              let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            var lines = result.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
