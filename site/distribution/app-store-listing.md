# iriz — App Store listing draft

This copy is prepared for a future macOS listing. Confirm the final business model, publisher identity, support address, product URL, and privacy disclosures before submission.

## Product metadata

- **Name:** iriz
- **Subtitle (30 characters maximum):** Context into clear Actions
- **Primary category:** Productivity
- **Secondary category:** Business
- **Platform:** macOS 15 or later
- **Copyright:** © 2026 iriz
- **Marketing URL:** `https://lafayette-consulting.us/iriz/`
- **Direct download URL:** `https://lafayette-consulting.us/iriz/download.html`
- **Privacy Policy URL:** `https://lafayette-consulting.us/iriz/privacy.html`
- **Support URL:** `https://lafayette-consulting.us/iriz/support.html`
- **Public source repository:** [github.com/daviddemri26/iriz](https://github.com/daviddemri26/iriz)

## Promotional text

Private context. Clear Actions. Sourced answers. iriz helps you remember what happened and understand what to do next.

## Short description

iriz is a private, local-first contextual memory for macOS. It notices meaningful moments, filters routine activity, turns commitments and unfinished work into Actions, and answers questions from sourced memory.

## Full description

Remember what you actually did.

iriz is a contextual memory for macOS that helps you recover the decisions, actions, purchases, applications, appointments, and promises that disappear between apps, tabs, and conversations.

Instead of producing a noisy activity log, iriz filters routine changes and preserves only the moments likely to matter later.

ACTIONS

Actions are context-aware next steps iriz creates from meaningful commitments and unfinished work. Prioritize, snooze, merge, export to Reminders, or validate them when they are done. When evidence suggests completion but remains uncertain, iriz asks for confirmation. Explicit proof can close an Action automatically.

ASK IRIZ

Ask a natural question about your work. iriz searches encrypted memory locally first, sends only a bounded set of relevant evidence and recent context from that conversation, and returns answers linked to local sources. Pin useful conversations for quick access.

READ THE INDICATOR

The compact floating indicator combines colors when several states are active. Blue means Observing, green means Listening, red-pink means Private, and yellow means Meeting. A rotating contextual gradient means an OpenAI request is active.

LOCAL-FIRST PRIVACY

Your memory and search index are encrypted on your Mac. Raw screenshots and audio are encrypted locally and expire after 24 hours. iriz never captures keystrokes, clipboard contents, or camera video. Pause instantly and exclude specific apps, domains, or window titles.

NATIVE MAC TECHNOLOGY

iriz is built with SwiftUI, AppKit, ScreenCaptureKit, Vision, SQLite FTS5, AES-GCM, and macOS Keychain. There is no browser wrapper and no required third-party runtime.

AI features require your own paid OpenAI API key. Selected requests are sent directly from your Mac to OpenAI and may incur separate API charges.

Audio capture is optional. You are responsible for participant notice and compliance with applicable recording laws.

## Keywords

memory,actions,productivity,AI,commitments,search,privacy,meetings,notes,macOS

## Screenshot story

1. **Remember what you actually did** — Current navigation with Actions, Ask iriz, pinned conversations, and the floating indicator.
2. **Context becomes Action** — Fictional Actions showing priority, waiting, suggested completion, and completed states.
3. **Ask with sources** — A privacy-safe demo conversation answered from cited local evidence.
4. **Read the indicator** — Observing, Listening, Private, Meeting, combined states, and active OpenAI rotation.
5. **Know what stays local** — How iriz Works and Privacy settings explaining exclusions, encryption, permissions, and 24-hour raw-media expiry.

## App privacy preparation

Do not automatically select “Data Not Collected.” iriz sends user content directly to OpenAI when AI features are enabled, and Apple requires disclosures to include relevant third-party processing. Review the final binary, OpenAI data controls, any distribution SDKs, and App Store Connect definitions immediately before submission.

Potential data categories to evaluate include Audio Data, Other User Content, and Browsing History, used for App Functionality. Determine whether each category meets Apple’s definition of collection and whether it is linked to the user under the final account and API design.
