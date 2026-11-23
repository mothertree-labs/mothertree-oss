// Every runtime dependency must load with plain Node require(): the portal is
// CommonJS. Jest's own resolver is not used here (it can mask ESM-only
// packages); each require runs in a real `node` child process, as in the image.
// Regression for connect-redis 11 (ESM-only), which crash-looped the portal in
// prod after a Dependabot batch (#834).
const { execFileSync } = require('child_process');
const path = require('path');

const root = path.join(__dirname, '..');
const deps = Object.keys(require(path.join(root, 'package.json')).dependencies);

describe('runtime dependencies load with require()', () => {
  test.each(deps)('%s', (dep) => {
    expect(() =>
      execFileSync(process.execPath, ['-e', `require(${JSON.stringify(dep)})`], {
        cwd: root,
        stdio: 'pipe',
      }),
    ).not.toThrow();
  });
});
