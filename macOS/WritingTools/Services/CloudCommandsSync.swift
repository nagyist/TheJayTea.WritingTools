//
//  CloudCommandsSync.swift
//  WritingTools
//
//  Created by Arya Mirsepasi on 15.08.25.
//

import Foundation

private let logger = AppLogger.logger("CloudCommandsSync")

@MainActor
final class CloudCommandsSync {
  static let shared = CloudCommandsSync()

  private let store = NSUbiquitousKeyValueStore.default

  // Keys for the "full command list" (edited built-ins + custom)
  private let dataKey = "icloud.commandManager.commands.v1.data"
  private let mtimeKey = "icloud.commandManager.commands.v1.mtime"
  private let localMTimeKey = "local.commandManager.commands.v1.mtime"

  private var started = false
  private var isApplyingCloudChange = false
  private var syncInProgress = false
  private var pendingSync = false

  private var commandsChangedObserver: NSObjectProtocol?
  private var kvsObserver: NSObjectProtocol?
  private var pushDebounceTask: Task<Void, Never>?
  private let pushDebounceDelay: Duration = .milliseconds(300)

  private init() {
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

    // Initial pull from iCloud if remote is newer
    schedulePull()

    // Listen for your app's commands change notification
    commandsChangedObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("CommandsChanged"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // Ensure we run on the MainActor
      Task { @MainActor in
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
    isApplyingCloudChange = false
  }

  deinit {
    if let commandsChangedObserver {
      NotificationCenter.default.removeObserver(commandsChangedObserver)
    }
    if let kvsObserver {
      NotificationCenter.default.removeObserver(kvsObserver)
    }
    pushDebounceTask?.cancel()
  }

  // MARK: - Push local -> iCloud

  private func schedulePush() {
    guard !isApplyingCloudChange else { return }

    pushDebounceTask?.cancel()
    pushDebounceTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: self.pushDebounceDelay)
      guard !Task.isCancelled else { return }
      self.pushLocalToICloud()
    }
  }

  private func pushLocalToICloud() {
    guard !isApplyingCloudChange else { return }

    let commands = AppState.shared.commandManager.commands

    do {
      let data = try JSONEncoder().encode(commands)
      let now = Date()

      store.set(data, forKey: dataKey)
      store.set(now, forKey: mtimeKey)

      UserDefaults.standard.set(now, forKey: localMTimeKey)
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

    guard localMTime == nil || remoteMTime > localMTime! else {
      return
    }

    guard let data = store.data(forKey: dataKey) else { return }

    do {
      let remoteCommands = try JSONDecoder().decode([CommandModel].self, from: data)

      isApplyingCloudChange = true
      defer { isApplyingCloudChange = false }

      AppState.shared.commandManager.replaceAllCommands(with: remoteCommands)
      UserDefaults.standard.set(remoteMTime, forKey: localMTimeKey)
    } catch {
      logger.error("CloudCommandsSync: decode error: \(error.localizedDescription)")
    }
  }

  private func handleICloudChange(_ note: Notification) {
    guard
      let userInfo = note.userInfo,
      let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
    else { return }

    guard reason == NSUbiquitousKeyValueStoreServerChange
      || reason == NSUbiquitousKeyValueStoreInitialSyncChange
    else {
      return
    }

    if
      let changedKeys =
        userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
      changedKeys.contains(where: { $0 == dataKey || $0 == mtimeKey })
    {
      schedulePull()
    }
  }
}
