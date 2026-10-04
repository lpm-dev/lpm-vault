const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
const { before, after, test } = require('node:test')
const { chromium } = require('playwright')
const { gunzipSync } = require('node:zlib')

let browser
let container
let origin

before(async () => {
  const image = process.env.VAULT_DELIVERY_TEST_IMAGE || 'lpm-vault-delivery-test'
  if (!process.env.VAULT_DELIVERY_TEST_IMAGE) execFileSync('docker', ['build', '-q', '-f', 'web/Dockerfile', '-t', image, '.'])
  container = execFileSync('docker', ['run', '-d', '-p', '127.0.0.1::8080', image], { encoding: 'utf8' }).trim()
  origin = `http://127.0.0.1:${execFileSync('docker', ['port', container, '8080'], { encoding: 'utf8' }).trim().split(':').at(-1)}`
  browser = await chromium.launch({ executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH })
})

after(async () => {
  await browser?.close()
  if (container) execFileSync('docker', ['rm', '-f', container])
})

test('real SDK delivers sanitized cookieless events when third-party analytics domains are blocked', async () => {
  const context = await browser.newContext({ userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' })
  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => false })
    Object.defineProperty(navigator, 'userAgentData', { get: () => ({ brands: [{ brand: 'Google Chrome', version: '146' }], mobile: false, platform: 'macOS' }) })
  })
  const page = await context.newPage()
  const requests = []
  const paths = []
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  await context.route('**/*', async route => {
    const request = route.request()
    const url = new URL(request.url())
    paths.push(`${request.method()} ${url.origin}${url.pathname}`)
    if (url.hostname !== 'vault.lpm.dev') return route.abort('blockedbyclient')
    if (url.pathname === '/ingest/e/') {
      let body = request.postDataBuffer()
      if (body[0] === 0x1f && body[1] === 0x8b) body = gunzipSync(body)
      let payload
      try { payload = JSON.parse(body.toString()) } catch {
        payload = JSON.parse(Buffer.from(new URLSearchParams(body.toString()).get('data'), 'base64').toString())
      }
      requests.push(...(payload.batch || (Array.isArray(payload) ? payload : [payload])))
      if (process.env.VAULT_VERIFY_LIVE_POSTHOG === '1') {
        const response = await route.fetch({ url: `${origin}${url.pathname}${url.search}` })
        assert.equal(response.status(), 200)
        return route.fulfill({ response })
      }
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{"status":1}' })
    }
    const response = await route.fetch({ url: `${origin}${url.pathname}${url.search}` })
    await route.fulfill({ response })
  })
  try {
    await page.goto('https://vault.lpm.dev/?utm_source=codex-seo-verification&token=private-value#secret')
    await page.waitForFunction(() => window.posthog?.__loaded)
    await page.waitForLoadState('networkidle')
    assert.equal(requests[0]?.event, '$pageview', JSON.stringify({ paths, requests, errors }))
    const delivery = page.waitForResponse(r => new URL(r.url()).pathname === '/ingest/e/')
    await page.getByRole('link', { name: 'View on GitHub' }).first().click({ modifiers: ['ControlOrMeta'] })
    await delivery
    assert.equal(requests[1]?.event, 'vault_github_clicked')
    assert.ok(requests.every(event => event.properties.$cookieless_mode === true && event.properties.$process_person_profile === false))
    assert.ok(requests.every(event => event.properties.$raw_user_agent))
    assert.equal(JSON.stringify(requests).includes('private-value'), false)
    assert.equal((await context.cookies()).length, 0)
    assert.deepEqual(await page.evaluate(() => Object.keys(localStorage)), [])
    await page.getByRole('button', { name: 'Turn off website analytics' }).click()
    await page.getByRole('link', { name: 'View on GitHub' }).first().click({ modifiers: ['ControlOrMeta'] })
    await page.waitForLoadState('networkidle')
    assert.equal(requests.length, 2)
    assert.deepEqual(errors, [])
  } finally {
    await context.close()
  }
})
