const { buildSync } = require('esbuild')
const path = require('node:path')

buildSync({
  stdin: { contents: "import posthog from 'posthog-js/dist/module.slim.no-external.js'; window.posthog = posthog;", resolveDir: __dirname },
  outfile: path.join(__dirname, 'public/vendor/metrics-core-1.435.7.js'),
  bundle: true,
  format: 'iife',
  minify: true,
  target: 'es2020',
  legalComments: 'eof',
})
