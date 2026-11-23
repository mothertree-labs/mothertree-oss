// Every runtime dependency must load the way the portal loads it. The portal
// is CommonJS, so that is require(), except for the ESM-only packages listed
// in ESM_ONLY, which the code loads with import(). Each load runs in a real
// `node` child process, as in the image; Jest's own resolver is not used (it
// can mask ESM-only packages). Regression for connect-redis 11 (ESM-only),
// which crash-looped the portal in prod while server.js still require()d it
// (#835, #834).
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const deps = Object.keys(require(path.join(root, 'package.json')).dependencies);

// Loaded with `await import()` in server.js.
const ESM_ONLY = new Set(['connect-redis']);

const runNode = (args) =>
  execFileSync(process.execPath, args, { cwd: root, stdio: 'pipe' });

// The portal's own source: server.js plus api/ and lib/ when present.
function sourceFiles() {
  const out = [path.join(root, 'server.js')];
  for (const dir of ['api', 'lib']) {
    const d = path.join(root, dir);
    if (!fs.existsSync(d)) continue;
    for (const f of fs.readdirSync(d, { recursive: true })) {
      if (String(f).endsWith('.js')) out.push(path.join(d, String(f)));
    }
  }
  return out;
}

describe('runtime dependencies load the way the portal loads them', () => {
  test('every ESM_ONLY entry is a runtime dependency', () => {
    for (const dep of ESM_ONLY) expect(deps).toContain(dep);
  });

  test.each(deps.filter((d) => !ESM_ONLY.has(d)))('%s loads with require()', (dep) => {
    expect(() => runNode(['-e', `require(${JSON.stringify(dep)})`])).not.toThrow();
  });

  test.each([...ESM_ONLY])('%s loads with import()', (dep) => {
    expect(() =>
      runNode(['--input-type=module', '-e', `await import(${JSON.stringify(dep)})`]),
    ).not.toThrow();
  });

  test.each([...ESM_ONLY])('%s is never require()d by portal source', (dep) => {
    // Any quote style, and subpaths (connect-redis/...), count.
    const name = dep.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const pattern = new RegExp(`require\\(\\s*['"\`]${name}(?:/[^'"\`]*)?['"\`]\\s*\\)`);
    const offenders = sourceFiles().filter((f) => pattern.test(fs.readFileSync(f, 'utf8')));
    expect(offenders).toEqual([]);
  });
});
