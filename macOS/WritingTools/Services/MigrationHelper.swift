import Foundation

/// A utility class to help migrate from the old WritingOption/CustomCommand system
/// to the new unified CommandModel system
@MainActor
class MigrationHelper {
    static let shared = MigrationHelper()
    
    private let migrationCompletedKey = "command_migration_completed"
    
    private init() {}
    
    /// Checks if migration has been completed
    var isMigrationCompleted: Bool {
        return UserDefaults.standard.bool(forKey: migrationCompletedKey)
    }
    
    /// Performs migration from the old system to the new CommandManager system.
    /// Only marks migration as complete if `migrateFromLegacySystems` succeeds
    /// (i.e. does not throw or crash). If the app is killed mid-migration the
    /// flag will remain false and migration will be re-attempted on next launch.
    func migrateIfNeeded(commandManager: CommandManager, customCommandsManager: CustomCommandsManager) {
        // Skip if already migrated
        if isMigrationCompleted {
            return
        }
        
        let commandsBefore = commandManager.commands.count
        
        // Migrate custom commands
        commandManager.migrateFromLegacySystems(customCommands: customCommandsManager.commands)
        
        // Only mark migration as complete if commands were loaded successfully
        // (the manager should have at least the built-in commands after migration)
        if !commandManager.commands.isEmpty || commandsBefore == 0 {
            UserDefaults.standard.set(true, forKey: migrationCompletedKey)
        }
    }
    
    /// Forces a re-migration (for testing or if needed)
    func forceMigration(commandManager: CommandManager, customCommandsManager: CustomCommandsManager) {
        // Reset migration flag
        UserDefaults.standard.set(false, forKey: migrationCompletedKey)
        
        // Perform migration
        migrateIfNeeded(commandManager: commandManager, customCommandsManager: customCommandsManager)
    }
} 