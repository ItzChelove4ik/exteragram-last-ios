import XCTest
import Postbox
import TelegramCore
@testable import ChatMessageItemCommon

final class ExteraReactionVisibilityTests: XCTestCase {
    func testEachSwitchOnlyAffectsItsOwnChatKind() {
        for channels in [false, true] {
            for groups in [false, true] {
                for privateChats in [false, true] {
                    XCTAssertEqual(exteraHideReactions(kind: .channel, channels: channels, groups: groups, privateChats: privateChats), channels)
                    XCTAssertEqual(exteraHideReactions(kind: .group, channels: channels, groups: groups, privateChats: privateChats), groups)
                    XCTAssertEqual(exteraHideReactions(kind: .privateChat, channels: channels, groups: groups, privateChats: privateChats), privateChats)
                    XCTAssertFalse(exteraHideReactions(kind: .unknown, channels: channels, groups: groups, privateChats: privateChats))
                }
            }
        }
    }

    func testMissingUserAndSecretChatPeersStillUsePrivateSetting() {
        XCTAssertEqual(exteraReactionChatKind(peer: nil, namespace: Namespaces.Peer.CloudUser), .privateChat)
        XCTAssertEqual(exteraReactionChatKind(peer: nil, namespace: Namespaces.Peer.SecretChat), .privateChat)
    }

    func testLegacyGroupNamespaceRemainsGroupWithoutPeerObject() {
        XCTAssertEqual(exteraReactionChatKind(peer: nil, namespace: Namespaces.Peer.CloudGroup), .group)
    }

    func testBroadcastChannelAndSupergroupUseDifferentSwitches() {
        let broadcast = makeBroadcastChannel(id: 42, messagesShouldHaveProfiles: false)
        let supergroup = makeGroupChannel(id: 43)
        XCTAssertEqual(exteraReactionChatKind(peer: broadcast, namespace: broadcast.id.namespace), .channel)
        XCTAssertEqual(exteraReactionChatKind(peer: supergroup, namespace: supergroup.id.namespace), .group)
        let user = makeUser(id: 44)
        XCTAssertEqual(exteraReactionChatKind(peer: user, namespace: user.id.namespace), .privateChat)
    }

    func testMissingChannelPeerIsNotMistakenForSupergroup() {
        XCTAssertEqual(exteraReactionChatKind(peer: nil, namespace: Namespaces.Peer.CloudChannel), .unknown)
        XCTAssertEqual(exteraReactionChatKind(peer: nil, namespace: .max), .unknown)
    }
}
