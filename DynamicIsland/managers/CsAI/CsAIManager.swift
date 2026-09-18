/*
 * Atoll (DynamicIsland) — csai-atoll fork
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Defaults
import Foundation

struct CsAIMessage: Identifiable, Equatable {
    let id: UUID
    let role: String
    var content: String
    let timestamp: Date

    init(id: UUID = UUID(), role: String, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

@MainActor
final class CsAIManager: ObservableObject {
    static let shared = CsAIManager()

    @Published private(set) var messages: [CsAIMessage] = []
    @Published var draftText: String = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?
    @Published var shouldFocusComposer = false

    private var streamTask: Task<Void, Never>?

    private init() {}

    func clearConversation() {
        cancelStreaming()
        messages.removeAll()
        errorMessage = nil
    }

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    func sendDraft() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draftText = ""
        send(text: trimmed)
    }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isStreaming else { return }

        errorMessage = nil
        messages.append(CsAIMessage(role: "user", content: trimmed))
        startStreaming(for: messages)
    }

    func sendClipboardContent(autoSend: Bool = true) {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            errorMessage = String(localized: "Clipboard is empty or contains no text.")
            return
        }

        if autoSend {
            send(text: text)
        } else {
            draftText = text
            shouldFocusComposer = true
        }
    }

    private func startStreaming(for conversation: [CsAIMessage]) {
        cancelStreaming()

        let assistantID = UUID()
        messages.append(CsAIMessage(id: assistantID, role: "assistant", content: ""))
        isStreaming = true

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.fetchStreamingReply(for: conversation, assistantID: assistantID)
                if Task.isCancelled { return }
                self.isStreaming = false
            } catch is CancellationError {
                self.isStreaming = false
            } catch {
                if Task.isCancelled { return }
                if self.messages.first(where: { $0.id == assistantID })?.content.isEmpty == true {
                    self.messages.removeAll { $0.id == assistantID }
                }
                self.errorMessage = error.localizedDescription
                self.isStreaming = false
            }
        }
    }

    private func appendAssistantDelta(id: UUID, delta: String) {
        guard !delta.isEmpty else { return }
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += delta
    }

    private func fetchStreamingReply(for conversation: [CsAIMessage], assistantID: UUID) async throws {
        let endpoint = Defaults[.csAIEndpoint].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            throw CsAIClientError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120

        if let apiKey = CsAIKeychain.read()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "messages": conversation.map { ["role": $0.role, "content": $0.content] },
            "tier": Defaults[.csAIDefaultPlate].rawValue,
            "mode": "agent",
            "client": "macos-atoll",
            "disableSearch": true,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CsAIClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 4096 { break }
            }
            throw CsAIClientError.httpStatus(http.statusCode, errorBody.isEmpty ? nil : errorBody)
        }

        var receivedContent = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if let delta = Self.extractTextDelta(from: String(payload)) {
                receivedContent = true
                appendAssistantDelta(id: assistantID, delta: delta)
            }
        }

        guard receivedContent else {
            throw CsAIClientError.emptyResponse
        }
    }

    private static func extractTextDelta(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let text = json as? String {
            return text
        }

        guard let object = json as? [String: Any] else { return nil }

        if let content = object["content"] as? String { return content }
        if let text = object["text"] as? String { return text }
        if let delta = object["delta"] as? String { return delta }

        if let deltaObject = object["delta"] as? [String: Any] {
            if let content = deltaObject["content"] as? String { return content }
            if let text = deltaObject["text"] as? String { return text }
        }

        if let choices = object["choices"] as? [[String: Any]] {
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    return content
                }
                if let message = choice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    return content
                }
                if let text = choice["text"] as? String {
                    return text
                }
            }
        }

        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }

        return nil
    }
}

enum CsAIClientError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case emptyResponse
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return String(localized: "cs.AI endpoint URL is invalid.")
        case .invalidResponse:
            return String(localized: "Received an invalid response from cs.AI.")
        case .emptyResponse:
            return String(localized: "cs.AI returned an empty response.")
        case .httpStatus(let code, let body):
            if let body, !body.isEmpty {
                return String(localized: "cs.AI request failed (\(code)): \(body)")
            }
            return String(localized: "cs.AI request failed with status \(code).")
        }
    }
}
