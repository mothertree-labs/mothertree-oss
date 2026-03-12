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
 * Extract the body of a named function from source code.
 * Handles both "function name()" and "async function name()" forms.
 * Returns the function body string (including braces) or null if not found.
 */
function extractFunctionBody(src, funcName) {
  const pattern = new RegExp(`(?:async\\s+)?function\\s+${funcName}\\s*\\([^)]*\\)\\s*\\{`);
  const match = pattern.exec(src);
  if (!match) return null;

  let depth = 0;
  let inFunc = false;
  let body = '';
  for (let i = match.index; i < src.length; i++) {
    if (src[i] === '{') {
      depth++;
      inFunc = true;
    }
    if (src[i] === '}') {
      depth--;
    }
    if (inFunc) {
      body += src[i];
    }
    if (inFunc && depth === 0) break;
  }
  return body;
}

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

// ---------------------------------------------------------------------------
// Retry and dead-letter handling
// ---------------------------------------------------------------------------

describe('Retry and dead-letter handling', () => {
  it('DEAD_LETTER_FOLDER constant should be INBOX/iTIP-Failed', () => {
    assert.ok(
      source.includes("DEAD_LETTER_FOLDER = 'INBOX/iTIP-Failed'"),
      'DEAD_LETTER_FOLDER constant not found or has wrong value',
    );
  });

  it('MAX_RETRIES constant should exist', () => {
    assert.ok(
      source.includes('MAX_RETRIES = 5'),
      'MAX_RETRIES constant not found or has wrong value',
    );
  });

  it('moveToDeadLetter should flag message before moving', () => {
    const body = extractFunctionBody(source, 'moveToDeadLetter');
    assert.ok(body, 'moveToDeadLetter function not found');

    const flagIndex = body.indexOf('messageFlagsAdd');
    const moveIndex = body.indexOf('messageMove');

    assert.ok(flagIndex !== -1, 'messageFlagsAdd not found in moveToDeadLetter');
    assert.ok(moveIndex !== -1, 'messageMove not found in moveToDeadLetter');
    assert.ok(
      flagIndex < moveIndex,
      `messageFlagsAdd (index ${flagIndex}) must come before messageMove (index ${moveIndex}) — flag before move is critical because IMAP MOVE changes the UID`,
    );
  });

  it('processUser should call shouldSkipMessage', () => {
    const body = extractFunctionBody(source, 'processUser');
    assert.ok(body, 'processUser function not found');
    assert.ok(
      body.includes('shouldSkipMessage'),
      'processUser should call shouldSkipMessage to skip messages in backoff',
    );
  });

  it('metrics should include messagesDeadLettered and messagesSkippedBackoff', () => {
    assert.ok(
      source.includes('messagesDeadLettered'),
      'metrics.messagesDeadLettered not found in source',
    );
    assert.ok(
      source.includes('messagesSkippedBackoff'),
      'metrics.messagesSkippedBackoff not found in source',
    );
  });

  it('backoff should use exponential formula', () => {
    const body = extractFunctionBody(source, 'recordFailure');
    assert.ok(body, 'recordFailure function not found');
    assert.ok(
      body.includes('Math.pow(2,'),
      'recordFailure should use Math.pow(2, ...) for exponential backoff',
    );
  });
});
