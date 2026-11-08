import Foundation
import Observation

/// How long LPM Vault stays unlocked without input before it locks itself.
enum VaultLockInterval: Int, CaseIterable, Identifiable, Sendable {
	case oneMinute = 60
	case twoMinutes = 120
	case fiveMinutes = 300
	case fifteenMinutes = 900
	case thirtyMinutes = 1800

	static let standard = VaultLockInterval.twoMinutes

	var id: Int { rawValue }
	var seconds: TimeInterval { TimeInterval(rawValue) }
	var title: String { VaultSettingsDuration.title(seconds: rawValue) }
}

/// When revealing or copying a value asks for Touch ID or the Mac's
/// password again, while the vault stays unlocked.
enum VaultValueApproval: Int, CaseIterable, Identifiable, Sendable {
	/// Unlocking is enough.
	case never = 0
	case afterFiveMinutes = 300
	case afterFifteenMinutes = 900

	static let standard = VaultValueApproval.never

	var id: Int { rawValue }
	/// How long an approval holds, or nil when one is never asked for.
	var seconds: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }
	var title: String { self == .never ? "Never" : "After \(VaultSettingsDuration.title(seconds: rawValue))" }
}

/// How long a copied value stays on the clipboard.
enum VaultClipboardClear: Int, CaseIterable, Identifiable, Sendable {
	case tenSeconds = 10
	case thirtySeconds = 30
	case oneMinute = 60
	case twoMinutes = 120

	static let standard = VaultClipboardClear.tenSeconds

	var id: Int { rawValue }
	var seconds: TimeInterval { TimeInterval(rawValue) }
	var title: String { VaultSettingsDuration.title(seconds: rawValue) }
	/// The time a copy toast says the clipboard clears in: "10s", "1 min".
	var countdown: String { rawValue < 60 ? "\(rawValue)s" : "\(rawValue / 60) min" }
}

/// How long a revealed value stays shown before it's masked again.
enum VaultRehideInterval: Int, CaseIterable, Identifiable, Sendable {
	case never = 0
	case thirtySeconds = 30
	case oneMinute = 60
	case fiveMinutes = 300

	static let standard = VaultRehideInterval.never

	var id: Int { rawValue }
	var seconds: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }
	var title: String { self == .never ? "Never" : "After \(VaultSettingsDuration.title(seconds: rawValue))" }
}

/// A setting's duration as its menu names it: "10 sec", "1 min", "30 min".
enum VaultSettingsDuration {
	static func title(seconds: Int) -> String {
		seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min"
	}

	/// The same duration in words, for a sentence: "10 seconds", "1 minute".
	static func phrase(seconds: Int) -> String {
		seconds < 60 ? seconds.counted("second") : (seconds / 60).counted("minute")
	}
}

/// LPM Vault's own settings that aren't a single control's: how the vault
/// locks and guards its values, what a new project starts with, and the
/// backup reminder. Each is saved in `defaults` as it changes, and read
/// back as its default when what's saved isn't one of its choices.
@Observable
@MainActor
final class VaultSettings {
	enum Key {
		static let lockAfter = "lpm-vault-lock-after"
		static let valueApproval = "lpm-vault-value-approval"
		static let clipboardClear = "lpm-vault-clipboard-clear"
		static let rehide = "lpm-vault-rehide-values"
		static let hidesFromCapture = "lpm-vault-hides-from-capture"
		static let newProjectHistory = "lpm-vault-new-project-history"
		static let newProjectCLIApproval = "lpm-vault-new-project-cli-approval"
		static let backupReminder = "lpm-vault-backup-reminder"
	}

	/// What changed, for the parts of the app that act on it at once.
	enum Change: Sendable {
		case lockAfter, valueApproval, clipboardClear, rehide, hidesFromCapture
	}

	@ObservationIgnored private let defaults: UserDefaults
	/// Called after a setting the running app acts on changes.
	@ObservationIgnored var onChange: (@MainActor (Change) -> Void)?

	var lockAfter: VaultLockInterval {
		didSet { save(lockAfter.rawValue, Key.lockAfter, changed: lockAfter != oldValue ? .lockAfter : nil) }
	}
	var valueApproval: VaultValueApproval {
		didSet { save(valueApproval.rawValue, Key.valueApproval, changed: valueApproval != oldValue ? .valueApproval : nil) }
	}
	var clipboardClear: VaultClipboardClear {
		didSet { save(clipboardClear.rawValue, Key.clipboardClear, changed: clipboardClear != oldValue ? .clipboardClear : nil) }
	}
	var rehide: VaultRehideInterval {
		didSet { save(rehide.rawValue, Key.rehide, changed: rehide != oldValue ? .rehide : nil) }
	}
	/// Whether LPM Vault's windows are left out of screenshots, recordings and screen sharing.
	var hidesFromCapture: Bool {
		didSet { save(hidesFromCapture, Key.hidesFromCapture, changed: hidesFromCapture != oldValue ? .hidesFromCapture : nil) }
	}
	/// Whether a project created in LPM Vault keeps local history.
	var newProjectsKeepHistory: Bool {
		didSet { save(newProjectsKeepHistory, Key.newProjectHistory) }
	}
	/// Whether a project created in LPM Vault asks before the CLI reads its values.
	var newProjectsAskBeforeCLIReads: Bool {
		didSet { save(newProjectsAskBeforeCLIReads, Key.newProjectCLIApproval) }
	}
	/// Whether LPM Vault reminds the person to back up once a month.
	var remindsToBackUp: Bool {
		didSet { save(remindsToBackUp, Key.backupReminder) }
	}

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		lockAfter = Self.choice(defaults, Key.lockAfter) ?? .standard
		valueApproval = Self.choice(defaults, Key.valueApproval) ?? .standard
		clipboardClear = Self.choice(defaults, Key.clipboardClear) ?? .standard
		rehide = Self.choice(defaults, Key.rehide) ?? .standard
		hidesFromCapture = Self.flag(defaults, Key.hidesFromCapture) ?? Self.standard.security.hidesFromCapture
		newProjectsKeepHistory = Self.flag(defaults, Key.newProjectHistory) ?? Self.standard.newProjectsKeepHistory
		newProjectsAskBeforeCLIReads = Self.flag(defaults, Key.newProjectCLIApproval) ?? Self.standard.newProjectsAskBeforeCLIReads
		remindsToBackUp = Self.flag(defaults, Key.backupReminder) ?? Self.standard.remindsToBackUp
	}

	// MARK: - Groups

	/// The Security page's settings.
	struct Security: Equatable, Sendable {
		var lockAfter: VaultLockInterval
		var valueApproval: VaultValueApproval
		var clipboardClear: VaultClipboardClear
		var rehide: VaultRehideInterval
		var hidesFromCapture: Bool
	}

	/// Every setting here, as a backup carries them.
	struct Snapshot: Equatable, Sendable {
		var security: Security
		var newProjectsKeepHistory: Bool
		var newProjectsAskBeforeCLIReads: Bool
		var remindsToBackUp: Bool
	}

	nonisolated static let standard = Snapshot(
		security: Security(
			lockAfter: .standard, valueApproval: .standard, clipboardClear: .standard, rehide: .standard, hidesFromCapture: true),
		newProjectsKeepHistory: true,
		newProjectsAskBeforeCLIReads: false,
		remindsToBackUp: true)

	var security: Security {
		get { Security(lockAfter: lockAfter, valueApproval: valueApproval, clipboardClear: clipboardClear, rehide: rehide, hidesFromCapture: hidesFromCapture) }
		set {
			lockAfter = newValue.lockAfter
			valueApproval = newValue.valueApproval
			clipboardClear = newValue.clipboardClear
			rehide = newValue.rehide
			hidesFromCapture = newValue.hidesFromCapture
		}
	}

	var snapshot: Snapshot {
		get {
			Snapshot(security: security, newProjectsKeepHistory: newProjectsKeepHistory,
				newProjectsAskBeforeCLIReads: newProjectsAskBeforeCLIReads, remindsToBackUp: remindsToBackUp)
		}
		set {
			security = newValue.security
			newProjectsKeepHistory = newValue.newProjectsKeepHistory
			newProjectsAskBeforeCLIReads = newValue.newProjectsAskBeforeCLIReads
			remindsToBackUp = newValue.remindsToBackUp
		}
	}

	// MARK: - Saving

	private func save(_ value: Any, _ key: String, changed: Change? = nil) {
		defaults.set(value, forKey: key)
		if let changed { onChange?(changed) }
	}

	private static func choice<Choice: RawRepresentable & CaseIterable>(_ defaults: UserDefaults, _ key: String) -> Choice?
	where Choice.RawValue == Int {
		guard let number = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
		return Choice(rawValue: number.intValue)
	}

	private static func flag(_ defaults: UserDefaults, _ key: String) -> Bool? {
		guard let number = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
		return number.boolValue
	}
}
