import Foundation
import Testing

@testable import TinyTaskbar

struct ApplicationIndicatorTests {
    @Test("attention listener uses a finite lease")
    func finiteAttentionListenerLease() {
        #expect(
            SystemApplicationAttentionObserver.listenerArguments == [
                "-currentSession", "listen", "+wantsAttentionChanged", "wait", "300",
            ])
        #expect(
            SystemApplicationAttentionObserver.currentAttentionArguments == [
                "-currentSession", "find", "kLSApplicationDesiresAttentionKey=true",
            ])
    }

    @Test("attention parser accepts only wants-attention LaunchServices events")
    func attentionEventParsing() {
        let began =
            "Notification: kLSNotifyApplicationWantsAttentionChanged dataRef={ \"ChangeCount\"=540, \"LSASN\"=ASN:0x0-0xf5cf5c:, \"LSPreviousValue\"=false, \"LSWantsAttention\"=true }"
        let ended =
            "Notification: kLSNotifyApplicationWantsAttentionChanged dataRef={ \"LSASN\"=ASN:0x0-0xf5cf5c:, \"LSPreviousValue\"=true, \"LSWantsAttention\"=false }"

        #expect(
            LaunchServicesAttentionEventParser.parse(began)
                == LaunchServicesAttentionEvent(
                    applicationSerialNumber: "ASN:0x0-0xf5cf5c:",
                    wantsAttention: true))
        #expect(
            LaunchServicesAttentionEventParser.parse(ended)
                == LaunchServicesAttentionEvent(
                    applicationSerialNumber: "ASN:0x0-0xf5cf5c:",
                    wantsAttention: false))
        #expect(LaunchServicesAttentionEventParser.parse("unrelated output") == nil)
        #expect(
            LaunchServicesAttentionEventParser.parse(
                "kLSNotifyApplicationWantsAttentionChanged \"LSASN\"=bad \"LSWantsAttention\"=true")
                == nil)
    }

    @Test("attention application list parser accepts bounded unique ASNs")
    func attentionApplicationListParsing() {
        #expect(
            LaunchServicesApplicationSerialNumberParser.parse(
                "ASN:0x0-0x1234-\"Control_Center\": ASN:0x0-0x5678-\"Indicator_Probe\": ASN:0x0-0x1234-\"Control_Center\":"
            ) == [
                "ASN:0x0-0x1234:", "ASN:0x0-0x5678:",
            ])
        #expect(
            LaunchServicesApplicationSerialNumberParser.parse(
                "( ASN:0x0-0x1234:, ASN:0x0-0x5678: )") == [
                    "ASN:0x0-0x1234:", "ASN:0x0-0x5678:",
                ])
        #expect(
            LaunchServicesApplicationSerialNumberParser.parse(
                "not-an-asn ASN:broken ASN:0x0-nope:"
            ).isEmpty)
    }

    @Test("Dock badge fallback remains bounded while the metadata seed is checked quickly")
    func dockMembershipRefreshDelay() {
        #expect(SystemDockBadgeObserver.applicationMembershipRefreshDelay == .seconds(1))
        #expect(
            SystemDockBadgeObserver.applicationInformationSeedCheckInterval == .seconds(1))
        #expect(
            SystemDockBadgeObserver.nextBadgeScanDelay(
                hasObservedApplications: false, badgesChanged: false) == nil)
        #expect(
            SystemDockBadgeObserver.nextBadgeScanDelay(
                hasObservedApplications: true, badgesChanged: true) == .seconds(10))
        #expect(
            SystemDockBadgeObserver.nextBadgeScanDelay(
                hasObservedApplications: true, badgesChanged: false) == .seconds(10))
    }

    @Test("badge observation excludes broad Dock-root animation changes")
    func badgeNotificationsStayItemScoped() {
        #expect(
            SystemDockBadgeObserver.badgeChangeNotificationNames == [
                "AXValueChanged",
                "AXTitleChanged",
                "AXStatusLabelChanged",
            ])
    }

    @Test("line buffer preserves split events and emits complete lines once")
    func splitLineBuffering() {
        var buffer = BoundedUTF8LineBuffer()

        #expect(buffer.append(Data("first".utf8)).isEmpty)
        #expect(buffer.append(Data(" line\nsecond".utf8)) == ["first line"])
        #expect(buffer.append(Data(" line\n".utf8)) == ["second line"])
        #expect(buffer.data.isEmpty)
    }

    @Test("line buffer bounds malformed unterminated output")
    func boundedLineBuffering() {
        var buffer = BoundedUTF8LineBuffer()
        _ = buffer.append(Data(repeating: 0x61, count: 96 * 1024))

        #expect(buffer.data.count <= 64 * 1024)
    }

    @Test("attention event queue coalesces applications and bounds bursts")
    func boundedAttentionEventQueue() {
        var queue = BoundedAttentionEventQueue(maximumCount: 2)
        queue.enqueue(
            LaunchServicesAttentionEvent(
                applicationSerialNumber: "ASN:0x0-0x1:", wantsAttention: true))
        queue.enqueue(
            LaunchServicesAttentionEvent(
                applicationSerialNumber: "ASN:0x0-0x1:", wantsAttention: false))
        queue.enqueue(
            LaunchServicesAttentionEvent(
                applicationSerialNumber: "ASN:0x0-0x2:", wantsAttention: true))
        queue.enqueue(
            LaunchServicesAttentionEvent(
                applicationSerialNumber: "ASN:0x0-0x3:", wantsAttention: true))

        #expect(
            queue.events == [
                LaunchServicesAttentionEvent(
                    applicationSerialNumber: "ASN:0x0-0x2:", wantsAttention: true),
                LaunchServicesAttentionEvent(
                    applicationSerialNumber: "ASN:0x0-0x3:", wantsAttention: true),
            ])
        #expect(queue.popFirst()?.applicationSerialNumber == "ASN:0x0-0x2:")
        queue.removeAll()
        #expect(queue.isEmpty)
    }
}
