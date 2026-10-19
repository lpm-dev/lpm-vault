import Foundation

/// What happened to one key a publish sent.
enum PublishOutcome: Equatable, Sendable {
	case published
	case failed(String)
	/// Sent, but no answer came back, so whether the platform took it isn't known.
	case unconfirmed(String)
	/// Not sent, because an earlier refusal stopped the publish.
	case notSent
}

/// What a publish did: each sent key's outcome, and the records of what the platform accepted.
struct PublishReport: Equatable, Sendable {
	var outcomes: [String: PublishOutcome] = [:]
	/// The history records of the keys the platform accepted.
	var published: [PublishHistory.Published] = []
	/// The history records of the keys sent without an answer, recorded so
	/// a later review knows the platform may have them.
	var unconfirmed: [PublishHistory.Published] = []
	/// Keys the platform accepted but no longer had when they were read back,
	/// recorded in the history all the same.
	var gone: Set<String> = []
	/// The connection's token was refused, so it needs connecting again.
	var needsReconnect = false
	/// Platform records the publish moved forward that other places share,
	/// such as a Netlify variable's time, which every deploy context sees.
	var advances: [PublishHistory.Advance] = []
}
