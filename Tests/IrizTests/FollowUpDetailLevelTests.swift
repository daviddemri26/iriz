import Foundation
import Testing
@testable import Iriz

@Suite("Follow-up detail level")
struct FollowUpDetailLevelTests {
    @Test("Five ordered levels expose useful labels and descriptions")
    func levelMetadata() {
        #expect(FollowUpDetailLevel.allCases == [.outcome, .milestone, .standard, .detailed, .micro])
        #expect(FollowUpDetailLevel.allCases.map(\.displayName) == [
            "Outcome", "Milestone", "Standard", "Detailed", "Micro"
        ])
        #expect(FollowUpDetailLevel.allCases.allSatisfy { !$0.description.isEmpty })
        #expect(Set(FollowUpDetailLevel.allCases.map(\.description)).count == FollowUpDetailLevel.allCases.count)
    }

    @Test("New settings default to standard and preserve every level")
    func settingsRoundTrip() throws {
        #expect(IrizSettings().followUpDetailLevel == .standard)

        for level in FollowUpDetailLevel.allCases {
            var settings = IrizSettings()
            settings.followUpDetailLevel = level
            let restored = try JSONDecoder().decode(
                IrizSettings.self,
                from: JSONEncoder().encode(settings)
            )
            #expect(restored.followUpDetailLevel == level)
        }
    }

    @Test("Every level sends distinct creation guidance")
    func requestGuidance() throws {
        let expectedGuidance: [FollowUpDetailLevel: String] = [
            .outcome: "very few durable outcome-level follow-ups",
            .milestone: "one follow-up per major deliverable or phase",
            .standard: "one follow-up per distinct, meaningful action",
            .detailed: "separate follow-ups for clear concrete steps",
            .micro: "smallest concrete next actions"
        ]
        var prompts: Set<String> = []

        for level in FollowUpDetailLevel.allCases {
            let data = try OpenAIRequestFactory.interpretationRequest(
                observation: Observation(source: .screen, text: "Continue the product work"),
                imageData: nil,
                outputLanguage: "English",
                followUpDetailLevel: level
            )
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let input = try #require(object["input"] as? [[String: Any]])
            let content = try #require(input.first?["content"] as? [[String: Any]])
            let prompt = try #require(content.first?["text"] as? String)

            #expect(prompt.contains("Detail level for newly created follow-ups: \(level.displayName)"))
            #expect(prompt.contains(try #require(expectedGuidance[level])))
            #expect(prompt.contains("This setting applies only to operation=create"))
            prompts.insert(prompt)
        }

        #expect(prompts.count == FollowUpDetailLevel.allCases.count)
    }

    @Test("Legacy settings without a detail level migrate to standard")
    func legacySettingsDefault() throws {
        let legacySettings = Data(
            #"{"outputLanguageTag":"en-US","followUpSensitivity":"focused","mediaRetentionHours":24}"#.utf8
        )
        let restored = try JSONDecoder().decode(IrizSettings.self, from: legacySettings)

        #expect(restored.outputLanguageTag == "en-US")
        #expect(restored.followUpDetailLevel == .standard)
        #expect(!String(decoding: try JSONEncoder().encode(restored), as: UTF8.self)
            .contains("followUpSensitivity"))
    }

    @Test("Commitments preserve their creation level and old payloads use standard")
    func commitmentCodingCompatibility() throws {
        let commitment = Commitment(
            eventID: UUID(),
            owner: "You",
            action: "Prepare the launch checklist",
            confidence: 0.9,
            state: .needsAttention,
            detailLevelAtCreation: .micro
        )
        let encoded = try JSONEncoder().encode(commitment)
        let restored = try JSONDecoder().decode(Commitment.self, from: encoded)
        #expect(restored.detailLevelAtCreation == .micro)

        var legacyObject = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "detailLevelAtCreation")
        let legacyPayload = try JSONSerialization.data(withJSONObject: legacyObject)
        let migrated = try JSONDecoder().decode(Commitment.self, from: legacyPayload)

        #expect(migrated.id == commitment.id)
        #expect(migrated.detailLevelAtCreation == .standard)
    }

    @Test("Later AI observations preserve scope across detail-level changes")
    func nonDestructiveUpdate() {
        let original = Commitment(
            eventID: UUID(),
            owner: "You",
            action: "Continue developing Iriz on the new version",
            confidence: 0.8,
            state: .needsAttention,
            summary: "Deliver the next coherent version.",
            details: "Initial architecture is ready.",
            detailLevelAtCreation: .outcome,
            surfacedAt: Date(timeIntervalSince1970: 100)
        )
        let microDraft = CommitmentDraft(
            operation: .update,
            existingCommitmentID: original.id,
            owner: "You",
            action: "Adjust priority buttons",
            rationale: "A smaller implementation step was observed.",
            summary: "Rewrite this as a micro-task.",
            details: "Priority controls are being refined.",
            explicitDueAt: nil,
            suggestedReviewAt: nil,
            contextLabel: "Iriz Follow Up",
            confidence: 0.9
        )

        let updated = CommitmentLinker.applyingNonDestructiveTextUpdate(microDraft, to: original)

        #expect(updated.action == original.action)
        #expect(updated.summary == original.summary)
        #expect(updated.detailLevelAtCreation == .outcome)
        #expect(updated.surfacedAt == original.surfacedAt)
        #expect(updated.details == "Initial architecture is ready.\n\nPriority controls are being refined.")

        var userEdited = original
        userEdited.manuallyEditedFields.insert(.details)
        #expect(CommitmentLinker.applyingNonDestructiveTextUpdate(microDraft, to: userEdited).details == original.details)
    }
}
