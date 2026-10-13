import Foundation
import Testing

@testable import PeeringKit

struct AgentDraftTests {
    @Test func filesGoFirstAsMentions() {
        let text = AgentDraft.prompt(draft: "what is this", attachedPaths: ["/p/a.png", "/p/b.txt"])
        #expect(text == "@/p/a.png @/p/b.txt what is this")
    }

    @Test func emptyDraftSendsJustTheFiles() {
        #expect(AgentDraft.prompt(draft: "", attachedPaths: ["/p/a.png"]) == "@/p/a.png")
    }

    @Test func plainDraftIsUntouched() {
        #expect(AgentDraft.prompt(draft: "hello", attachedPaths: []) == "hello")
    }

    @Test func whatIsSentReadsBackAsFilesAndMessage() {
        let text = AgentDraft.prompt(draft: "describe", attachedPaths: ["/p/a.png"])
        let read = AgentMentions.split(text)
        #expect(read.files == ["/p/a.png"])
        #expect(read.rest == "describe")
    }

    @Test func sendNeedsWordsOrAFileAndNoUploadInFlight() {
        #expect(AgentDraft.canSend(draft: "hi", attachedCount: 0, isUploading: false))
        #expect(AgentDraft.canSend(draft: "  ", attachedCount: 1, isUploading: false))
        #expect(!AgentDraft.canSend(draft: "  \n", attachedCount: 0, isUploading: false))
        #expect(!AgentDraft.canSend(draft: "hi", attachedCount: 1, isUploading: true))
    }

    @Test func uploadLandsInTheChatsFolder() {
        #expect(AgentDraft.attachmentPath(folder: "/Users/me/app", name: "a.png") == "/Users/me/app/a.png")
        #expect(AgentDraft.attachmentPath(folder: "/Users/me/app/", name: "a.png") == "/Users/me/app/a.png")
        #expect(AgentDraft.attachmentPath(folder: "/", name: "a.png") == "/a.png")
    }
}
