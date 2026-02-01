import Foundation
import Observation

private let logger = AppLogger.logger("CustomCommandsManager")

struct CustomCommand: Codable, Identifiable, Equatable {
  let id: UUID
  var name: String
  var prompt: String
  var icon: String
  var useResponseWindow: Bool

  init(
    id: UUID = UUID(),
    name: String,
    prompt: String,
    icon: String,
    useResponseWindow: Bool = false
  ) {
    self.id = id
    self.name = name
    self.prompt = prompt
    self.icon = icon
    self.useResponseWindow = useResponseWindow
  }
}

@Observable
final class CustomCommandsManager {
  private(set) var commands: [CustomCommand] = []

  private let saveKey = "custom_commands"

  // iCloud KVS
  private let iCloudStore = NSUbiquitousKeyValueStore.default
  private let iCloudDataKey = "icloud.custom_commands.v1.data"
  private let iCloudMTimeKey = "icloud.custom_commands.v1.mtime"
  private let localMTimeDefaultsKey = "custom_commands_mtime.v1"

  // Synchronization queue for thread-safe iCloud operations
  private let syncQueue = DispatchQueue(label: "com.writingtools.customcommands.sync")

  // Prevents push loops when applying remote changes (accessed only on syncQueue)
  private var isApplyingCloudChange = false

  // Track pending local changes during cloud sync
  private var pendingLocalSave = false

  private var kvsObserver: NSObjectProtocol?

  init() {
    // Load local first
    loadLocalCommands()

    // Start iCloud sync
    // Pull from iCloud if newer than local
    pullFromICloudIfNewer()

    // Observe KVS remote changes
    kvsObserver = NotificationCenter.default.addObserver(
      forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
      object: iCloudStore,
      queue: .main
    ) { [weak self] note in
      self?.handleICloudChange(note)
    }
  }

  deinit {
    if let kvsObserver {
      NotificationCenter.default.removeObserver(kvsObserver)
    }
  }

  // MARK: - Public API

  func addCommand(_ command: CustomCommand) {
    commands.append(command)
    saveCommands()
  }

  func updateCommand(_ command: CustomCommand) {
    if let index = commands.firstIndex(where: { $0.id == command.id }) {
      commands[index] = command
      saveCommands()
    }
  }

  func deleteCommand(_ command: CustomCommand) {
    commands.removeAll { $0.id == command.id }
    saveCommands()
  }

  // Replace all custom commands at once (kept for your existing usage)
  func replaceCommands(with newCommands: [CustomCommand]) {
    commands = newCommands
    saveCommands()
  }

  // MARK: - Local persistence

  private func loadLocalCommands() {
    if
      let data = UserDefaults.standard.data(forKey: saveKey),
      let decoded = try? JSONDecoder().decode([CustomCommand].self, from: data)
    {
      commands = decoded
    }
  }

  private func saveLocalCommands() {
    if let encoded = try? JSONEncoder().encode(commands) {
      UserDefaults.standard.set(encoded, forKey: saveKey)
    }
  }

  // MARK: - iCloud sync

  // Push local -> iCloud, with modified time (thread-safe)
  private func pushToICloud() {
    // Capture current commands for encoding
    let currentCommands = commands

    syncQueue.async { [weak self] in
      guard let self else { return }

      // If we're applying cloud changes, mark as pending and defer
      guard !self.isApplyingCloudChange else {
        self.pendingLocalSave = true
        return
      }

      do {
        let data = try JSONEncoder().encode(currentCommands)
        let now = Date()

        DispatchQueue.main.async {
          self.iCloudStore.set(data, forKey: self.iCloudDataKey)
          self.iCloudStore.set(now, forKey: self.iCloudMTimeKey)
          UserDefaults.standard.set(now, forKey: self.localMTimeDefaultsKey)
        }
      } catch {
        logger.error("CustomCommandsManager: Failed to encode for iCloud: \(error.localizedDescription)")
      }
    }
  }

  // Pull iCloud -> local if iCloud is newer (thread-safe)
  private func pullFromICloudIfNewer() {
    syncQueue.async { [weak self] in
      guard let self else { return }

      guard let remoteMTime = self.iCloudStore.object(forKey: self.iCloudMTimeKey) as? Date
      else { return }

      let localMTime =
        UserDefaults.standard.object(forKey: self.localMTimeDefaultsKey) as? Date

      guard localMTime == nil || remoteMTime > localMTime! else {
        return
      }

      guard let data = self.iCloudStore.data(forKey: self.iCloudDataKey) else { return }

      do {
        let remoteCommands =
          try JSONDecoder().decode([CustomCommand].self, from: data)

        self.isApplyingCloudChange = true

        // Update commands on main thread since it's @Observable
        DispatchQueue.main.async {
          self.commands = remoteCommands
          self.saveLocalCommands()

          // Update local mtime after applying
          UserDefaults.standard.set(remoteMTime, forKey: self.localMTimeDefaultsKey)

          // Mark cloud change as complete on sync queue
          self.syncQueue.async {
            self.isApplyingCloudChange = false

            // If there was a pending local save during cloud sync, push it now
            if self.pendingLocalSave {
              self.pendingLocalSave = false
              DispatchQueue.main.async {
                self.pushToICloud()
              }
            }
          }
        }
      } catch {
        self.isApplyingCloudChange = false
        logger.error("CustomCommandsManager: Failed to decode from iCloud: \(error.localizedDescription)")
      }
    }
  }

  private func handleICloudChange(_ note: Notification) {
    guard
      let userInfo = note.userInfo,
      let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey]
        as? Int
    else { return }

    guard reason == NSUbiquitousKeyValueStoreServerChange
      || reason == NSUbiquitousKeyValueStoreInitialSyncChange
    else {
      return
    }

    if
      let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey]
        as? [String],
      changedKeys.contains(where: { $0 == iCloudDataKey || $0 == iCloudMTimeKey })
    {
      pullFromICloudIfNewer()
    }
  }

  // Save both locally and to iCloud
  private func saveCommands() {
    saveLocalCommands()

    // Update local modified time first
    let now = Date()
    UserDefaults.standard.set(now, forKey: localMTimeDefaultsKey)

    // Push to iCloud unless we’re applying a remote change
    pushToICloud()
  }
}
