import SwiftUI

/// Publishes a Vault environment to a platform: where it goes, a review of
/// what changes there, and what the platform accepted.
struct PublishSheet: View {
	@Bindable var store: VaultStore
	@Bindable var session: PublishSession
	@Environment(\.dismiss) private var dismiss
	@Environment(\.vaultContentObscured) private var isObscured
	@State private var confirmingForget = false
	/// Why forgetting the destination failed, shown until it's tried again.
	@State private var forgetFailure: String?
	@State private var isForgetting = false

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			VStack(alignment: .leading, spacing: 14) {
				route
				if session.step != .results { steps }
				switch session.step {
				case .destination: destinationStep
				case .review: reviewStep
				case .results: resultsStep
				}
			}
			.padding(.horizontal, 24)
			.padding(.bottom, 16)
			.frame(maxHeight: .infinity, alignment: .top)
			footer
		}
		.frame(width: 640)
		.frame(minHeight: 420, idealHeight: session.step == .destination ? 440 : 620, maxHeight: 680)
		.background(VaultPalette.content)
		.task { session.start() }
		.onDisappear { session.cancel() }
		.onChange(of: store.isUnlocked) { _, unlocked in if !unlocked { close() } }
		.onChange(of: store.selectedProjectId) { _, id in if id != session.vaultID { close() } }
		.onChange(of: store.selectedAccount) { _, _ in close() }
		.onChange(of: isObscured) { _, obscured in if obscured { confirmingForget = false } }
		.confirmationDialog("Forget this destination?", isPresented: $confirmingForget, titleVisibility: .visible) {
			Button("Forget Destination", role: .destructive) { forget() }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("LPM Vault forgets where this environment publishes and what it published there. Nothing changes on \(platformName).")
		}
	}

	// MARK: - Sections

	private var header: some View {
		HStack(alignment: .top, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text(session.step == .results ? "Published" : "Publish environment")
					.font(.system(size: 17, weight: .bold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text(subtitle)
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			Spacer(minLength: 12)
			VaultSheetCloseButton(action: close)
				.disabled(session.isPublishing)
		}
		.padding(.horizontal, 24)
		.padding(.top, 20)
		.padding(.bottom, 14)
	}

	private var subtitle: String {
		switch session.step {
		case .results: "\(platformName) uses new values in new deployments."
		default: session.saved == nil ? "Send selected variables from a Vault environment to a platform." : "Saved destination · opens on Review."
		}
	}

	/// The platform being published to, once it's known.
	private var platform: PublishPlatform? {
		session.review?.platform ?? session.platform ?? session.saved?.target.platform
	}

	private var platformName: String { platform?.displayName ?? "the platform" }

	private var route: some View {
		HStack(spacing: 14) {
			VStack(alignment: .leading, spacing: 4) {
				Text("FROM VAULT").vaultSectionLabel()
				Text("\(session.projectName) / \(VaultProject.displayName(for: session.sourceEnvironment))")
					.font(VaultTypography.mono(12.5, .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			Image(systemName: "arrow.right")
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(VaultPalette.textTertiary)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 4) {
				Text("TO \(platform?.displayName.uppercased() ?? "PLATFORM")\(session.connection.map { " · \($0.name.uppercased()) (\($0.detail))" } ?? "")")
					.vaultSectionLabel()
					.lineLimit(1)
					.truncationMode(.middle)
				Text("\(place.name ?? "—") / \(place.part ?? "—")")
					.font(VaultTypography.mono(12.5, .semibold))
					.foregroundStyle(place.part == nil ? VaultPalette.textTertiary : VaultPalette.accentForeground)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 12)
		.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.headerRow))
		.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
		.accessibilityElement(children: .combine)
	}

	/// Where the fields say to publish: the platform's project or resource,
	/// then the part of it written to, each nil until it's chosen.
	private var place: (name: String?, part: String?) {
		switch session.form {
		case .vercel(let form)?:
			let project = form.project?.name ?? {
				if case .vercel(let target)? = session.saved?.target, target.projectID == form.projectID { return target.projectName }
				return nil
			}()
			return (project, form.environment?.displayName)
		case .coolify(let form)?:
			let resource = form.resource?.name ?? {
				if case .coolify(let target)? = session.saved?.target, target.resourceID == form.resourceID { return target.resourceName }
				return nil
			}()
			return (resource, form.deployments?.displayName)
		case .netlify(let form)?:
			let site = form.site?.name ?? {
				if case .netlify(let target)? = session.saved?.target, target.siteID == form.siteID { return target.siteName }
				return nil
			}()
			return (site, form.context?.displayName)
		case .github(let form)?:
			let repository = form.repository?.fullName ?? {
				if case .github(let target)? = session.saved?.target, target.repositoryID == form.repositoryID { return target.repositoryName }
				return nil
			}()
			return (repository, form.scope?.displayName)
		case .cloudflare(let form)?:
			let worker = form.worker?.name ?? {
				if case .cloudflare(let target)? = session.saved?.target, target.workerID == form.workerID { return target.workerName }
				return nil
			}()
			return (worker, worker == nil ? nil : CloudflarePublishTarget.placeKind)
		case nil:
			return (nil, nil)
		}
	}

	private var steps: some View {
		HStack(spacing: 8) {
			Button("Destination") { session.showDestination() }
				.buttonStyle(.plain)
				.foregroundStyle(session.step == .destination ? VaultPalette.accentForeground : VaultPalette.textSecondary)
				.disabled(session.isPublishing)
			Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(VaultPalette.textFaint)
				.accessibilityHidden(true)
			Text("Review")
				.foregroundStyle(session.step == .review ? VaultPalette.accentForeground : VaultPalette.textSecondary)
		}
		.font(.system(size: 12.5, weight: .semibold))
	}

	// MARK: - Destination

	@ViewBuilder
	private var destinationStep: some View {
		switch session.connections {
		case .loaded(let connections) where connections.isEmpty:
			VStack(alignment: .leading, spacing: 10) {
				Text("No platform account is connected on this Mac.")
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
				Text("Connect Vercel, Netlify, GitHub, Cloudflare or Coolify on the Platforms page, then publish from here.")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
				VaultBarButton(systemImage: "square.stack.3d.up", title: "Open Platforms") {
					close()
					store.showPlatforms()
				}
			}
		case .failed(let message):
			Text(message).font(.system(size: 12)).foregroundStyle(VaultPalette.redText)
		default:
			VStack(alignment: .leading, spacing: 12) {
				Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
					GridRow {
						PublishDestinationField("Source environment") {
							VaultMenuField(
								title: "Source environment",
								options: session.environments.map { VaultMenuOption(value: $0, label: VaultProject.displayName(for: $0)) },
								selection: Binding(
									get: { session.sourceEnvironment },
									set: { if let name = $0 { session.sourceEnvironment = name } }))
						}
						PublishDestinationField("Platform connection") {
							VaultMenuField(
								title: "Platform connection",
								options: (session.connections.value ?? []).map {
									VaultMenuOption(value: $0.id, label: Self.connectionLabel($0), systemImage: $0.platform.systemImage)
								},
								selection: $session.connectionID,
								placeholder: session.connections == .loading ? "Loading…" : "Choose connection…")
						}
					}
					switch session.form {
					case .vercel(let form)?:
						VercelDestinationFields(form: form)
					case .coolify(let form)?:
						CoolifyDestinationFields(form: form)
					case .netlify(let form)?:
						NetlifyDestinationFields(form: form)
					case .github(let form)?:
						GitHubDestinationFields(form: form, installURL: githubInstallURL, reload: session.reloadChoices)
					case .cloudflare(let form)?:
						CloudflareDestinationFields(form: form, accounts: cloudflareAccounts)
					case nil:
						GridRow {
							PublishDestinationField("Destination") {
								VaultMenuField<String>(
									title: "Destination", options: [], selection: .constant(nil),
									placeholder: "Choose a connection first", disabled: true)
							}
							Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
						}
					}
				}
				if let failure = choicesFailure {
					Text(failure).font(.system(size: 11.5)).foregroundStyle(VaultPalette.redText)
				}
				if let error = session.destinationError {
					Text(error).font(.system(size: 11.5)).foregroundStyle(VaultPalette.redText)
						.fixedSize(horizontal: false, vertical: true)
				}
				Text(session.saved == nil
					? "Saved as a destination after the first publish, so next time this opens on Review."
					: "Changing where this destination publishes forgets what it published before.")
					.font(.system(size: 12))
					.foregroundStyle(VaultPalette.textTertiary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	/// Why the chosen connection's projects or resources couldn't be listed.
	private var choicesFailure: String? {
		switch session.form {
		case .vercel(let form)?: if case .failed(let message) = form.projects { return message }
		case .coolify(let form)?: if case .failed(let message) = form.resources { return message }
		case .netlify(let form)?: if case .failed(let message) = form.sites { return message }
		case .github(let form)?:
			if case .failed(let message) = form.repositories { return message }
			if case .failed(let message) = form.environments {
				return "\(form.repository?.fullName ?? "The repository")'s environments couldn't be listed. \(message) Its own secrets and variables can still be chosen."
			}
		case .cloudflare(let form)?: if case .failed(let message) = form.workers { return message }
		case nil: break
		}
		return nil
	}

	/// The accounts the chosen Cloudflare login reaches.
	private var cloudflareAccounts: [CloudflareAccount] {
		if case .cloudflare(let login)? = session.connection?.account { return login.accounts }
		return []
	}

	/// The page that installs the chosen GitHub connection's app on more repositories.
	private var githubInstallURL: URL? {
		if case .github(let account)? = session.connection?.account { return account.installURL }
		return nil
	}

	// MARK: - Review

	@ViewBuilder
	private var reviewStep: some View {
		if session.isLoadingReview {
			HStack(spacing: 8) {
				ProgressView().controlSize(.small)
				Text("Reading the \(platform?.valuesNoun(count: 2) ?? "variables") on \(platformName)…").font(.system(size: 12)).foregroundStyle(VaultPalette.textTertiary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else if let review = session.review {
			reviewContent(review)
		} else if let error = session.reviewError {
			VStack(alignment: .leading, spacing: 10) {
				Text(error).font(.system(size: 12)).foregroundStyle(VaultPalette.redText).fixedSize(horizontal: false, vertical: true)
				if let choices = session.loginChoices, !choices.isEmpty {
					VStack(alignment: .leading, spacing: 6) {
						ForEach(choices) { login in
							VaultBarButton(title: "Publish through \(login.name)") { session.chooseLogin(login.id) }
								.accessibilityLabel("Publish through \(login.name), which reaches \(login.detail)")
						}
					}
				}
				HStack(spacing: 8) {
					VaultBarButton(title: "Review Again", action: session.loadReview)
					VaultBarButton(title: "Change Destination", action: session.showDestination)
				}
			}
		}
	}

	private func reviewContent(_ review: PublishSession.Review) -> some View {
		let summary = review.summary
		return VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 6) {
				VaultTagBadge(text: "\(summary.adding) add", foreground: VaultPalette.greenTintText, background: VaultPalette.greenTint, size: 11)
				VaultTagBadge(text: "\(summary.replacing) replace", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 11)
				if summary.upToDate > 0 {
					VaultTagBadge(text: "\(summary.upToDate) up to date", foreground: VaultPalette.textTertiary, background: VaultPalette.neutralTint, size: 11)
				}
				VaultTagBadge(text: "\(summary.skipped) skipped", foreground: VaultPalette.textTertiary, background: VaultPalette.neutralTint, size: 11)
				Spacer(minLength: 8)
				Label("Values hidden", systemImage: "lock")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
			}
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					HStack {
						Text("VARIABLE").vaultSectionLabel()
						Spacer()
						Text("PLANNED ACTION").vaultSectionLabel()
					}
					.padding(.horizontal, 14)
					.padding(.vertical, 8)
					.background(VaultPalette.headerRow)
					if review.plan.rows.isEmpty {
						Text("\(VaultProject.displayName(for: review.destination.sourceEnvironment)) has no variables to publish.")
							.font(.system(size: 12)).foregroundStyle(VaultPalette.textTertiary)
							.padding(14)
					}
					ForEach(review.plan.rows) { row in
						VaultHairline(color: VaultPalette.rowDivider)
						reviewRow(row, review: review)
					}
				}
			}
			.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.control))
			.clipShape(RoundedRectangle(cornerRadius: 10))
			.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
			.disabled(session.isPublishing)
			VStack(alignment: .leading, spacing: 3) {
				ForEach(Self.notes(for: review), id: \.self) { note in
					Text(note).font(.system(size: 11.5)).foregroundStyle(VaultPalette.textTertiary)
						.fixedSize(horizontal: false, vertical: true)
				}
				if let error = session.reviewError {
					Text(error).font(.system(size: 11.5)).foregroundStyle(VaultPalette.redText)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		}
	}

	private func reviewRow(_ row: PublishPlan.Row, review: PublishSession.Review) -> some View {
		let selected = session.isSelected(row.key)
		let failsRules = row.holds.contains { if case .failsRules = $0 { true } else { false } }
		return HStack(alignment: .top, spacing: 12) {
			Toggle("Publish \(row.key)", isOn: Binding(
				get: { session.isSelected(row.key) },
				set: { session.set(row.key, selected: $0) }))
				.toggleStyle(.checkbox)
				.labelsHidden()
				.disabled(!row.isPublishable || (row.needsConfirmation && !selected))
				.padding(.top, 1)
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 8) {
					Text(row.key)
						.font(VaultTypography.mono(12.5, .semibold))
						.foregroundStyle(failsRules ? VaultPalette.redText : VaultPalette.textPrimary)
						.lineLimit(1)
						.truncationMode(.middle)
					if row.kind == .public { VaultPublicBadge() }
				}
				Text(Self.detail(row, review: review))
					.font(.system(size: 11.5))
					.foregroundStyle(noteColor(row))
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 8)
			action(row, selected: selected)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.accessibilityElement(children: .contain)
	}

	@ViewBuilder
	private func action(_ row: PublishPlan.Row, selected: Bool) -> some View {
		if selected {
			Text(row.operation == .add ? "Add" : "Replace existing")
				.font(.system(size: 12.5))
				.foregroundStyle(VaultPalette.textPrimary)
		} else if !row.isPublishable {
			Text("Can't publish").font(.system(size: 12.5)).foregroundStyle(VaultPalette.textTertiary)
		} else if row.needsConfirmation {
			HStack(spacing: 8) {
				VaultTagBadge(text: "Blocked", foreground: VaultPalette.orangeTintText, background: VaultPalette.orangeTint, size: 11)
				Button("Publish anyway") { session.set(row.key, selected: true, confirmed: true) }
					.buttonStyle(.plain)
					.font(.system(size: 12.5))
					.foregroundStyle(VaultPalette.accentForeground)
					.accessibilityLabel("Publish \(row.key) anyway")
			}
		} else if row.status.isUpToDate {
			Text("Up to date").font(.system(size: 12.5)).foregroundStyle(VaultPalette.textTertiary)
		} else {
			Text("Skip").font(.system(size: 12.5)).foregroundStyle(VaultPalette.textTertiary)
		}
	}

	static func detail(_ row: PublishPlan.Row, review: PublishSession.Review) -> String {
		let platform = review.platform.displayName
		// GitHub's kinds are its own words, "secret" and "variable", not LPM Vault's Secret and Config.
		let secret = review.platform == .github ? "secret" : "Secret"
		// A Worker keeps every value as a secret its code reads at runtime.
		var parts = [row.publishesAsSecret || review.platform == .cloudflare ? "Secret" : review.platform == .github ? "Variable" : "Config"]
		if review.platform == .cloudflare,
			ProjectEnvSchemaRule.publicPrefix(of: row.key, clientPrefixes: review.rules.overview.clientPrefixes) != nil
		{
			parts.append("frontend code reads it at build time, from the build's own variables")
		}
		if row.staysSecret { parts.append("stays a \(secret) on \(platform)") }
		if let hold = row.holds.first {
			parts.append(Self.holdNote(hold, row: row, review: review))
			// Choosing the key could overwrite a change made on the platform, which it says whatever comes first.
			if row.isPublishable, let risk = row.holds.dropFirst().first(where: \.risksOverwrite) {
				parts.append(Self.holdNote(risk, row: row, review: review))
			}
		} else if let publishedAt = row.status.publishedAt {
			parts.append(row.status.valueChanged
				? "Changed since last publish"
				: "Unchanged since you published \(RelativeTimestampFormatter.string(from: publishedAt))")
		} else if case .replace = row.operation {
			if review.platform == .cloudflare {
				parts.append("Replaces the value Cloudflare has now")
			} else {
				let kind = review.platform == .github && row.publishesAsSecret ? "secret" : "variable"
				parts.append("Replaces a \(kind) already on \(platform)")
			}
		}
		if row.status.protectionChanged, review.platform != .cloudflare {
			parts.append(row.publishesAsSecret ? "will be stored as a \(secret)" : "will be stored readable")
		}
		return parts.joined(separator: " · ")
	}

	static func holdNote(_ hold: PublishPlan.Hold, row: PublishPlan.Row, review: PublishSession.Review) -> String {
		let platform = review.platform.displayName
		let onPlatform = review.platform == .coolify ? "in \(platform)" : "on \(platform)"
		switch hold {
		case .reserved:
			return switch review.platform {
			case .vercel: "Vercel reserves this name"
			case .github: "GitHub reserves names starting with GITHUB_"
			default: "\(platform) sets this name itself"
			}
		case .nameTooLong(let limit): return "\(platform) accepts names up to \(limit) characters"
		case .nameNotAccepted:
			return review.platform == .github
				? "GitHub keeps names in capital letters, digits and underscores, not starting with a digit. Rename the key to publish it"
				: "\(platform) accepts only names that start with a letter and use letters, digits and underscores"
		case .unusableValue: return "No process can receive this value"
		case .changesValue(let issue): return Self.note(for: issue, on: platform)
		case .valueTooLong(let limit): return "\(platform) accepts values up to \(limit.formatted()) characters"
		case .valueTooLarge(let bytes): return "\(platform) accepts values up to \((bytes / 1_024).formatted()) KB"
		case .nameTaken:
			return "\(platform) uses this name for another variable or binding here. Rename one of them, then review again"
		case .duplicatedOnPlatform:
			return "\(platform) has both a secret and a variable with this name, which a workflow could read either of. Remove one \(onPlatform), then review again"
		case .sameValueEverywhere:
			return "\(platform) uses one value for all deploy contexts here. Give it a value per deploy context \(onPlatform), then review again"
		case .staysReadable:
			return review.platform == .github
				? "GitHub keeps this as a readable variable, so the value would be readable too. Delete the variable on GitHub to publish it as a secret"
				: "\(platform) keeps this variable readable, so the value would be too. Mark it as containing secret values \(onPlatform) to keep it write-only"
		case .unknownChangeTime:
			return "\(platform) doesn't say when this variable last changed, so a change made meanwhile can't be caught. Edit it once \(onPlatform), then review again"
		case .sharedWith(let names):
			let list = ListFormatter.localizedString(byJoining: names)
			return "Shared with \(list) on \(platform) — publishing would change \(list) too"
		case .failsRules:
			return "Fails its rule: \(review.ruleNotes[row.key] ?? "invalid")"
		case .ignoredByLPM: return "The LPM CLI ignores this key"
		case .excluded: return "Left out last time"
		case .changedOnPlatform:
			return row.status.platform == .removed ? "Removed \(onPlatform) since you published it" : "Changed \(onPlatform) since you published it"
		case .unknownSincePublish:
			return "\(platform) doesn't say whether it changed since you published it. Publishing replaces whatever it has now"
		case .unconfirmedPublish:
			return "This Mac sent it, but no answer came back, so \(platform) may or may not have it. Publishing sends it again"
		case .upToDate:
			return "Unchanged since you published \(row.status.publishedAt.map { RelativeTimestampFormatter.string(from: $0) } ?? "it")"
		}
	}

	static func note(for issue: PublishPlan.ValueIssue, on platform: String) -> String {
		switch issue {
		case .singleQuote: "\(platform) can't pass a value with a single quote (') to your app unchanged"
		case .trailingBackslash: "\(platform) can't pass a value ending in a backslash (\\) to your app unchanged"
		case .unquotedJSON: "\(platform) passes JSON without quotes, so its line breaks, $ signs or \" #\" would change"
		case .reference: "\(platform) replaces its {{…}} reference with a shared variable's value"
		case .trimmed: "\(platform) drops the spaces and line breaks at its ends"
		}
	}

	private func noteColor(_ row: PublishPlan.Row) -> Color {
		guard let hold = row.holds.first else { return VaultPalette.textTertiary }
		if hold.blocksPublishing, hold != .reserved { return VaultPalette.redText }
		switch hold {
		case .failsRules: return VaultPalette.redText
		case .sharedWith, .staysReadable, .changedOnPlatform, .changesValue: return VaultPalette.orangeTintText
		default: return VaultPalette.textTertiary
		}
	}

	/// A connection names what tells it apart, since two teams can share a name.
	static func connectionLabel(_ connection: PlatformConnection) -> String {
		"\(connection.platform.displayName) · \(connection.name) · \(connection.detail)"
	}

	static func notes(for review: PublishSession.Review) -> [String] {
		let platform = review.platform.displayName
		var notes: [String] = []
		// A value added to a variable the platform already has is written over whatever that variable holds for it then.
		let writesExistingVariables = review.summary.replacing > 0 || review.selection.keys.contains { review.remoteKeys[$0] != nil }
		if writesExistingVariables {
			switch review.platform {
			case .vercel:
				notes.append("Existing variables will be replaced. Vercel's current values can't be read to compare, and Vercel replaces a variable without checking it, so a change made on Vercel moments before publishing can still be overwritten.")
			case .coolify:
				notes.append("Existing variables will be replaced. LPM Vault doesn't read Coolify's current values to compare, and Coolify replaces a variable without checking it, so a change made in Coolify moments before publishing can still be overwritten.")
			case .netlify:
				notes.append("Values will be written to variables Netlify already has. LPM Vault doesn't read Netlify's current values to compare, and Netlify writes a value without checking it, so a change made on Netlify moments before publishing can still be overwritten, and a change to another deploy context at that moment can't be told apart from this publish.")
			case .github:
				notes.append("Existing secrets and variables will be replaced. GitHub never shows a secret's value, and replaces one without checking it, so a change made on GitHub moments before publishing can still be overwritten.")
			case .cloudflare:
				notes.append("Existing secrets will be replaced. Cloudflare never shows a secret's value. LPM Vault checks the Worker's newest version right before sending, but Cloudflare replaces secrets without a check of its own, so a change made moments before publishing can still be overwritten.")
			}
		}
		if case .cloudflare(let target) = review.destination.target {
			if let login = review.login {
				notes.append("Publishing to the Cloudflare account \(target.accountName), as \(login.label).")
			}
			if let hold = review.plan.placeHold { notes.append(CloudflarePublishing.holdMessage(hold)) }
			notes.append("Cloudflare makes a new version of the Worker with the secrets, and deploys it at once.")
			let clientPrefixes = review.rules.overview.clientPrefixes
			let frontend = review.plan.rows.lazy.map(\.key).filter { ProjectEnvSchemaRule.publicPrefix(of: $0, clientPrefixes: clientPrefixes) != nil }
			if let first = frontend.first {
				let others = frontend.dropFirst().count
				let named = others == 0 ? first : "\(first) and \(others) more"
				notes.append("\(named) \(others == 0 ? "is" : "are") read by frontend code at build time. A Worker's secrets reach only the Worker at runtime, so set them as the build's own variables and rebuild.")
			}
		}
		if case .coolify(let target) = review.destination.target, target.resource == .application, target.deployments == .production,
			review.summary.adding > 0
		{
			notes.append("Coolify also copies new variables to the application's preview deployments. LPM Vault locks the copies of Secrets.")
		}
		if review.platform == .netlify {
			notes.append("Values set in the site's netlify.toml override published ones. A site's variables also override the team's shared variables with the same name.")
		}
		if case .github(let target) = review.destination.target {
			notes.append("Workflows read secrets as ${{ secrets.NAME }} and variables as ${{ vars.NAME }}.")
			switch target.scope {
			case .repository:
				notes.append("A job that uses a deployment environment gets that environment's secret or variable instead, when it has one with the same name.")
			case .environment(let id, let name):
				notes.append("Only jobs that use the \(GitHubPublishTarget.Scope.shownName(id: id, name: name)) environment get these values, over the repository's with the same name.")
			}
		}
		let remoteOnly = review.plan.remoteOnlyCount
		if remoteOnly > 0 {
			notes.append("\(remoteOnly) \(review.platform.valuesNoun(count: remoteOnly)) only on \(platform) stay as they are.")
		}
		// GitHub's and Cloudflare's secrets stay secrets whatever their prefix.
		let readable = review.platform == .github || review.platform == .cloudflare ? "" : " unless their prefix makes them public"
		let secrets = review.platform == .github || review.platform == .cloudflare ? "secrets" : "Secrets"
		switch review.rules {
		case .unreadable: notes.append("lpm.json's rules can't be read, so values aren't checked, and keys publish as \(secrets)\(readable).")
		case .none: notes.append("This project has no rules, so keys publish as \(secrets)\(readable).")
		case .known:
			if !review.hasValueCheck {
				notes.append("The values haven't been checked against lpm.json's rules yet, so rule failures don't show.")
			}
		}
		if let lastPublishedAt = review.lastPublishedAt {
			notes.append("Last published \(RelativeTimestampFormatter.string(from: lastPublishedAt)).")
		}
		return notes
	}

	// MARK: - Results

	@ViewBuilder
	private var resultsStep: some View {
		if let results = session.results {
			VStack(alignment: .leading, spacing: 10) {
				Text(Self.resultsHeader(for: results))
					.font(.system(size: 13, weight: .semibold))
					.foregroundStyle(VaultPalette.textPrimary)
					.fixedSize(horizontal: false, vertical: true)
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(Array(results.rows.enumerated()), id: \.offset) { index, row in
							if index > 0 { VaultHairline(color: VaultPalette.rowDivider) }
							HStack(alignment: .firstTextBaseline, spacing: 10) {
								Text(row.key).font(VaultTypography.mono(12.5, .semibold)).foregroundStyle(VaultPalette.textPrimary)
									.lineLimit(1).truncationMode(.middle)
								Spacer(minLength: 8)
								outcome(row.outcome)
							}
							.padding(.horizontal, 14)
							.padding(.vertical, 9)
						}
					}
				}
				.background(RoundedRectangle(cornerRadius: 10).fill(VaultPalette.control))
				.clipShape(RoundedRectangle(cornerRadius: 10))
				.overlay { RoundedRectangle(cornerRadius: 10).stroke(VaultPalette.border, lineWidth: 1) }
				if results.needsReconnect {
					Text("\(results.destination.target.platform.displayName) no longer accepts this connection. Connect it again on the Platforms page.")
						.font(.system(size: 11.5)).foregroundStyle(VaultPalette.redText)
				}
				if let failure = results.recordFailure {
					Text(failure).font(.system(size: 11.5)).foregroundStyle(VaultPalette.redText).fixedSize(horizontal: false, vertical: true)
				}
			}
		}
	}

	/// How much was published, and, when the platform kept any new value, as it can with its row failed, how it starts using it.
	static func resultsHeader(for results: PublishSession.Results) -> String {
		guard results.rows.contains(where: \.isStored) else { return results.summary }
		return "\(results.summary) \(redeployNote(for: results.destination.target.platform))"
	}

	/// What to say of the installations GitHub left out: the suspended ones, then those whose repositories it refused to list.
	static func skippedInstallationNotes(_ skipped: [GitHubSkippedInstallation]) -> [String] {
		var notes: [String] = []
		let suspended = skipped.filter(\.isSuspended)
		if let first = suspended.first {
			let one = suspended.count == 1
			let owner = one ? "An owner of \(first.account ?? "the account")" : "An owner of each account"
			let settings = one ? first.account.map { "\($0)'s settings" } ?? "its settings" : "its settings"
			// GitHub lets an installation be unsuspended only the way it was suspended: an app's own suspension, only by the app.
			notes.append(
				"LPM Vault's GitHub App is suspended on \(accounts(suspended)), so \(one ? "its" : "their") repositories aren't listed. \(owner) can unsuspend it in \(settings) on GitHub, unless LPM Vault suspended it."
			)
		}
		let refused = skipped.filter { !$0.isSuspended }
		if !refused.isEmpty {
			notes.append(
				"GitHub refused to list the repositories of LPM Vault's GitHub App on \(accounts(refused)), as when it was uninstalled meanwhile. Refresh, or install the app there again."
			)
		}
		return notes
	}

	/// The installations' accounts: the first few by name, then how many others.
	private static func accounts(_ installations: [GitHubSkippedInstallation]) -> String {
		let named = installations.compactMap(\.account)
		let shown = named.prefix(3)
		let others = installations.count - shown.count
		var parts = Array(shown)
		if others > 0 {
			parts.append(shown.isEmpty
				? (others == 1 ? "an account" : "\(others) accounts")
				: "\(others) other account\(others == 1 ? "" : "s")")
		}
		return ListFormatter.localizedString(byJoining: parts)
	}

	static func redeployNote(for platform: PublishPlatform) -> String {
		switch platform {
		case .vercel: "Redeploy on Vercel to use the new values."
		case .coolify: "Redeploy in Coolify to use the new values."
		case .netlify: "Redeploy on Netlify to use the new values."
		case .github: "Workflow runs that start from now on get the new values. Re-run a workflow to use them now."
		case .cloudflare: "The Worker uses them at once: Cloudflare deployed a new version with them."
		}
	}

	@ViewBuilder
	private func outcome(_ outcome: PublishOutcome) -> some View {
		switch outcome {
		case .published:
			Label("Published", systemImage: "checkmark.circle.fill").foregroundStyle(VaultPalette.greenTintText)
				.font(.system(size: 12))
		case .failed(let message):
			Text(message).foregroundStyle(VaultPalette.redText).font(.system(size: 12))
				.multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
		case .unconfirmed(let message):
			Text(message).foregroundStyle(VaultPalette.orangeTintText).font(.system(size: 12))
				.multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
		case .notSent:
			Text("Not sent").foregroundStyle(VaultPalette.textTertiary).font(.system(size: 12))
		}
	}

	// MARK: - Footer

	private var footer: some View {
		VaultSheetFooter {
			switch session.step {
			case .destination:
				if session.saved != nil {
					HStack(spacing: 10) {
						Button(isForgetting ? "Forgetting…" : "Forget destination…") { confirmingForget = true }
							.buttonStyle(.plain)
							.font(.system(size: 12))
							.foregroundStyle(VaultPalette.redText)
							.disabled(isForgetting)
						if let forgetFailure {
							Text(forgetFailure)
								.font(.system(size: 11.5))
								.foregroundStyle(VaultPalette.redText)
								.lineLimit(2)
						}
					}
				} else if !session.canReview {
					Text("Choose a destination").font(.system(size: 12)).foregroundStyle(VaultPalette.textTertiary)
				}
			case .review:
				if let overflow = overflowMessage {
					Text(overflow)
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.orangeTintText)
						.fixedSize(horizontal: false, vertical: true)
				} else {
					Label("Touch ID confirms before anything is sent", systemImage: "touchid")
						.font(.system(size: 12))
						.foregroundStyle(VaultPalette.textTertiary)
				}
			case .results:
				EmptyView()
			}
		} actions: {
			switch session.step {
			case .destination:
				VaultBarButton(title: "Cancel", height: 28, action: close)
				VaultBarButton(
					title: "Review \(platform?.valuesNoun(count: 2) ?? "variables")", filled: true, disabled: !session.canReview, height: 28,
					action: session.loadReview)
			case .review:
				VaultBarButton(title: "Back", disabled: session.isPublishing, height: 28, action: session.showDestination)
				VaultBarButton(
					title: session.isPublishing ? "Publishing…" : "Publish \(publishedValues)",
					filled: true,
					disabled: publishCount == 0 || overflowMessage != nil || session.isPublishing || session.isLoadingReview,
					height: 28,
					action: session.publish)
				.accessibilityHint(overflowMessage ?? "")
			case .results:
				if session.results?.rows.contains(where: { $0.outcome != .published }) == true {
					VaultBarButton(title: "Review Again", height: 28, action: session.reviewAgain)
				}
				VaultBarButton(title: "Done", filled: true, height: 28, action: close)
			}
		}
	}

	private var publishCount: Int { session.review?.selection.keys.count ?? 0 }

	/// What the publish sends, counted as the platform calls it.
	private var publishedValues: String {
		guard let review = session.review else { return "variables" }
		let summary = review.summary
		return review.platform.countedValues(secrets: summary.secrets, variables: summary.variables)
	}

	private var overflowMessage: String? { session.review.flatMap(Self.overflowMessage(for:)) }

	/// Why the chosen keys can't be published as they are, when they can't:
	/// every kind that wouldn't fit, or what holds a Cloudflare Worker.
	static func overflowMessage(for review: PublishSession.Review) -> String? {
		switch review.destination.target {
		case .github(let target):
			let overflows = review.plan.overflows(of: review.selection)
			guard !overflows.isEmpty else { return nil }
			return overflows.map { GitHubPublishing.overflowMessage($0, scope: target.scope) }.joined(separator: " ")
		case .cloudflare:
			if let hold = review.plan.placeHold { return CloudflarePublishing.holdMessage(hold) }
			var messages: [String] = []
			if review.plan.changeLimitExcess(of: review.selection) != nil {
				messages.append(CloudflarePublishing.changeLimitMessage)
			}
			for overflow in review.plan.overflows(of: review.selection) {
				messages.append(CloudflarePublishing.capacityMessage(overflow))
			}
			return messages.isEmpty ? nil : messages.joined(separator: " ")
		case .vercel, .coolify, .netlify:
			return nil
		}
	}

	/// Forgets the destination, and closes once it's gone; a failure stays
	/// shown so forgetting can be tried again.
	private func forget() {
		guard let saved = session.saved, !isForgetting else { return }
		let vaultID = session.vaultID
		forgetFailure = nil
		isForgetting = true
		Task {
			let result = await store.publishing.remove(saved.id, from: vaultID)
			await store.loadPublishDestinations(for: vaultID)
			isForgetting = false
			switch result {
			case .success: close()
			case .failure(let error): forgetFailure = "This destination couldn't be forgotten. \(error)"
			}
		}
	}

	private func close() {
		guard !session.isPublishing else { return }
		session.cancel()
		dismiss()
	}
}

/// A Cloudflare destination's account, from those the chosen login reaches, and Worker.
private struct CloudflareDestinationFields: View {
	@Bindable var form: CloudflareDestinationForm
	let accounts: [CloudflareAccount]

	var body: some View {
		GridRow {
			PublishDestinationField("Cloudflare account") {
				VaultMenuField(
					title: "Cloudflare account",
					options: accounts.map { VaultMenuOption(value: $0.id, label: $0.name) },
					selection: $form.accountID,
					placeholder: accounts.isEmpty ? "Choose a login first" : "Choose account…",
					disabled: accounts.isEmpty)
			}
			PublishDestinationField("Worker") {
				VaultMenuField(
					title: "Worker",
					options: (form.workers.value ?? []).map { VaultMenuOption(value: $0.id, label: $0.name) },
					selection: $form.workerID,
					placeholder: placeholder,
					disabled: form.workers.value?.isEmpty ?? true)
			}
		}
	}

	private var placeholder: String {
		switch form.workers {
		case .loading: "Loading Workers…"
		case .loaded(let workers) where workers.isEmpty: "No Workers in this account"
		case .idle where form.accountID == nil: "Choose an account first"
		default: "Choose Worker…"
		}
	}
}

/// A Vercel destination's project and environment.
private struct VercelDestinationFields: View {
	@Bindable var form: VercelDestinationForm

	var body: some View {
		GridRow {
			PublishDestinationField("Platform project") {
				VaultMenuField(
					title: "Platform project",
					options: (form.projects.value ?? []).map { VaultMenuOption(value: $0.id, label: $0.name) },
					selection: $form.projectID,
					placeholder: placeholder,
					disabled: form.projects.value?.isEmpty ?? true)
			}
			PublishDestinationField("Destination environment") {
				VaultMenuField(
					title: "Destination environment",
					options: form.environmentChoices.map { VaultMenuOption(value: $0, label: $0.displayName) },
					selection: $form.environment,
					placeholder: "Choose environment…",
					disabled: form.project == nil)
			}
		}
	}

	private var placeholder: String {
		switch form.projects {
		case .loading: "Loading projects…"
		case .loaded(let projects) where projects.isEmpty: "No projects this connection can reach"
		default: "Choose project…"
		}
	}
}

/// A Coolify destination's application or service, and its deployments.
private struct CoolifyDestinationFields: View {
	@Bindable var form: CoolifyDestinationForm

	var body: some View {
		let resources = form.resources.value ?? []
		let labels = CoolifyDestinationForm.labels(for: resources)
		GridRow {
			PublishDestinationField("Application or service") {
				VaultMenuField(
					title: "Application or service",
					options: resources.map {
						VaultMenuOption(value: $0.id, label: labels[$0.id] ?? $0.name, systemImage: $0.kind == .service ? "square.stack.3d.up" : "app")
					},
					selection: $form.resourceID,
					placeholder: placeholder,
					disabled: form.resources.value?.isEmpty ?? true)
			}
			PublishDestinationField("Deployments") {
				VaultMenuField(
					title: "Deployments",
					options: form.deploymentChoices.map { VaultMenuOption(value: $0, label: $0.displayName) },
					selection: $form.deployments,
					placeholder: "Choose deployments…",
					disabled: form.resource == nil || form.deploymentChoices.count < 2)
			}
		}
	}


	private var placeholder: String {
		switch form.resources {
		case .loading: "Loading applications…"
		case .loaded(let resources) where resources.isEmpty: "No applications or services in this team"
		default: "Choose application or service…"
		}
	}
}

/// A Netlify destination's site and deploy context, and a branch's name when it's one branch's deploys.
private struct NetlifyDestinationFields: View {
	@Bindable var form: NetlifyDestinationForm
	@FocusState private var editingBranch: Bool

	var body: some View {
		let sites = form.sites.value ?? []
		let labels = NetlifyDestinationForm.labels(for: sites)
		GridRow {
			PublishDestinationField("Site") {
				VaultMenuField(
					title: "Site",
					options: sites.map { VaultMenuOption(value: $0.id, label: labels[$0.id] ?? $0.name) },
					selection: $form.siteID,
					placeholder: placeholder,
					disabled: form.sites.value?.isEmpty ?? true)
			}
			PublishDestinationField("Deploy context") {
				VaultMenuField(
					title: "Deploy context",
					options: NetlifyDestinationForm.ContextChoice.allCases.map { VaultMenuOption(value: $0, label: $0.displayName) },
					selection: $form.contextChoice,
					placeholder: "Choose deploy context…",
					disabled: form.site == nil)
			}
		}
		if form.contextChoice == .branch {
			GridRow {
				PublishDestinationField("Branch") {
					VStack(alignment: .leading, spacing: 4) {
						TextField("staging", text: $form.branch)
							.textFieldStyle(.plain)
							.font(VaultTypography.mono(12.5))
							.foregroundStyle(VaultPalette.textPrimary)
							.autocorrectionDisabled()
							.focused($editingBranch)
							.padding(.horizontal, 11)
							.frame(height: 30)
							.vaultInputField(focused: editingBranch)
						if let problem = form.branchProblem {
							Text(problem).font(.system(size: 11)).foregroundStyle(VaultPalette.redText)
								.fixedSize(horizontal: false, vertical: true)
						}
					}
				}
				Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
			}
		}
	}

	private var placeholder: String {
		switch form.sites {
		case .loading: "Loading sites…"
		case .loaded(let sites) where sites.isEmpty: "No sites this connection can reach"
		default: "Choose site…"
		}
	}
}

/// A GitHub destination's repository, and the repository's own secrets and
/// variables or one environment's. Repositories come from installations of
/// LPM Vault's GitHub App, so installing it on more lists them after Refresh.
private struct GitHubDestinationFields: View {
	@Bindable var form: GitHubDestinationForm
	let installURL: URL?
	let reload: () -> Void
	@Environment(\.openURL) private var openURL

	var body: some View {
		GridRow {
			PublishDestinationField("Repository") {
				VaultMenuField(
					title: "Repository",
					options: zip(form.repositories.value ?? [], form.repositoryOptions).map { repository, option in
						VaultMenuOption(
							value: option.id, label: option.label, systemImage: repository.isPrivate ? "lock" : "book.closed",
							disabled: !option.isAvailable)
					},
					selection: $form.repositoryID,
					placeholder: placeholder,
					disabled: form.repositories.value?.isEmpty ?? true)
			}
			PublishDestinationField("Secrets and variables") {
				VaultMenuField(
					title: "Secrets and variables",
					options: form.scopeOptions.map { VaultMenuOption(value: $0.id, label: $0.label, disabled: !$0.isAvailable) },
					selection: Binding(
						get: { form.scope?.identifier },
						set: { identifier in form.scope = form.scopeChoices.first { $0.identifier == identifier } }),
					placeholder: form.environments == .loading ? "Loading environments…" : "Choose…",
					disabled: form.repository == nil)
			}
		}
		GridRow {
			HStack(spacing: 8) {
				Text("A repository that isn't listed needs LPM Vault's GitHub App.\(form.environments == .loading ? " Loading environments…" : "")")
					.font(.system(size: 11.5))
					.foregroundStyle(VaultPalette.textTertiary)
				if let installURL {
					Button("Install on GitHub") { openURL(installURL) }
						.buttonStyle(.plain)
						.font(.system(size: 11.5, weight: .medium))
						.foregroundStyle(VaultPalette.accentForeground)
				}
				Button("Refresh", action: reload)
					.buttonStyle(.plain)
					.font(.system(size: 11.5, weight: .medium))
					.foregroundStyle(VaultPalette.accentForeground)
					.disabled(form.repositories == .loading)
					.accessibilityLabel("Refresh repositories")
			}
			.gridCellColumns(2)
		}
		GridRow {
			VStack(alignment: .leading, spacing: 4) {
				Text(form.hidesSSORepositories
					? "GitHub left out repositories of an organization with single sign-on. Sign in to it on GitHub, then connect GitHub again on the Platforms page."
					: "An organization with single sign-on lists its repositories only when GitHub was connected while you were signed in to it.")
					.foregroundStyle(form.hidesSSORepositories ? VaultPalette.orangeTintText : VaultPalette.textTertiary)
				ForEach(PublishSheet.skippedInstallationNotes(form.skippedInstallations), id: \.self) { note in
					Text(note).foregroundStyle(VaultPalette.orangeTintText)
				}
			}
			.font(.system(size: 11.5))
			.fixedSize(horizontal: false, vertical: true)
			.gridCellColumns(2)
		}
	}

	private var placeholder: String {
		switch form.repositories {
		case .loading: "Loading repositories…"
		case .loaded(let repositories) where repositories.isEmpty: "No repositories have LPM Vault's GitHub App"
		default: "Choose repository…"
		}
	}
}

/// One labeled field of the Destination step.
private struct PublishDestinationField<Content: View>: View {
	let title: String
	@ViewBuilder let content: Content

	init(_ title: String, @ViewBuilder content: () -> Content) {
		self.title = title
		self.content = content()
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			VaultFieldLabel(title: title)
			content
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
