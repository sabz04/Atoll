/*
 * Atoll (DynamicIsland)
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

import SwiftUI
import AppKit
import Defaults

/// Claude Code sessions on this Mac as a notch tab: what each one is doing,
/// newest first, and a click away from resuming it. Without the hooks the
/// strip opens with a card that connects them in one click.
struct NotchClaudeView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var monitor = ClaudeCodeSessionMonitor.shared
    @AppStorage("claudeTabActiveOnly") private var activeOnly = false
    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false
    @Namespace private var filterNamespace

    private static let installURL = URL(string: "https://www.anthropic.com/claude-code")!

    var body: some View {
        let all = monitor.sessions
        let sessions = activeOnly ? all.filter { $0.status.isActive } : all

        VStack(alignment: .leading, spacing: 10) {
            toolbar(all: all)

            if !monitor.isClaudeCodeInstalled {
                notInstalled
            } else if !monitor.hasLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty && monitor.hooksInstalled {
                emptyState
            } else {
                strip(sessions)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { updateSuppression(for: $0) }
        .onDisappear { updateSuppression(for: false) }
        .onAppear { monitor.start() }
    }

    // MARK: - Toolbar

    private func toolbar(all: [ClaudeCodeSession]) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ClaudeCodePalette.brand)
                Text(verbatim: "Claude Code")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 2) {
                filterChip(title: String(localized: "All"), count: all.count, isSelected: !activeOnly) { activeOnly = false }
                filterChip(title: String(localized: "claude.filter.active", defaultValue: "Active"), count: all.filter { $0.status.isActive }.count, isSelected: activeOnly) { activeOnly = true }
            }

            Spacer(minLength: 0)

            if monitor.hooksInstalled {
                HStack(spacing: 5) {
                    PulsingDot(color: ClaudeCodePalette.done, isAnimating: all.contains { $0.status == .working })
                    Text("Live")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(ClaudeCodePalette.done)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(ClaudeCodePalette.done.opacity(0.12)))
                .help("Live status is connected through Claude Code hooks")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(height: 26)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: monitor.hooksInstalled)
    }

    private func filterChip(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { action() }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                if count > 0 {
                    Text(count, format: .number)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .opacity(0.65)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.gray)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .matchedGeometryEffect(id: "claude-filter", in: filterNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cards

    private func strip(_ sessions: [ClaudeCodeSession]) -> some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    if !monitor.hooksInstalled {
                        ClaudeConnectCard(isConnecting: isConnecting, error: connectError, action: connect)
                            .frame(width: 236, height: geo.size.height)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    ForEach(sessions) { session in
                        ClaudeSessionCard(session: session) { monitor.open(session) } onReveal: {
                            monitor.revealFolder(of: session)
                        }
                        .frame(width: 236, height: geo.size.height)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                    if sessions.isEmpty {
                        Text(activeOnly ? "Nothing running right now" : "No sessions this week")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 200, height: geo.size.height)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(ClaudeCodePalette.brand.opacity(0.6))
            Text(activeOnly ? "Nothing running right now" : "No sessions this week")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Sessions from the terminal and the Claude app show up here")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notInstalled: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(ClaudeCodePalette.brand.opacity(0.15))
                Image(systemName: "sparkle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(ClaudeCodePalette.brand)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Code isn't installed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Install it and your sessions — terminal and app alike — will appear here with live status.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSWorkspace.shared.open(Self.installURL)
                } label: {
                    Label("Get Claude Code", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(ClaudeCodePalette.brand))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        connectError = nil
        do {
            try withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                try monitor.connectHooks()
            }
            if Defaults[.enableHaptics] {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        } catch {
            connectError = error.localizedDescription
        }
        isConnecting = false
    }

    private func updateSuppression(for hovering: Bool) {
        guard hovering != isSuppressing else { return }
        isSuppressing = hovering
        vm.setScrollGestureSuppression(hovering, token: suppressionToken)
    }
}

// MARK: - Session card

private struct ClaudeSessionCard: View {
    let session: ClaudeCodeSession
    let onOpen: () -> Void
    let onReveal: () -> Void

    @State private var isHovered = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ClaudeStatusBadge(status: session.status)
                Spacer(minLength: 4)
                Text(relativeTime)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Text(session.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let prompt = session.lastPrompt, prompt != session.displayTitle {
                Text(prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Color.white.opacity(isHovered ? 0.11 : 0.07)))
        .overlay {
            if session.status == .working {
                ClaudeWorkingBorder(cornerRadius: 14)
            } else {
                shape.strokeBorder(borderColor, lineWidth: 1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isHovered {
                Image(systemName: "arrow.up.forward.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, ClaudeCodePalette.brand)
                    .padding(9)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contextMenu {
            Button(session.isDesktop ? "Open in Claude" : "Resume in Terminal", action: onOpen)
            if session.cwd != nil {
                Button("Show Folder in Finder", action: onReveal)
            }
            if !session.isDesktop {
                Button("Copy Resume Command") { copy(session.resumeCommand) }
            }
            Button("Copy Session ID") { copy(session.id) }
        }
        .help(session.statusMessage ?? session.displayTitle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: session.projectName == nil ? "tray" : "folder.fill")
                .font(.system(size: 9))
            Text(session.projectName ?? String(localized: "No folder"))
                .lineLimit(1)
                .truncationMode(.middle)
            if let branch = session.gitBranch, !branch.isEmpty, branch != "HEAD" {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                Text(branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(session.isDesktop ? "App" : "CLI")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
    }

    private var borderColor: Color {
        switch session.status {
        case .needsPermission: return ClaudeCodePalette.attention.opacity(0.6)
        case .waitingForInput: return ClaudeCodePalette.waiting.opacity(0.45)
        case .finished: return ClaudeCodePalette.done.opacity(0.35)
        default: return Color.white.opacity(isHovered ? 0.25 : 0.08)
        }
    }

    private var relativeTime: String {
        if Date().timeIntervalSince(session.lastActivity) < 60 { return String(localized: "Just now") }
        return Self.relativeFormatter.localizedString(for: session.lastActivity, relativeTo: Date())
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Connect card

private struct ClaudeConnectCard: View {
    let isConnecting: Bool
    let error: String?
    let action: () -> Void

    @State private var isHovered = false
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(ClaudeCodePalette.brand))
                Text("Live status")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(error ?? String(localized: "See when Claude is working, done, or waiting for your permission — right here in the notch."))
                .font(.system(size: 11))
                .foregroundStyle(error == nil ? .white.opacity(0.6) : .red.opacity(0.9))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: action) {
                HStack(spacing: 6) {
                    if isConnecting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "link")
                            .font(.system(size: 11, weight: .bold))
                    }
                    Text("Connect")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(Capsule().fill(ClaudeCodePalette.brand.opacity(isHovered ? 1 : 0.88)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)
            .onHover { isHovered = $0 }
            .help("Adds Atoll's hooks to ~/.claude/settings.json (a backup is kept)")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            shape.fill(
                LinearGradient(
                    colors: [ClaudeCodePalette.brand.opacity(0.22), ClaudeCodePalette.brand.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        )
        .overlay(shape.strokeBorder(ClaudeCodePalette.brand.opacity(0.45), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Status pieces

private struct ClaudeStatusBadge: View {
    let status: ClaudeCodeSession.Status

    var body: some View {
        let color = ClaudeCodePalette.color(for: status)
        HStack(spacing: 5) {
            indicator(color)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(Capsule().fill(color.opacity(0.15)))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: status)
    }

    @ViewBuilder
    private func indicator(_ color: Color) -> some View {
        switch status {
        case .working:
            PulsingDot(color: color, isAnimating: true)
        case .needsPermission:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 9, weight: .bold))
                .symbolEffect(.pulse, options: .repeating)
        case .waitingForInput:
            Image(systemName: "ellipsis.bubble.fill")
                .font(.system(size: 9, weight: .bold))
        case .finished:
            Image(systemName: "checkmark")
                .font(.system(size: 8.5, weight: .heavy))
        case .idle:
            Circle().fill(color).frame(width: 5, height: 5)
        }
    }

    private var label: String {
        switch status {
        case .working: return String(localized: "Working")
        case .needsPermission: return String(localized: "Needs permission")
        case .waitingForInput: return String(localized: "Waiting for you")
        case .finished: return String(localized: "Done")
        case .idle: return String(localized: "claude.status.idle", defaultValue: "Idle")
        }
    }
}

/// A dot with a ring that keeps expanding out of it while `isAnimating`.
private struct PulsingDot: View {
    let color: Color
    let isAnimating: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .background {
                if isAnimating {
                    PhaseAnimator([false, true]) { expanded in
                        Circle()
                            .stroke(color, lineWidth: 1.5)
                            .scaleEffect(expanded ? 2.6 : 1)
                            .opacity(expanded ? 0 : 0.8)
                    } animation: { expanded in
                        expanded ? .easeOut(duration: 1.3) : nil
                    }
                }
            }
    }
}

/// A light that runs around the card's border while Claude is working.
private struct ClaudeWorkingBorder: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.strokeBorder(ClaudeCodePalette.brand.opacity(0.25), lineWidth: 1)
            // Gradient angles don't interpolate, so the light is a gradient square
            // (big enough to cover the card at any angle) that turns underneath a
            // border-shaped mask.
            GeometryReader { geo in
                let side = hypot(geo.size.width, geo.size.height)
                PhaseAnimator([false, true]) { turned in
                    AngularGradient(
                        colors: [.clear, .clear, ClaudeCodePalette.brand, .clear],
                        center: .center
                    )
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(turned ? 360 : 0))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } animation: { turned in
                    turned ? .linear(duration: 2.4) : nil
                }
            }
            .mask(shape.strokeBorder(lineWidth: 1.5))
        }
        .allowsHitTesting(false)
    }
}
