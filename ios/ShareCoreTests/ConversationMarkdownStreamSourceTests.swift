import Testing

@testable import ShareCore

@Suite("Conversation markdown stream source")
struct ConversationMarkdownStreamSourceTests {
    @Test("Replays the latest snapshot to new subscribers")
    func replaysLatestSnapshot() async {
        let source = ConversationMarkdownStreamSource()
        source.yield("Hello **world**")

        var iterator = source.text.makeAsyncIterator()

        #expect(await iterator.next() == "Hello **world**")
    }

    @Test("Broadcasts complete snapshots to every subscriber")
    func broadcastsSnapshots() async {
        let source = ConversationMarkdownStreamSource()
        var first = source.text.makeAsyncIterator()
        var second = source.text.makeAsyncIterator()

        source.yield("Hello")
        source.yield("Hello world")

        #expect(await first.next() == "Hello world")
        #expect(await second.next() == "Hello world")
    }

    @Test("Reset finishes old subscribers and clears replay")
    func resetClearsStream() async {
        let source = ConversationMarkdownStreamSource()
        var oldIterator = source.text.makeAsyncIterator()

        source.yield("Partial")
        #expect(await oldIterator.next() == "Partial")
        source.reset()

        #expect(await oldIterator.next() == nil)

        var newIterator = source.text.makeAsyncIterator()
        source.yield("New response")

        #expect(await newIterator.next() == "New response")
    }

    @Test("Finish is idempotent and preserves the final replay")
    func finishPreservesFinalReplay() async {
        let source = ConversationMarkdownStreamSource()
        source.yield("Final")
        source.finish()
        source.finish()

        var iterator = source.text.makeAsyncIterator()

        #expect(await iterator.next() == "Final")
        #expect(await iterator.next() == nil)
    }
}
