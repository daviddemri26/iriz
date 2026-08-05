import SwiftUI

struct HowIrizWorksView: View {
    @EnvironmentObject private var app: AppState
    @State private var simulatorSelection = IndicatorSimulatorSelection()
    @FocusState private var focusedScenarioID: String?

    private var previewScenario: IndicatorScenario? {
        let identifier = simulatorSelection.previewID
        return identifier.flatMap { id in IndicatorScenario.all.first(where: { $0.id == id }) }
    }

    private var previewPresentation: IndicatorPresentation {
        previewScenario?.presentation ?? app.indicatorPresentation
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                howItWorks
                simulator
                privacy
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(IrizTheme.canvas)
        .onExitCommand(perform: returnToLive)
        .onChange(of: focusedScenarioID) { _, identifier in
            simulatorSelection.setFocused(identifier)
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.075, green: 0.075, blue: 0.11))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(IrizTheme.gradient)
                        .opacity(0.20)
                }

            HStack(alignment: .center, spacing: 26) {
                IrizLogo(size: 92, shape: .appIcon)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Remember what you actually did")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("iriz notices meaningful changes, keeps the routine quiet, and turns useful context into private memory and clear Actions.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Ask iriz") { app.selectedSection = .assistant }
                            .buttonStyle(.borderedProminent)
                            .tint(IrizTheme.violet)
                        Button("Open Actions") { app.selectedSection = .followUp }
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
        .frame(minHeight: 220)
        .accessibilityElement(children: .contain)
    }

    private var howItWorks: some View {
        GuideSection(
            eyebrow: "LOCAL FIRST, CLEARLY EXPLAINED",
            title: "Your Mac filters first. OpenAI interprets only what matters.",
            detail: "iriz does not stream your entire day. It detects useful signals locally, sends selected context only when advanced understanding is needed, and keeps the resulting memory encrypted on your Mac."
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                GuideStepCard(
                    number: "01",
                    symbol: "eye.fill",
                    title: "Observe selectively",
                    detail: "Screen comparison, silence detection, exclusions and OCR happen locally before anything can leave your Mac."
                )
                GuideStepCard(
                    number: "02",
                    symbol: "sparkles",
                    title: "Interpret when useful",
                    detail: "Selected text, speech or a key image goes directly to OpenAI through your API key when deeper understanding is needed."
                )
                GuideStepCard(
                    number: "03",
                    symbol: "checklist",
                    title: "Remember and act",
                    detail: "iriz keeps searchable evidence, answers with sources and turns real loose ends into manageable Actions."
                )
            }
        }
    }

    private var simulator: some View {
        GuideSection(
            eyebrow: "READ THE INDICATOR",
            title: "One border, every live state.",
            detail: "Colors combine when states overlap. Only an OpenAI request makes the gradient rotate. Hover or focus a state to preview it; click to keep it selected. The simulator never changes capture, permissions, settings or API activity."
        ) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(IndicatorSimulatorLayout.groupsBeforePreview) { group in
                    scenarioGroup(group)
                }

                indicatorPreview

                ForEach(IndicatorSimulatorLayout.groupsAfterPreview) { group in
                    scenarioGroup(group)
                }
            }
        }
    }

    private func scenarioGroup(_ group: IndicatorScenario.Group) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title)
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                ForEach(IndicatorScenario.all.filter { $0.group == group }) { scenario in
                    scenarioCard(scenario)
                }
            }
        }
    }

    private var indicatorPreview: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 26) {
                previewLogo
                previewCopy
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack { Spacer(); previewLogo; Spacer() }
                previewCopy
            }
        }
        .padding(22)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }

    private var previewLogo: some View {
        IrizIndicatorView(presentation: previewPresentation, logoSize: 84)
            .frame(width: 116, height: 116)
            .accessibilityHidden(true)
    }

    private var previewCopy: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(previewScenario == nil ? "LIVE" : "PREVIEW")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(previewPresentation.tint)
                if simulatorSelection.pinnedID != nil {
                    Text("PINNED")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                }
            }
            Text(previewScenario?.title ?? previewPresentation.title)
                .font(.title2.weight(.bold))
            Text(previewScenario?.detail ?? previewPresentation.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let modelName = previewScenario?.modelName {
                Label(modelName, systemImage: "cpu")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Button("Back to Live", action: returnToLive)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .disabled(previewScenario == nil)
                .padding(.top, 2)
        }
        .frame(maxWidth: 540, alignment: .leading)
    }

    private func scenarioCard(_ scenario: IndicatorScenario) -> some View {
        let isPinned = simulatorSelection.pinnedID == scenario.id
        let isPreviewed = previewScenario?.id == scenario.id
        let accessibilityValue = [
            isPinned ? "Pinned" : nil,
            scenario.detail,
            scenario.modelName.map { "Model \($0)" }
        ]
            .compactMap { $0 }
            .joined(separator: ". ")
        return Button {
            simulatorSelection.togglePinned(scenario.id)
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: scenario.presentation.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(scenario.presentation.tint)
                    .frame(width: 26, height: 26)
                    .background(scenario.presentation.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(scenario.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(scenario.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    if let modelName = scenario.modelName {
                        Text(modelName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(scenario.presentation.tint)
                    }
                }
                Spacer(minLength: 0)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(scenario.presentation.tint)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .background(
                isPreviewed ? scenario.presentation.tint.opacity(0.10) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isPreviewed ? scenario.presentation.tint.opacity(0.42) : Color.primary.opacity(0.07))
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focusedScenarioID, equals: scenario.id)
        .onHover { isInside in
            simulatorSelection.setHovered(scenario.id, isInside: isInside)
        }
        .accessibilityLabel(scenario.title)
        .accessibilityHint("Previews this indicator state. Activate to pin or unpin it.")
        .accessibilityValue(accessibilityValue)
    }

    private var privacy: some View {
        GuideSection(
            eyebrow: "PRIVACY BOUNDARIES",
            title: "Designed to remember without watching everything.",
            detail: "The indicator tells you what is active, what is private, and when selected data is actually sent for interpretation."
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                PrivacyCard(symbol: "lock.shield.fill", title: "Encrypted on your Mac", detail: "Memory, search data, screenshots and audio are encrypted locally. Raw media expires automatically.")
                PrivacyCard(symbol: "eye.slash.fill", title: "Sensitive places stay private", detail: "Excluded apps, domains, secure fields and authentication windows are never captured.")
                PrivacyCard(symbol: "keyboard", title: "No hidden input capture", detail: "iriz never records keystrokes, clipboard contents or camera video.")
                PrivacyCard(symbol: "arrow.up.forward.app", title: "Selective OpenAI requests", detail: "Only selected context goes directly from this Mac to OpenAI through your API key, with storage disabled for analysis requests.")
            }
        }
    }

    private func returnToLive() {
        simulatorSelection.returnToLive()
        focusedScenarioID = nil
    }
}

private struct GuideSection<Content: View>: View {
    let eyebrow: String
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(IrizTheme.violet)
                Text(title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

private struct GuideStepCard: View {
    let number: String
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(IrizTheme.violet)
                Spacer()
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(IrizTheme.violet)
            }
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(IrizTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)) }
    }
}

private struct PrivacyCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(IrizTheme.mint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(IrizTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)) }
    }
}
