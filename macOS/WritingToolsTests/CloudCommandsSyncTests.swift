import Foundation
import XCTest
@testable import WritingTools

final class CloudCommandsSyncTests: XCTestCase {
    func testReasonClassificationIncludesAccountChange() {
        XCTAssertTrue(CloudCommandsSync.isServerDrivenPullReason(NSUbiquitousKeyValueStoreServerChange))
        XCTAssertTrue(CloudCommandsSync.isServerDrivenPullReason(NSUbiquitousKeyValueStoreInitialSyncChange))
        XCTAssertTrue(CloudCommandsSync.isAccountChangeReason(NSUbiquitousKeyValueStoreAccountChange))
        XCTAssertFalse(CloudCommandsSync.isServerDrivenPullReason(NSUbiquitousKeyValueStoreAccountChange))
    }

    func testRelevantChangedKeyDetection() {
        XCTAssertTrue(
            CloudCommandsSync.hasRelevantChangedKeys(
                ["icloud.commandManager.commands.v1.mtime"],
                dataKey: "icloud.commandManager.commands.v1.data",
                mtimeKey: "icloud.commandManager.commands.v1.mtime",
                deletedIdsKey: "icloud.commandManager.commands.v1.deleted_ids"
            )
        )

        XCTAssertFalse(
            CloudCommandsSync.hasRelevantChangedKeys(
                ["unrelated.key"],
                dataKey: "icloud.commandManager.commands.v1.data",
                mtimeKey: "icloud.commandManager.commands.v1.mtime",
                deletedIdsKey: "icloud.commandManager.commands.v1.deleted_ids"
            )
        )
    }
}
