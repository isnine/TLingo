#if os(iOS)
    import CoreFoundation
    import Testing

    @testable import ShareCore

    @Suite("Conversation scroll policy")
    struct ConversationScrollPolicyTests {
        @Test("Follows only after the streaming frontier crosses the follow line")
        func followsAfterFrontierCrossesFollowLine() {
            #expect(!ConversationScrollPolicy.shouldFollow(
                frontierY: 650,
                viewportHeight: 1000,
                isAutoFollowing: true
            ))
            #expect(ConversationScrollPolicy.shouldFollow(
                frontierY: 651,
                viewportHeight: 1000,
                isAutoFollowing: true
            ))
        }

        @Test("Does not follow while paused or without a viewport")
        func doesNotFollowWithoutActiveTracking() {
            #expect(!ConversationScrollPolicy.shouldFollow(
                frontierY: 900,
                viewportHeight: 1000,
                isAutoFollowing: false
            ))
            #expect(!ConversationScrollPolicy.shouldFollow(
                frontierY: 900,
                viewportHeight: 0,
                isAutoFollowing: true
            ))
        }

        @Test("Resumes only while the streaming frontier is visible")
        func resumesNearVisibleFrontier() {
            #expect(ConversationScrollPolicy.shouldResume(frontierY: 850, viewportHeight: 1000))
            #expect(!ConversationScrollPolicy.shouldResume(frontierY: 851, viewportHeight: 1000))
            #expect(!ConversationScrollPolicy.shouldResume(frontierY: -1, viewportHeight: 1000))
            #expect(!ConversationScrollPolicy.shouldResume(frontierY: 0, viewportHeight: 0))
        }

        @Test("Reanchors an active stream when the keyboard reduces the viewport")
        func reanchorsAfterViewportShrinks() {
            #expect(ConversationScrollPolicy.shouldReanchorForViewportChange(
                previousHeight: 700,
                viewportHeight: 400,
                isStreaming: true,
                isAutoFollowing: true
            ))
            #expect(!ConversationScrollPolicy.shouldReanchorForViewportChange(
                previousHeight: 400,
                viewportHeight: 700,
                isStreaming: true,
                isAutoFollowing: true
            ))
            #expect(!ConversationScrollPolicy.shouldReanchorForViewportChange(
                previousHeight: 700,
                viewportHeight: 400,
                isStreaming: false,
                isAutoFollowing: true
            ))
        }
    }
#endif
