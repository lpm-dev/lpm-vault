const { execFileSync, spawnSync } = require('node:child_process')
const { setTimeout: sleep } = require('node:timers/promises')

const STARTUP_DEADLINE_MS = 10_000

// `docker run -d` returns before nginx listens, so a page opened right away can be refused.
async function startSite(image) {
  const container = execFileSync('docker', ['run', '-d', '-p', '127.0.0.1::8080', image], { encoding: 'utf8' }).trim()
  try {
    const origin = `http://127.0.0.1:${execFileSync('docker', ['port', container, '8080'], { encoding: 'utf8' }).trim().split(':').at(-1)}`
    if (!await answersHealth(origin)) {
      const logs = spawnSync('docker', ['logs', '--tail', '20', container], { encoding: 'utf8' })
      throw new Error(`${image} did not answer /health within ${STARTUP_DEADLINE_MS / 1000} s\n${logs.stdout}${logs.stderr}`)
    }
    return { container, origin }
  } catch (error) {
    execFileSync('docker', ['rm', '-f', container])
    throw error
  }
}

async function answersHealth(origin) {
  const deadline = Date.now() + STARTUP_DEADLINE_MS
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${origin}/health`, { signal: AbortSignal.timeout(1000) })
      await response.arrayBuffer()
      if (response.ok) return true
    } catch {}
    await sleep(100)
  }
  return false
}

module.exports = { startSite }
