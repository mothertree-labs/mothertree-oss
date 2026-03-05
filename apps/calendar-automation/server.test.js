/**
 * Verify that all CalDAV PUT calls in server.js include the Schedule-Reply: F
 * header, which suppresses Nextcloud's IMipPlugin from sending outbound iMIP
 * emails on programmatic PUTs.
 *
 * This is a source-level check (not a behavioral unit test) because server.js
 * is a monolith that starts a server on load and doesn't export functions.
 * It catches accidental removal of the header during refactoring.
 *
 * Run: node --test server.test.js
 */
import { describe, it } from 'node:test';
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(__dirname, 'server.js'), 'utf-8');

/**
 * Extract all fetch() call blocks that use method: 'PUT' from the source.
 * Returns an array of { functionName, fetchBlock } objects.
 */
function extractPutFetchCalls(src) {
  const results = [];

  // Match "async function <name>" followed by a fetch() call with method: 'PUT'
  // We look for function boundaries to associate each fetch with its function.
  const funcPattern = /async function (\w+)\s*\([^)]*\)\s*\{/g;
  let funcMatch;

  while ((funcMatch = funcPattern.exec(src)) !== null) {
    const funcName = funcMatch[1];
    const funcStart = funcMatch.index;

    // Find the function body by counting braces
    let depth = 0;
    let inFunc = false;
    let funcBody = '';
    for (let i = funcStart; i < src.length; i++) {
      if (src[i] === '{') {
        depth++;
        inFunc = true;
      }
      if (src[i] === '}') {
        depth--;
      }
      if (inFunc) {
        funcBody += src[i];
      }
      if (inFunc && depth === 0) break;
    }

    // Find fetch() calls with method: 'PUT' in this function body
    const fetchPattern = /fetch\s*\([^,]+,\s*\{[^}]*method:\s*['"]PUT['"][^}]*\}/gs;
    let fetchMatch;
    while ((fetchMatch = fetchPattern.exec(funcBody)) !== null) {
      results.push({ functionName: funcName, fetchBlock: fetchMatch[0] });
    }
  }

  return results;
}

describe('CalDAV PUT requests include Schedule-Reply header', () => {
  const putCalls = extractPutFetchCalls(source);

  it('should find at least 2 CalDAV PUT fetch calls', () => {
    assert.ok(
      putCalls.length >= 2,
      `Expected at least 2 PUT fetch calls, found ${putCalls.length}: ${putCalls.map((c) => c.functionName).join(', ')}`,
    );
  });

  it('caldavPutEventAt should include Schedule-Reply: F', () => {
    const call = putCalls.find((c) => c.functionName === 'caldavPutEventAt');
    assert.ok(call, 'caldavPutEventAt not found among PUT fetch calls');
    assert.ok(
      call.fetchBlock.includes("'Schedule-Reply'") ||
        call.fetchBlock.includes('"Schedule-Reply"'),
      `caldavPutEventAt fetch block missing Schedule-Reply header:\n${call.fetchBlock}`,
    );
  });

  it('caldavPutEvent should include Schedule-Reply: F', () => {
    const call = putCalls.find((c) => c.functionName === 'caldavPutEvent');
    assert.ok(call, 'caldavPutEvent not found among PUT fetch calls');
    assert.ok(
      call.fetchBlock.includes("'Schedule-Reply'") ||
        call.fetchBlock.includes('"Schedule-Reply"'),
      `caldavPutEvent fetch block missing Schedule-Reply header:\n${call.fetchBlock}`,
    );
  });

  it('all PUT fetch calls should include Schedule-Reply header', () => {
    for (const call of putCalls) {
      assert.ok(
        call.fetchBlock.includes("'Schedule-Reply'") ||
          call.fetchBlock.includes('"Schedule-Reply"'),
        `${call.functionName} PUT fetch is missing Schedule-Reply header:\n${call.fetchBlock}`,
      );
    }
  });
});
