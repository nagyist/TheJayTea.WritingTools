//
//  CloudCommandsSync.swift
//  WritingTools
//
//  Created by Arya Mirsepasi on 15.08.25.
//

import Foundation

private let logger = AppLogger.logger("CloudCommandsSync")

extension Notification.Name {
  static let iCloudCommandSyncQuotaExceeded = Notification.Name("iCloudCommandSyncQuotaExceeded")
}

enum CloudCommandsSyncUserInfoKey {
  static let payloadBytes = "payloadBytes"
  static let totalBytes = "totalBytes"
  static let reason = "reason"
}

@MainActor
final class CloudCommandsSync {
  enum SyncHealth: Equatable {
    case idle
    case synced
    case quotaLimited(reason: String, payloadBytes: Int?, totalBytes: Int?)
  }

  static let shared = CloudCommandsSync()

  private let store = NSUbiquitousKeyValueStore.default

  // Keys for the "full command list" (edited built-ins + custom)
  private let dataKey = "icloud.commandManager.commands.v1.data"
  private let mtimeKey = "icloud.commandManager.commands.v1.mtime"
  private let deletedIdsKey = "icloud.commandManager.commands.v1.deleted_ids"
  private let localMTimeKey = "local.commandManager.commands.v1.mtime"
  private let localDeletedIdsKey = "local.commandManager.commands.v1.deleted_ids"
  private let localDeletedTimestampByIdKey = "local.commandManager.commands.v1.deleted_ts_by_id"
  private let localKnownIdsKey = "local.commandManager.commands.v1.known_ids"

  private var started = false
  /// Monotonic counter incremented each time a cloud pull applies changes.
  /// Push is suppressed when the counter changes between scheduling and execution.
  private var cloudApplyGeneration: UInt64 = 0
  private var syncInProgress = false
  private var pendingSync = false
  /// Brief suppression flag set while applying remote changes to prevent
  /// the `CommandsChanged` notification from triggering a redundant push.
  private var suppressPush = false
  private var lastQuotaWarningDate: Date?
  private var deletedCommandIds: Set<UUID> = []
  private var deletedCommandTimestamps: [UUID: Date] = [:]
  private var knownLocalCommandIds: Set<UUID> = []
  private(set) var syncHealth: SyncHealth = .idle

  private var commandsChangedObserver: NSObjectProtocol?
  private var kvsObserver: NSObjectProtocol?
  private var pushDebounceTask: Task<Void, Never>?
  private let pushDebounceDelay: Duration = .milliseconds(300)
  private let kvsValueQuotaBytes = 1_000_000
  private let quotaWarningDebounceInterval: TimeInterval = 30
  private let maxDeletedTombstones = 512

  private init() {
    loadLocalSyncState()
    // Started explicitly by AppDelegate based on user preference.
  }

  func setEnabled(_ enabled: Bool) {
    if enabled {
      start()
    } else {
      stop()
    }
  }

  func start() {
    guard !started else { return }
    started = true
    bootstrapKnownLocalIdsIfNeeded()

    // Initial pull from iCloud if remote is newer
    schedulePull()

    // Listen for your app's commands change notification
    commandsChangedObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("CommandsChanged"),
      object: nil,
      queue: nil
    ) { [weak self] _ in
      guard Thread.isMainThread else {
        logger.error("CloudCommandsSync: CommandsChanged received off main thread; skipping synchronous push schedule")
        return
      }
      MainActor.assumeIsolated {
        self?.schedulePush()
      }
    }

    // Listen for iCloud server changes
    kvsObserver = NotificationCenter.default.addObserver(
      forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
      object: store,
      queue: .main
    ) { [weak self] note in
      // Hop to MainActor before calling a MainActor-isolated method
      Task { @MainActor in
        self?.handleICloudChange(note)
      }
    }

    _ = store.synchronize()
  }

  func stop() {
    guard started else { return }
    started = false

    if let commandsChangedObserver {
      NotificationCenter.default.removeObserver(commandsChangedObserver)
      self.commandsChangedObserver = nil
    }
    if let kvsObserver {
      NotificationCenter.default.removeObserver(kvsObserver)
      self.kvsObserver = nil
    }
    pushDebounceTask?.cancel()
    pushDebounceTask = nil
    syncInProgress = false
    pendingSync = false
    syncHealth = .idle
  }

  /// Cancel any pending debounce, push local commands immediately, and
  /// call `synchronize()` to flush the KVS write to the daemon before
  /// the process exits. Call from `applicationWillTerminate`.
  func flushAndSynchronize() {
    guard started else { return }
    pushDebounceTask?.cancel()
    pushDebounceTask = nil
    pushLocalToICloud()
    _ = store.synchronize()
  }

  // MARK: - Push local -> iCloud

  private func schedulePush() {
    // Skip pushes triggered by applying remote changes
    guard !suppressPush else { return }

    let generationAtSchedule = cloudApplyGeneration

    pushDebounceTask?.cancel()
    pushDebounceTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: self.pushDebounceDelay)
      guard !Task.isCancelled else { return }
      // Skip the push if a cloud pull happened since this push was scheduled
      guard self.cloudApplyGeneration == generationAtSchedule else { return }
      self.pushLocalToICloud()
    }
  }

  private func pushLocalToICloud() {

    let commands = AppState.shared.commandManager.commands
    let now = Date()
    let currentIds = Set(commands.map(\.id))
    let removedIds = knownLocalCommandIds.subtracting(currentIds)

    // Persist local deletion intent so it survives restarts/offline periods.
    deletedCommandIds.formUnion(removedIds)
    for id in removedIds where deletedCommandTimestamps[id] == nil {
      deletedCommandTimestamps[id] = now
    }
    // Undelete semantics: if a command exists locally, it should not remain tombstoned.
    deletedCommandIds.subtract(currentIds)
    for id in currentIds {
      deletedCommandTimestamps[id] = nil
    }
    _ = compactDeletedTombstones(maxCount: maxDeletedTombstones, maxDeletedIdsBytes: nil)
    knownLocalCommandIds = currentIds
    persistLocalSyncState()

    do {
      let data = try JSONEncoder().encode(commands)
      let dataBytes = estimatedKVSValueSize(of: data)
      guard dataBytes <= kvsValueQuotaBytes else {
        logger.error("CloudCommandsSync: push skipped because encoded command payload exceeds iCloud KVS value quota (\(dataBytes) bytes)")
        postQuotaWarningIfNeeded(
          payloadBytes: dataBytes,
          totalBytes: nil,
          reason: "preflight_payload_too_large"
        )
        return
      }

      var deletedIdsPayload = encodeUUIDSet(deletedCommandIds)
      var preflight = preflightBudget(
        commandData: data,
        deletedIdsPayload: deletedIdsPayload,
        mtime: now
      )

      if !preflight.isWithinQuota {
        let deletedIdsBudget =
          max(0, kvsValueQuotaBytes - preflight.nonManagedBytes - preflight.commandBytes - preflight.mtimeBytes)
        if compactDeletedTombstones(maxCount: maxDeletedTombstones, maxDeletedIdsBytes: deletedIdsBudget) {
          deletedIdsPayload = encodeUUIDSet(deletedCommandIds)
          preflight = preflightBudget(
            commandData: data,
            deletedIdsPayload: deletedIdsPayload,
            mtime: now
          )
          persistLocalSyncState()
        }
      }

      guard preflight.isWithinQuota else {
        logger.error(
          "CloudCommandsSync: push skipped because estimated iCloud KVS total (\(preflight.totalBytes) bytes) exceeds quota"
        )
        postQuotaWarningIfNeeded(
          payloadBytes: preflight.commandBytes,
          totalBytes: preflight.totalBytes,
          reason: "preflight_total_store_too_large"
        )
        return
      }

      store.set(data, forKey: dataKey)
      if deletedIdsPayload.isEmpty {
        store.removeObject(forKey: deletedIdsKey)
      } else {
        store.set(deletedIdsPayload, forKey: deletedIdsKey)
      }
      store.set(now, forKey: mtimeKey)

      UserDefaults.standard.set(now, forKey: localMTimeKey)
      syncHealth = .synced
    } catch {
      logger.error("CloudCommandsSync: encode error: \(error.localizedDescription)")
    }
  }

  // MARK: - Pull iCloud -> local (if newer)

  private func schedulePull() {
    if syncInProgress {
      pendingSync = true
      return
    }

    syncInProgress = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.syncInProgress = false
        if self.pendingSync {
          self.pendingSync = false
          self.schedulePull()
        }
      }
      await self.pullFromICloudIfNewer()
    }
  }

  private func pullFromICloudIfNewer() async {
    guard let remoteMTime = store.object(forKey: mtimeKey) as? Date else {
      return
    }
    let localMTime =
      UserDefaults.standard.object(forKey: localMTimeKey) as? Date

    guard localMTime.map({ remoteMTime > $0 }) ?? true else {
      return
    }

    do {
      let remoteCommands: [CommandModel]
      if let data = store.data(forKey: dataKey) {
        remoteCommands = try JSONDecoder().decode([CommandModel].self, from: data)
      } else {
        remoteCommands = []
      }
      let remoteDeletedCommandIds = decodeUUIDSet(
        from: store.array(forKey: deletedIdsKey) as? [String]
      )
      for id in remoteDeletedCommandIds where deletedCommandTimestamps[id] == nil {
        deletedCommandTimestamps[id] = remoteMTime
      }

      // Cancel any in-flight push and increment the generation counter so
      // any push scheduled after the debounce period also gets skipped.
      pushDebounceTask?.cancel()
      pushDebounceTask = nil
      cloudApplyGeneration &+= 1

      // Per-command merge: instead of replacing the entire local list,
      // merge by command ID. Remote versions win for shared commands,
      // local-only commands are preserved, and remote-only commands are added.
      let localCommands = AppState.shared.commandManager.commands
      var effectiveTombstones = deletedCommandIds.union(remoteDeletedCommandIds)
      var mergedCommands = mergeCommands(local: localCommands, remote: remoteCommands)
      mergedCommands.removeAll { effectiveTombstones.contains($0.id) }
      // If a command currently exists after merge, it is no longer deleted.
      effectiveTombstones.subtract(mergedCommands.map(\.id))

      // Suppress pushes while applying remote changes. The `replaceAllCommands`
      // call fires a `CommandsChanged` notification which would otherwise
      // schedule a redundant push-back of the data we just received.
      do {
        suppressPush = true
        defer { suppressPush = false }
        AppState.shared.commandManager.replaceAllCommands(with: mergedCommands)
      }

      deletedCommandIds = effectiveTombstones
      deletedCommandTimestamps = deletedCommandTimestamps.filter { effectiveTombstones.contains($0.key) }
      _ = compactDeletedTombstones(maxCount: maxDeletedTombstones, maxDeletedIdsBytes: nil)
      knownLocalCommandIds = Set(mergedCommands.map(\.id))
      persistLocalSyncState()
      UserDefaults.standard.set(remoteMTime, forKey: localMTimeKey)
      syncHealth = .synced
    } catch {
      logger.error("CloudCommandsSync: decode error: \(error.localizedDescription)")
    }
  }

  /// Merges local and remote command lists by command ID.
  ///
  /// Strategy:
  /// - Commands present in both: use the remote version (remote is newer since
  ///   we only pull when `remoteMTime > localMTime`).
  /// - Commands only in remote: add them (new from another device).
  /// - Commands only in local: keep them (created locally, not yet pushed).
  ///
  /// Ordering follows the remote list, with local-only commands appended at the end.
  private func mergeCommands(local: [CommandModel], remote: [CommandModel]) -> [CommandModel] {
    let remoteIds = Set(remote.map(\.id))

    // Start with the remote list (preserving remote ordering and content)
    var merged = remote

    // Append any local-only commands (not present in remote) at the end
    for command in local where !remoteIds.contains(command.id) {
      merged.append(command)
    }

    return merged
  }

  private func handleICloudChange(_ note: Notification) {
    guard
      let userInfo = note.userInfo,
      let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
    else { return }

    if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
      logger.error("CloudCommandsSync: received iCloud KVS quota violation change notification")
      postQuotaWarningIfNeeded(
        payloadBytes: nil,
        totalBytes: nil,
        reason: "quota_violation_notification"
      )
      return
    }

    guard reason == NSUbiquitousKeyValueStoreServerChange
      || reason == NSUbiquitousKeyValueStoreInitialSyncChange
    else {
      return
    }

    if
      let changedKeys =
        userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
      changedKeys.contains(where: { $0 == dataKey || $0 == mtimeKey || $0 == deletedIdsKey })
    {
      schedulePull()
    }
  }

  private func bootstrapKnownLocalIdsIfNeeded() {
    guard knownLocalCommandIds.isEmpty else { return }
    knownLocalCommandIds = Set(AppState.shared.commandManager.commands.map(\.id))
    persistLocalSyncState()
  }

  private func loadLocalSyncState() {
    let defaults = UserDefaults.standard
    deletedCommandIds = decodeUUIDSet(from: defaults.stringArray(forKey: localDeletedIdsKey))
    deletedCommandTimestamps = decodeDeletedCommandTimestamps(
      from: defaults.dictionary(forKey: localDeletedTimestampByIdKey)
    )
    // Keep timestamp map aligned with tombstone set, and seed missing entries.
    deletedCommandTimestamps = deletedCommandTimestamps.filter { deletedCommandIds.contains($0.key) }
    for id in deletedCommandIds where deletedCommandTimestamps[id] == nil {
      deletedCommandTimestamps[id] = .distantPast
    }
    knownLocalCommandIds = decodeUUIDSet(from: defaults.stringArray(forKey: localKnownIdsKey))
  }

  private func persistLocalSyncState() {
    let defaults = UserDefaults.standard
    defaults.set(encodeUUIDSet(deletedCommandIds), forKey: localDeletedIdsKey)
    defaults.set(
      encodeDeletedCommandTimestamps(deletedCommandTimestamps),
      forKey: localDeletedTimestampByIdKey
    )
    defaults.set(encodeUUIDSet(knownLocalCommandIds), forKey: localKnownIdsKey)
  }

  private func encodeUUIDSet(_ ids: Set<UUID>) -> [String] {
    ids.map(\.uuidString).sorted()
  }

  private func decodeUUIDSet(from rawValues: [String]?) -> Set<UUID> {
    Set((rawValues ?? []).compactMap(UUID.init(uuidString:)))
  }

  private func encodeDeletedCommandTimestamps(_ timestamps: [UUID: Date]) -> [String: TimeInterval] {
    var encoded: [String: TimeInterval] = [:]
    for (id, date) in timestamps {
      encoded[id.uuidString] = date.timeIntervalSince1970
    }
    return encoded
  }

  private func decodeDeletedCommandTimestamps(from rawValues: [String: Any]?) -> [UUID: Date] {
    var decoded: [UUID: Date] = [:]
    for (rawId, rawTimestamp) in rawValues ?? [:] {
      guard let id = UUID(uuidString: rawId) else { continue }
      if let timestampNumber = rawTimestamp as? NSNumber {
        decoded[id] = Date(timeIntervalSince1970: timestampNumber.doubleValue)
      }
    }
    return decoded
  }

  private func compactDeletedTombstones(maxCount: Int, maxDeletedIdsBytes: Int?) -> Bool {
    guard !deletedCommandIds.isEmpty else { return false }

    let sortedIds = deletedCommandIds.sorted { lhs, rhs in
      let lhsDate = deletedCommandTimestamps[lhs] ?? .distantPast
      let rhsDate = deletedCommandTimestamps[rhs] ?? .distantPast
      if lhsDate == rhsDate {
        return lhs.uuidString < rhs.uuidString
      }
      return lhsDate > rhsDate
    }

    var keptIds: [UUID] = []
    let cappedCount = max(0, maxCount)
    for id in sortedIds {
      guard keptIds.count < cappedCount else { break }
      let candidate = keptIds + [id]
      if let maxDeletedIdsBytes {
        let candidateBytes = estimatedKVSValueSize(of: candidate.map(\.uuidString))
        if candidateBytes > maxDeletedIdsBytes {
          continue
        }
      }
      keptIds.append(id)
    }

    let newSet = Set(keptIds)
    guard newSet != deletedCommandIds else { return false }

    let removedCount = deletedCommandIds.count - newSet.count
    deletedCommandIds = newSet
    deletedCommandTimestamps = deletedCommandTimestamps.filter { newSet.contains($0.key) }
    logger.warning("CloudCommandsSync: compacted \(removedCount) deleted-command tombstones")
    return true
  }

  private struct KVSPreflightResult {
    let commandBytes: Int
    let deletedIdsBytes: Int
    let mtimeBytes: Int
    let nonManagedBytes: Int
    let totalBytes: Int
    let isWithinQuota: Bool
  }

  private func preflightBudget(
    commandData: Data,
    deletedIdsPayload: [String],
    mtime: Date
  ) -> KVSPreflightResult {
    let managedKeys: Set<String> = [dataKey, deletedIdsKey, mtimeKey]
    let nonManagedBytes = store.dictionaryRepresentation.reduce(into: 0) { partialResult, entry in
      guard !managedKeys.contains(entry.key) else { return }
      partialResult += estimatedKVSValueSize(of: entry.value)
    }

    let commandBytes = estimatedKVSValueSize(of: commandData)
    let deletedIdsBytes = deletedIdsPayload.isEmpty ? 0 : estimatedKVSValueSize(of: deletedIdsPayload)
    let mtimeBytes = estimatedKVSValueSize(of: mtime)
    let totalBytes = nonManagedBytes + commandBytes + deletedIdsBytes + mtimeBytes

    let isWithinPerValueLimit =
      commandBytes <= kvsValueQuotaBytes
      && deletedIdsBytes <= kvsValueQuotaBytes
      && mtimeBytes <= kvsValueQuotaBytes

    return KVSPreflightResult(
      commandBytes: commandBytes,
      deletedIdsBytes: deletedIdsBytes,
      mtimeBytes: mtimeBytes,
      nonManagedBytes: nonManagedBytes,
      totalBytes: totalBytes,
      isWithinQuota: isWithinPerValueLimit && totalBytes <= kvsValueQuotaBytes
    )
  }

  private func estimatedKVSValueSize(of value: Any) -> Int {
    guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else {
      return 0
    }
    guard let data = try? PropertyListSerialization.data(
      fromPropertyList: value,
      format: .binary,
      options: 0
    ) else {
      return 0
    }
    return data.count
  }

  private func postQuotaWarningIfNeeded(payloadBytes: Int?, totalBytes: Int?, reason: String) {
    let now = Date()
    if let lastQuotaWarningDate,
       now.timeIntervalSince(lastQuotaWarningDate) < quotaWarningDebounceInterval {
      return
    }
    lastQuotaWarningDate = now
    syncHealth = .quotaLimited(reason: reason, payloadBytes: payloadBytes, totalBytes: totalBytes)

    var userInfo: [String: Any] = [
      CloudCommandsSyncUserInfoKey.reason: reason
    ]
    if let payloadBytes {
      userInfo[CloudCommandsSyncUserInfoKey.payloadBytes] = payloadBytes
    }
    if let totalBytes {
      userInfo[CloudCommandsSyncUserInfoKey.totalBytes] = totalBytes
    }

    NotificationCenter.default.post(
      name: .iCloudCommandSyncQuotaExceeded,
      object: nil,
      userInfo: userInfo
    )
  }
}
