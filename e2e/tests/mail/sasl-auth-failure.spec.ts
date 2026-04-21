/**
 * E2E test: SASL auth failure against Stalwart's submission listener.
 *
 * Regression guard for the caller-side SASL wiring shipped in PR-2b
 * (Synapse, Docs, Nextcloud, Keycloak realm SMTP → Stalwart:588). Verifies
 * Stalwart returns a clean `535` on invalid credentials rather than hanging,
 * closing the socket, or returning a generic `500`. A hang here would cascade
 * into caller timeouts and breaks notification email delivery silently.
 *
 * Requires `E2E_STALWART_SMTP_SUBMISSION_PORT` — the external tenant-unique
 * submission port (e.g. `58700`) that forwards to stalwart:587 with STARTTLS.
 * Skips when unset so the spec can land ahead of the CI secret being added.
 */
import { test, expect } from '@playwright/test';
import * as net from 'net';
import * as tls from 'tls';

const baseDomain = process.env.E2E_BASE_DOMAIN || 'dev.example.com';
const smtpHost = process.env.E2E_STALWART_IMAP_HOST || `lb1.${baseDomain}`;
const smtpPortStr = process.env.E2E_STALWART_SMTP_SUBMISSION_PORT;

interface SmtpExchange {
  /** Multi-line 3-digit status code sequence for each reply received. */
  codes: number[];
  /** Concatenated raw server output (for diagnostics on failure). */
  transcript: string;
}

/**
 * Run a minimal SMTP dialogue: EHLO → STARTTLS → EHLO → AUTH PLAIN → QUIT.
 *
 * Returns the status code of the AUTH PLAIN response. Each reply is read with
 * a per-step timeout so a Stalwart hang surfaces as a failed test (the whole
 * point of this spec) rather than a wall-clock timeout in Playwright.
 */
async function sendSmtpAuthPlain(opts: {
  host: string;
  port: number;
  authBlob: string;
  replyTimeoutMs: number;
}): Promise<SmtpExchange> {
  const { host, port, authBlob, replyTimeoutMs } = opts;
  const codes: number[] = [];
  let transcript = '';

  const readReply = (stream: net.Socket | tls.TLSSocket) =>
    new Promise<number>((resolve, reject) => {
      const timer = setTimeout(() => {
        stream.removeListener('data', onData);
        reject(new Error(`SMTP reply timeout after ${replyTimeoutMs}ms — Stalwart stopped responding mid-dialogue`));
      }, replyTimeoutMs);
      let buf = '';
      const onData = (chunk: Buffer) => {
        buf += chunk.toString('utf8');
        transcript += chunk.toString('utf8');
        // SMTP reply line ends when we see "NNN " (space) vs "NNN-" (continuation).
        const lines = buf.split(/\r?\n/).filter(Boolean);
        const last = lines[lines.length - 1] || '';
        const m = /^(\d{3}) /.exec(last);
        if (m) {
          clearTimeout(timer);
          stream.removeListener('data', onData);
          resolve(parseInt(m[1], 10));
        }
      };
      stream.on('data', onData);
    });

  const plain = await new Promise<net.Socket>((resolve, reject) => {
    const s = net.connect({ host, port, timeout: replyTimeoutMs }, () => resolve(s));
    s.once('error', reject);
    s.once('timeout', () => reject(new Error(`TCP connect timeout to ${host}:${port}`)));
  });

  try {
    codes.push(await readReply(plain)); // 220 banner
    plain.write('EHLO e2e-sasl-test.local\r\n');
    codes.push(await readReply(plain)); // 250 EHLO
    plain.write('STARTTLS\r\n');
    codes.push(await readReply(plain)); // 220 ready to start TLS
  } catch (err) {
    plain.destroy();
    throw err;
  }

  // Upgrade to TLS. Self-signed certs are acceptable here — we only care about
  // protocol-level behaviour, not certificate validity.
  const secure = await new Promise<tls.TLSSocket>((resolve, reject) => {
    const t = tls.connect({ socket: plain, servername: host, rejectUnauthorized: false }, () => resolve(t));
    t.once('error', reject);
  });

  try {
    secure.write('EHLO e2e-sasl-test.local\r\n');
    codes.push(await readReply(secure)); // 250 EHLO (post-TLS)
    secure.write(`AUTH PLAIN ${authBlob}\r\n`);
    codes.push(await readReply(secure)); // THIS is the code under test
    secure.write('QUIT\r\n');
    // Best-effort QUIT; we don't care if the server has already closed.
    await readReply(secure).catch(() => 221);
  } finally {
    secure.destroy();
  }

  return { codes, transcript };
}

test.describe('Mail — SASL Auth Failure (PR-2b regression guard)', () => {
  test.skip(
    !smtpPortStr,
    'E2E_STALWART_SMTP_SUBMISSION_PORT not set — skipping SASL auth-failure test',
  );

  test('invalid SASL password returns 535, does not hang', async () => {
    test.setTimeout(30_000);

    const port = parseInt(smtpPortStr!, 10);
    expect(Number.isFinite(port) && port > 0, `Expected numeric port, got: ${smtpPortStr}`).toBe(true);

    // RFC 4616 PLAIN: \0<user>\0<pass>. The user/pass here are deliberately
    // garbage so Stalwart's OIDC directory short-circuits to a reject.
    const authBlob = Buffer.from('\0e2e-sasl-bogus@invalid.example\0not-a-real-password')
      .toString('base64');

    const result = await sendSmtpAuthPlain({
      host: smtpHost,
      port,
      authBlob,
      replyTimeoutMs: 10_000,
    });

    const authCode = result.codes[result.codes.length - 2]; // second-to-last (last is QUIT)
    expect(
      authCode,
      `Expected 535 (auth failure) from Stalwart, got ${authCode}. Transcript:\n${result.transcript}`,
    ).toBe(535);
  });
});
