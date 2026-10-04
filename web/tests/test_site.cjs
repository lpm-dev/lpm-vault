const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
const { before, after, test } = require('node:test')
const { chromium } = require('playwright')
const { AxeBuilder } = require('@axe-core/playwright')

let browser
let container
let origin

before(async () => {
  execFileSync('docker', ['build', '-q', '-f', 'web/Dockerfile', '-t', 'lpm-vault-browser-test', '.'])
  container = execFileSync('docker', ['run', '-d', '-p', '127.0.0.1::8080', 'lpm-vault-browser-test'], { encoding: 'utf8' }).trim()
  const port = execFileSync('docker', ['port', container, '8080'], { encoding: 'utf8' }).trim().split(':').at(-1)
  origin = `http://127.0.0.1:${port}`
  browser = await chromium.launch({ executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH })
})

after(async () => {
  await browser?.close()
  if (container) execFileSync('docker', ['rm', '-f', container])
})

test('mobile and desktop content meets text contrast requirements', async () => {
  for (const width of [390, 1440]) {
    const context = await browser.newContext({ viewport: { width, height: 900 } })
    const page = await context.newPage()
    try {
      await page.goto(origin)
      await page.evaluate(() => document.fonts.ready)
      const result = await new AxeBuilder({ page }).withRules(['color-contrast']).analyze()
      assert.deepEqual(result.violations.map(v => ({ id: v.id, nodes: v.nodes.map(n => ({ target: n.target, summary: n.failureSummary })) })), [], `viewport ${width}`)
    } finally {
      await context.close()
    }
  }
})

test('CSP permits same-origin crawl metadata fetches', async () => {
  const page = await browser.newPage()
  try {
    await page.goto(origin)
    const robots = await page.evaluate(async () => (await fetch('/robots.txt')).text())
    assert.match(robots, /Sitemap: https:\/\/vault\.lpm\.dev\/sitemap.xml/)
  } finally {
    await page.close()
  }
})
