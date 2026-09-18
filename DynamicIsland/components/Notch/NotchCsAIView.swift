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

import Defaults
import SwiftUI

struct NotchCsAIView: View {
    @ObservedObject private var manager = CsAIManager.shared
    @Default(.csAIDefaultPlate) private var selectedPlate
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            messageList
            if let errorMessage = manager.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
            }
            composer
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isComposerFocused = true
            }
        }
        .onChange(of: manager.shouldFocusComposer) { _, shouldFocus in
            guard shouldFocus else { return }
            isComposerFocused = true
            manager.shouldFocusComposer = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("cs.AI")
                .font(.headline)
            Spacer()
            Picker("", selection: $selectedPlate) {
                ForEach(CsAIPlate.allCases) { plate in
                    Text(plate.displayName).tag(plate)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(maxWidth: 220)
            .disabled(manager.isStreaming)

            Button {
                manager.sendClipboardContent(autoSend: false)
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Paste clipboard into composer"))

            Button {
                manager.clearConversation()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Clear conversation"))
            .disabled(manager.messages.isEmpty && manager.draftText.isEmpty)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if manager.messages.isEmpty {
                        Text(String(localized: "Ask cs.AI anything. Flash plate is selected by default."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }

                    ForEach(manager.messages) { message in
                        messageBubble(for: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: manager.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: manager.messages.last?.content) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func messageBubble(for message: CsAIMessage) -> some View {
        HStack(alignment: .top) {
            if message.role == "user" { Spacer(minLength: 24) }
            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                Text(message.role == "user" ? String(localized: "You") : String(localized: "cs.AI"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message.content.isEmpty && manager.isStreaming ? "…" : message.content)
                    .font(.callout)
                    .textSelection(.enabled)
                    .multilineTextAlignment(message.role == "user" ? .trailing : .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                message.role == "user"
                    ? Color.accentColor.opacity(0.35)
                    : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
            if message.role != "user" { Spacer(minLength: 24) }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "Message cs.AI…"), text: $manager.draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isComposerFocused)
                .onSubmit {
                    manager.sendDraft()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

            if manager.isStreaming {
                Button {
                    manager.cancelStreaming()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.85))
                .help(String(localized: "Stop generating"))
            } else {
                Button {
                    manager.sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : .secondary)
                .disabled(!canSend)
                .help(String(localized: "Send message"))
            }
        }
    }

    private var canSend: Bool {
        !manager.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastID = manager.messages.last?.id else { return }
        withAnimation(.smooth(duration: 0.2)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}
