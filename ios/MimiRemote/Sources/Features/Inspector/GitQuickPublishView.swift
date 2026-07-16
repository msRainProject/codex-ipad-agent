import SwiftUI

enum GitCommitMessageSuggestion {
    static func make(from status: GitStatusResponse) -> String {
        let paths = status.files.map { $0.path.lowercased() }
        guard !paths.isEmpty else {
            return "chore: 同步当前分支"
        }

        if paths.allSatisfy({ $0.hasSuffix(".md") || $0.hasPrefix("docs/") }) {
            return "docs: 更新项目文档"
        }
        if paths.allSatisfy(isTestPath) {
            return "test: 更新自动化测试"
        }
        if paths.allSatisfy(isReleasePath) {
            return "chore: 更新发布流程"
        }

        let type = status.files.contains(where: isAddedFile) ? "feat" : "chore"
        return "\(type): 更新\(scopeName(for: paths))"
    }

    private static func isTestPath(_ path: String) -> Bool {
        path.contains("/tests/")
            || path.hasPrefix("tests/")
            || path.hasSuffix("_test.go")
            || path.hasSuffix("tests.swift")
    }

    private static func isReleasePath(_ path: String) -> Bool {
        path.hasPrefix("scripts/")
            || path.hasPrefix(".github/")
            || path.hasPrefix("config/release/")
    }

    private static func isAddedFile(_ file: GitFileStatus) -> Bool {
        file.untracked || file.code.contains("A") || file.code == "??"
    }

    private static func scopeName(for paths: [String]) -> String {
        if paths.allSatisfy({ $0.hasPrefix("ios/") }) {
            if paths.contains(where: { $0.contains("/conversation/") }) {
                return "会话交互"
            }
            if paths.contains(where: { $0.contains("/inspector/") }) {
                return "Git 变更面板"
            }
            if paths.contains(where: { $0.contains("/state/") }) {
                return "iOS 状态管理"
            }
            return "iOS 客户端"
        }
        if paths.allSatisfy({ $0.hasPrefix("internal/") || $0.hasPrefix("cmd/") }) {
            return "主机服务"
        }
        if paths.allSatisfy({ $0.hasPrefix("scripts/") || $0.hasPrefix("config/") }) {
            return "项目工具"
        }
        return "项目变更"
    }
}

struct GitQuickPublishBox: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @Binding var message: String
    let status: GitStatusResponse
    let testFlightStatus: GitTestFlightStatusResponse?
    let testFlightError: String?
    let isWorking: Bool
    let isRefreshingTestFlight: Bool
    let onRegenerateMessage: () -> Void
    let onQuickPublish: () -> Void
    let onTestFlight: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 10) {
            header(tokens: tokens)
            repositoryState(tokens: tokens)

            if status.hasChanges {
                commitMessageField(tokens: tokens)
            }

            publishButton(tokens: tokens)

            if shouldShowTestFlight {
                testFlightButton(tokens: tokens)
                Text(testFlightCaption)
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(testFlightCaptionTint(tokens: tokens))
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if isRefreshingTestFlight {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查主机发布能力")
                }
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }

            if let job = testFlightStatus?.job {
                releaseJobStatus(job, tokens: tokens)
            }
            if let testFlightError, !testFlightError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(testFlightError, systemImage: "exclamationmark.triangle")
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(tokens.warning)
                    .lineLimit(4)
            }

            Label("执行前会再次确认，不会自动发布", systemImage: "shield.lefthalf.filled")
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.tertiaryText)
        }
        .padding(12)
        .background(tokens.elevatedSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.accent.opacity(0.24), lineWidth: 1)
        }
    }

    private var releaseJob: GitTestFlightJob? {
        testFlightStatus?.job
    }

    private var releaseIsRunning: Bool {
        releaseJob?.isRunning == true
    }

    private var canQuickPublish: Bool {
        !isWorking
            && !releaseIsRunning
            && !(status.branch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && (!status.hasChanges || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var shouldShowTestFlight: Bool {
        testFlightStatus?.capability.isIOSProject == true || releaseJob != nil
    }

    private var canPublishTestFlight: Bool {
        testFlightStatus?.capability.available == true
            && !status.hasChanges
            && !isWorking
            && !releaseIsRunning
    }

    private var testFlightCaption: String {
        if releaseIsRunning {
            return "主机正在归档并上传，可离开此页面"
        }
        if status.hasChanges {
            return "提交推送成功后可用"
        }
        return testFlightStatus?.capability.reason ?? "主机未配置 TestFlight 发布流程"
    }

    @ViewBuilder
    private func header(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Label("快捷发布", systemImage: "wand.and.sparkles")
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            if testFlightStatus?.capability.isIOSProject == true {
                Text("iOS 项目")
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tokens.accent.opacity(0.12), in: Capsule())
            }
            Spacer()
            if isWorking || isRefreshingTestFlight {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func repositoryState(tokens: ThemeTokens) -> some View {
        HStack(spacing: 9) {
            Image(systemName: status.hasChanges ? "checkmark.circle" : "checkmark.circle.fill")
                .font(themeStore.uiFont(size: 18, weight: .semibold))
                .foregroundStyle(status.hasChanges ? tokens.accent : tokens.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.hasChanges ? "\(status.files.count) 个文件待提交" : "工作区已提交")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text("\(status.branch ?? "当前分支") → origin/\(status.branch ?? "当前分支")")
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(tokens.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func commitMessageField(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("提交说明")
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.tertiaryText)
            HStack(spacing: 6) {
                TextField("提交说明", text: $message, axis: .vertical)
                    .font(themeStore.uiFont(.caption))
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 40)
                Button(action: onRegenerateMessage) {
                    Label("重新生成提交说明", systemImage: "wand.and.sparkles")
                        .labelStyle(.iconOnly)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(tokens.accent)
                .help("根据当前文件重新生成提交说明")
            }
            .background(tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tokens.border, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func publishButton(tokens: ThemeTokens) -> some View {
        Button(action: onQuickPublish) {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up.circle")
                }
                Text(status.hasChanges ? "提交并推送" : "推送当前分支")
            }
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(canQuickPublish ? Color.white : tokens.tertiaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(canQuickPublish ? tokens.accent : tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canQuickPublish)
        .accessibilityHint("暂存当前工作区变更，提交后普通推送到 origin")
    }

    @ViewBuilder
    private func testFlightButton(tokens: ThemeTokens) -> some View {
        Button(action: onTestFlight) {
            HStack(spacing: 8) {
                if releaseIsRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "paperplane")
                }
                Text(releaseIsRunning ? "正在发布 TestFlight" : "发布 TestFlight")
            }
            .font(themeStore.uiFont(.caption, weight: .semibold))
            .foregroundStyle(canPublishTestFlight ? tokens.primaryText : tokens.tertiaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(canPublishTestFlight ? tokens.secondaryText : tokens.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canPublishTestFlight)
        .accessibilityHint("在主机执行已配置并通过预检的本地 TestFlight 发布流程")
    }

    @ViewBuilder
    private func releaseJobStatus(_ job: GitTestFlightJob, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(releaseJobTitle(job), systemImage: releaseJobSymbol(job))
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(releaseJobTint(job, tokens: tokens))
            if let output = job.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                Text(output)
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func releaseJobTitle(_ job: GitTestFlightJob) -> String {
        switch job.state {
        case "running": return "TestFlight 发布进行中"
        case "succeeded": return "TestFlight 发布完成"
        default: return "TestFlight 发布失败"
        }
    }

    private func releaseJobSymbol(_ job: GitTestFlightJob) -> String {
        switch job.state {
        case "running": return "clock.arrow.circlepath"
        case "succeeded": return "checkmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private func releaseJobTint(_ job: GitTestFlightJob, tokens: ThemeTokens) -> Color {
        switch job.state {
        case "running": tokens.accent
        case "succeeded": tokens.success
        default: tokens.warning
        }
    }

    private func testFlightCaptionTint(tokens: ThemeTokens) -> Color {
        if releaseJob?.succeeded == true {
            return tokens.success
        }
        if testFlightStatus?.capability.available == false && !status.hasChanges {
            return tokens.warning
        }
        return tokens.tertiaryText
    }
}
