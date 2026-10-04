const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { test } = require('node:test')

const sourcePath = path.join(__dirname, '../public/analytics.js')
const sdkUserAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/146.0.0.0 Safari/537.36'

function boot({ href = 'https://vault.lpm.dev/', referrer = '', stored = null, navigator = {}, storageThrows = false, sdkMissing = false } = {}) {
  const events = []
  const listeners = {}
  const writes = []
  const scripts = []
  const button = { hidden: true, disabled: false, textContent: '', addEventListener: (name, callback) => { listeners[`button:${name}`] = callback } }
  let config
  let properties = {}
  const sdk = {
    init: (key, options) => { config = options; options.loaded(sdk) },
    register: (value) => { properties = value },
    capture: (event, value, options) => {
      const raw = { event, properties: { token: 'public-token', distinct_id: '$posthog_cookieless', $cookieless_mode: true, $raw_user_agent: sdkUserAgent, ...properties, ...value } }
      const result = config.before_send(raw)
      if (result) events.push({ ...result, options })
    },
  }
  const location = new URL(href)
  const context = {
    URL, URLSearchParams, Set, Object,
    window: { posthog: sdkMissing ? undefined : sdk, location, addEventListener: (name, callback) => { listeners[`window:${name}`] = callback } },
    document: { referrer, getElementById: () => button, addEventListener: (name, callback) => { listeners[name] = callback }, createElement: () => ({}), head: { append: script => scripts.push(script) } },
    navigator,
    localStorage: {
      getItem: () => { if (storageThrows) throw Error('blocked'); return stored },
      setItem: (key, value) => { if (storageThrows) throw Error('blocked'); writes.push([key, value]) },
    },
  }
  vm.runInNewContext(fs.readFileSync(sourcePath, 'utf8'), context)
  return { events, listeners, writes, button, config, properties, scripts, context, sdk }
}

test('delivers through the same origin when PostHog domains are blocked', () => {
  assert.equal(boot().config.api_host, '/ingest')
})

test('loads the SDK only for eligible visits and preserves early clicks', () => {
  const state = boot({ sdkMissing: true })
  assert.equal(state.scripts.length, 1)
  click(state, '/download')
  state.context.window.posthog = state.sdk
  state.scripts[0].onload()
  assert.deepEqual(state.events.map(e => e.event), ['$pageview', 'vault_download_clicked'])
  for (const options of [{ sdkMissing: true, stored: 'true' }, { sdkMissing: true, navigator: { globalPrivacyControl: true } }, { sdkMissing: true, navigator: { doNotTrack: '1' } }, { sdkMissing: true, href: 'http://localhost:8080/' }]) {
    assert.equal(boot(options).scripts.length, 0)
  }
})

test('opt-out during SDK loading prevents initialization and queued delivery', () => {
  const state = boot({ sdkMissing: true })
  click(state, '/download')
  state.listeners['button:click']()
  state.context.window.posthog = state.sdk
  state.scripts[0].onload()
  assert.equal(state.events.length, 0)
})

test('privacy changes during SDK loading disable capture and update the choice', () => {
  const state = boot({ sdkMissing: true })
  state.context.navigator.globalPrivacyControl = true
  state.context.window.posthog = state.sdk
  state.scripts[0].onload()
  assert.equal(state.events.length, 0)
  assert.equal(state.button.disabled, true)
})

test('early intents use a bounded queue and SDK load failures discard it', () => {
  const state = boot({ sdkMissing: true })
  for (let index = 0; index < 25; index++) click(state, '/download')
  state.context.window.posthog = state.sdk
  state.scripts[0].onload()
  assert.equal(state.events.length, 21)
  const failed = boot({ sdkMissing: true })
  click(failed, '/download')
  failed.scripts[0].onerror()
  failed.context.window.posthog = failed.sdk
  failed.scripts[0].onload()
  assert.equal(failed.events.length, 0)
  assert.equal(failed.button.disabled, true)
})

function click(state, href, section = 'hero', overrides = {}) {
  const anchor = { href, getAttribute: () => href, setAttribute: (name, value) => { anchor.href = value }, closest: (selector) => selector === 'header' && section === 'header' ? {} : selector === 'footer' && section === 'footer' ? {} : selector === '[data-hero]' && section === 'hero' ? {} : null }
  state.listeners.click?.({ button: 0, defaultPrevented: false, target: { closest: () => anchor }, ...overrides })
  return anchor
}

test('uses cookieless analytics without profiles, replay, autocapture, or external code', () => {
  const state = boot()
  assert.equal(state.config.cookieless_mode, 'always')
  assert.equal(state.config.persistence, 'memory')
  assert.equal(state.config.person_profiles, 'never')
  assert.equal(state.config.autocapture, false)
  assert.equal(state.config.disable_session_recording, true)
  assert.equal(state.config.disable_external_dependency_loading, true)
  assert.equal(state.config.advanced_disable_flags, true)
  assert.equal(state.config.save_campaign_params, false)
  assert.equal(state.config.save_referrer, false)
  assert.equal(state.events.length, 1)
  assert.equal(state.events[0].event, '$pageview')
  assert.equal(state.events[0].properties.$cookieless_mode, true)
  assert.equal(state.writes.length, 0)
})

test('records explicit intents without claiming installation or activation', () => {
  const state = boot()
  click(state, '/download')
  click(state, 'https://cli.lpm.dev/docs/dev/lpm-vault', 'footer')
  click(state, 'https://cli.lpm.dev/docs/infra/secrets-vault', 'body')
  click(state, 'https://github.com/lpm-dev/lpm-vault', 'header')
  assert.deepEqual(state.events.map(value => value.event), ['$pageview', 'vault_download_clicked', 'vault_docs_clicked', 'vault_docs_clicked', 'vault_github_clicked'])
  assert.equal(state.events[1].properties.destination, 'download')
  assert.equal(state.events[1].properties.link_location, 'hero')
  assert.equal(state.events[2].properties.link_location, 'footer')
  assert.equal(state.events[3].properties.destination, 'security_model')
  assert.ok(state.events.every(value => value.options.send_instantly))
})

test('preserves the SDK user agent required for cookieless ingestion on every approved event', () => {
  const state = boot({ href: 'https://vault.lpm.dev/?utm_source=codex-seo-verification&token=secret#private' })
  click(state, '/download')
  click(state, 'https://cli.lpm.dev/docs/dev/lpm-vault')
  click(state, 'https://github.com/lpm-dev/lpm-vault')
  assert.equal(state.events.length, 4)
  for (const { properties } of state.events) {
    assert.equal(properties.$raw_user_agent, sdkUserAgent)
    assert.equal(properties.$host, 'vault.lpm.dev')
    assert.equal(properties.$cookieless_mode, true)
    assert.equal(properties.distinct_id, '$posthog_cookieless')
    assert.equal(properties.$process_person_profile, false)
    assert.equal(properties.$current_url, 'https://vault.lpm.dev/')
    assert.equal(properties.is_test_traffic, true)
  }
})

test('keeps the initial organic source on each intent', () => {
  const state = boot({ referrer: 'https://www.google.com/search?q=private+query' })
  click(state, '/download')
  for (const value of state.events) {
    assert.equal(value.properties.landing_source, 'google')
    assert.equal(value.properties.landing_medium, 'organic')
    assert.equal(value.properties.$referrer, 'https://www.google.com/')
    assert.equal(value.properties.landing_path, '/')
  }
})

test('retains referral origins without credentials, paths, queries, or fragments', () => {
  const state = boot({ referrer: 'https://user:password@example.com/private/account?token=secret#private' })
  assert.equal(state.events[0].properties.$referrer, 'https://example.com/')
  assert.equal(state.events[0].properties.landing_source, 'example.com')
  assert.equal(state.events[0].properties.landing_medium, 'referral')
  assert.equal(JSON.stringify(state.events).includes('password'), false)
  assert.equal(JSON.stringify(state.events).includes('secret'), false)
})

test('normalizes same-host referrals and rejects search-engine lookalikes', () => {
  const self = boot({ referrer: 'https://vault.lpm.dev/?token=secret' })
  assert.equal(self.events[0].properties.landing_source, 'direct')
  assert.equal(self.events[0].properties.$referrer, '')
  const spoofed = boot({ referrer: 'https://google.com.evil.test/' })
  assert.equal(spoofed.events[0].properties.landing_medium, 'referral')
})

test('marks verification traffic and never sends raw landing queries', () => {
  const state = boot({ href: 'https://vault.lpm.dev/?utm_source=codex-seo-verification&utm_medium=test&email=private@example.com&token=secret#private' })
  click(state, '/download')
  assert.ok(state.events.every(value => value.properties.is_test_traffic === true))
  assert.equal(state.events[0].properties.$current_url, 'https://vault.lpm.dev/')
  assert.equal(state.events[0].properties.attribution_version, 2)
  assert.equal(JSON.stringify(state.events).includes('private@example.com'), false)
  assert.equal(JSON.stringify(state.events).includes('secret'), false)
})

test('keeps cross-site verification out of CLI customer reports', () => {
  const state = boot({ href: 'https://vault.lpm.dev/?utm_source=codex-seo-verification&token=secret' })
  const anchor = click(state, 'https://cli.lpm.dev/docs/dev/lpm-vault')
  const destination = new URL(anchor.href)
  assert.equal(destination.searchParams.get('utm_source'), 'codex-seo-verification')
  assert.equal(destination.searchParams.get('utm_medium'), 'test')
  assert.equal(destination.searchParams.has('token'), false)
  assert.equal(click(boot(), 'https://cli.lpm.dev/docs/dev/lpm-vault').href, 'https://cli.lpm.dev/docs/dev/lpm-vault')
})

test('drops unsolicited events and properties including person updates', () => {
  const state = boot()
  assert.equal(state.config.before_send({ event: '$autocapture', properties: {} }), null)
  const result = state.config.before_send({ event: '$pageview', properties: { token: 'key', distinct_id: '$posthog_cookieless', $cookieless_mode: true, $current_url: 'https://vault.lpm.dev/?token=secret', $initial_referrer: 'https://example.com/private', email: 'private@example.com', destination: 'secret', link_location: 'private', $set: { email: 'private@example.com' } }, $set_once: { secret: 'private' } })
  assert.equal(result.properties.$current_url, 'https://vault.lpm.dev/')
  assert.equal(result.properties.email, undefined)
  assert.equal(result.$set_once, undefined)
  assert.equal(result.properties.$set, undefined)
  assert.equal(result.properties.destination, undefined)
  assert.equal(result.properties.link_location, undefined)
  assert.equal(result.properties.distinct_id, '$posthog_cookieless')
})

test('respects browser privacy signals and saved opt-out before SDK initialization', () => {
  for (const options of [{ navigator: { globalPrivacyControl: true } }, { navigator: { doNotTrack: '1' } }, { stored: 'true' }]) {
    const state = boot(options)
    assert.equal(state.config, undefined)
    assert.equal(state.events.length, 0)
    assert.equal(state.button.disabled, true)
  }
})

test('manual opt-out stops events even when preference storage is unavailable', () => {
  const state = boot({ storageThrows: true })
  state.listeners['button:click']()
  click(state, '/download')
  assert.equal(state.events.length, 1)
  assert.equal(state.config.before_send({ event: '$pageview', properties: {} }), null)
  assert.equal(state.button.disabled, true)
})

test('manual opt-out stores only the preference and synchronizes across tabs', () => {
  const state = boot()
  state.listeners['button:click']()
  assert.deepEqual(state.writes, [['vault_website_analytics_optout', 'true']])
  const other = boot()
  other.listeners['window:storage']({ key: 'vault_website_analytics_optout', newValue: 'true' })
  click(other, '/download')
  assert.equal(other.events.length, 1)
})

test('does not capture local previews, failed SDK loads, canceled clicks, or unrelated links', () => {
  assert.equal(boot({ href: 'http://localhost:8080/' }).events.length, 0)
  assert.equal(boot({ sdkMissing: true }).events.length, 0)
  const state = boot()
  click(state, '/download', 'hero', { defaultPrevented: true })
  click(state, 'https://example.com/download')
  click(state, '#features')
  assert.equal(state.events.length, 1)
})
