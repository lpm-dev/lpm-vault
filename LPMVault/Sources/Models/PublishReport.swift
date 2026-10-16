import Foundation

/// What happened to one key a publish sent.
enum PublishOutcome: Equatable, Sendable {
	case published
	case failed(String)
	/// Not sent, because an earlier refusal stopped the publish.
	case notSent
}

/// What a publish did: each sent key's outcome, and the records of what the platform accepted.
struct PublishReport: Equatable, Sendable {
	var outcomes: [String: PublishOutcome] = [:]
	/// The history records of the keys the platform accepted.
	var published: [PublishHistory.Published] = []
	/// The connection's token was refused, so it needs connecting again.
	var needsReconnect = false
	/// Platform records the publish moved forward that other places share,
	/// such as a Netlify variable's time, which every deploy context sees.
	var advances: [PublishHistory.Advance] = []
}
