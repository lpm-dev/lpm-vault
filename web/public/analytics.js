"use strict"

;(() => {
	const HOST = "vault.lpm.dev"
	const ROOT = `https://${HOST}/`
	const OPTOUT_KEY = "vault_website_analytics_optout"
	const EVENTS = new Set(["$pageview", "vault_download_clicked", "vault_docs_clicked", "vault_github_clicked"])
	const SDK_PROPERTIES = new Set(["token", "distinct_id", "$cookieless_mode", "$raw_user_agent", "$insert_id", "$lib", "$lib_version", "$browser", "$os", "$device_type", "$process_person_profile"])
	const LOCATIONS = new Set(["header", "hero", "body", "footer"])
	const DESTINATIONS = new Set(["download", "documentation", "security_model", "repository", "changelog"])
	const choice = document.getElementById("analytics-optout")
	let trackingEnabled = window.location.hostname === HOST && !browserOptOut() && !savedOptOut()
	let client = null
	const attribution = landingAttribution()
	updateChoice()

	choice?.addEventListener("click", () => {
		trackingEnabled = false
		try { localStorage.setItem(OPTOUT_KEY, "true") } catch {}
		updateChoice()
	})
	window.addEventListener("storage", event => {
		if ((event.key === OPTOUT_KEY && event.newValue === "true") || event.key === null) {
			trackingEnabled = false
			updateChoice()
		}
	})

	if (!trackingEnabled || !window.posthog?.init) {
		trackingEnabled = false
		updateChoice()
		return
	}

	window.posthog.init("phc_Igvvu8TSxTnXG6miVGgRaHT54Fd2A9mpzgnON5V3Vjt", {
		api_host: "https://eu.i.posthog.com",
		ui_host: "https://eu.posthog.com",
		persistence: "memory",
		cookieless_mode: "always",
		person_profiles: "never",
		autocapture: false,
		capture_pageview: false,
		capture_pageleave: false,
		capture_exceptions: false,
		capture_performance: false,
		disable_session_recording: true,
		disable_surveys: true,
		disable_conversations: true,
		disable_product_tours: true,
		disable_web_experiments: true,
		disable_external_dependency_loading: true,
		advanced_disable_flags: true,
		save_campaign_params: false,
		save_referrer: false,
		request_batching: false,
		respect_dnt: true,
		before_send: sanitizeEvent,
		loaded: posthog => {
			client = posthog
			client.register({ ...attribution, app: "vault", attribution_version: 2, analytics_mode: "cookieless" })
			capture("$pageview")
		},
	})
	document.addEventListener("click", captureLink)
	document.addEventListener("auxclick", captureLink)

	function browserOptOut() {
		return navigator.globalPrivacyControl === true || [navigator.doNotTrack, window.doNotTrack].some(value => value === "1" || value === "yes")
	}

	function savedOptOut() {
		try { return localStorage.getItem(OPTOUT_KEY) === "true" } catch { return false }
	}

	function updateChoice() {
		if (!choice) return
		choice.hidden = false
		choice.disabled = !trackingEnabled
		choice.textContent = trackingEnabled ? "Turn off website analytics" : "Website analytics off"
	}

	function parseUrl(value) {
		try {
			const url = new URL(value)
			return ["https:", "http:"].includes(url.protocol) ? url : null
		} catch { return null }
	}

	function landingAttribution() {
		const search = new URLSearchParams(window.location.search)
		const token = value => /^[a-z0-9._-]{1,80}$/i.test(value || "") ? value : ""
		const campaignSource = token(search.get("utm_source"))
		const campaignMedium = token(search.get("utm_medium"))
		const referrer = parseUrl(document.referrer)
		const external = referrer && referrer.hostname !== HOST ? referrer : null
		const host = external?.hostname.toLowerCase() || ""
		let source = host || "direct"
		let medium = host ? "referral" : "none"
		const engines = [
			["google", /(^|\.)google\.(com|[a-z]{2}|co\.[a-z]{2}|com\.[a-z]{2})$/],
			["bing", /(^|\.)bing\.com$/],
			["duckduckgo", /(^|\.)duckduckgo\.com$/],
			["yahoo", /(^|\.)search\.yahoo\.com$/],
		]
		for (const [name, pattern] of engines) {
			if (pattern.test(host)) { source = name; medium = "organic"; break }
		}
		if (campaignSource) { source = campaignSource; medium = campaignMedium || "campaign" }
		return {
			landing_source: source,
			landing_medium: medium,
			landing_path: "/",
			is_test_traffic: campaignSource === "codex-seo-verification",
			$referrer: external ? `${external.origin}/` : "",
			$referring_domain: host || "$direct",
		}
	}

	function sanitizeEvent(event) {
		if (!trackingEnabled || browserOptOut() || !event || !EVENTS.has(event.event)) return null
		const properties = {}
		for (const [key, value] of Object.entries(event.properties || {})) {
			if (SDK_PROPERTIES.has(key)) properties[key] = value
		}
		Object.assign(properties, attribution, {
			app: "vault", attribution_version: 2, analytics_mode: "cookieless",
			$host: HOST, $current_url: ROOT, $pathname: "/", $process_person_profile: false,
		})
		if (LOCATIONS.has(event.properties?.link_location)) properties.link_location = event.properties.link_location
		if (DESTINATIONS.has(event.properties?.destination)) properties.destination = event.properties.destination
		const result = { ...event, properties }
		delete result.$set
		delete result.$set_once
		return result
	}

	function capture(event, properties = {}) {
		if (trackingEnabled && !browserOptOut()) client?.capture(event, properties, { send_instantly: true, transport: "sendBeacon" })
	}

	function captureLink(event) {
		if (event.defaultPrevented || (event.button !== 0 && event.button !== 1)) return
		const anchor = event.target?.closest?.("a[href]")
		if (!anchor) return
		let url
		try { url = new URL(anchor.getAttribute("href"), window.location.href) } catch { return }
		let name
		let destination
		if (url.origin === ROOT.slice(0, -1) && url.pathname === "/download") {
			name = "vault_download_clicked"; destination = "download"
		} else if (url.origin === "https://cli.lpm.dev" && ["/docs/dev/lpm-vault", "/docs/infra/secrets-vault"].includes(url.pathname)) {
			name = "vault_docs_clicked"; destination = url.pathname.includes("infra") ? "security_model" : "documentation"
		} else if (url.origin === "https://github.com" && ["/lpm-dev/lpm-vault", "/lpm-dev/lpm-vault/releases"].includes(url.pathname)) {
			name = "vault_github_clicked"; destination = url.pathname.endsWith("/releases") ? "changelog" : "repository"
		} else { return }
		const link_location = anchor.closest("header") ? "header" : anchor.closest("footer") ? "footer" : anchor.closest("[data-hero]") ? "hero" : "body"
		capture(name, { destination, link_location })
		if (attribution.is_test_traffic && url.origin === "https://cli.lpm.dev") {
			url.searchParams.set("utm_source", "codex-seo-verification")
			url.searchParams.set("utm_medium", "test")
			anchor.setAttribute("href", url.href)
		}
	}
})()
