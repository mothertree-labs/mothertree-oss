#!/usr/bin/env python3
"""
Email Probe - End-to-end email delivery monitoring.

Sends probe emails through Stalwart at regular intervals and checks for
auto-reply delivery. Exposes Prometheus metrics for alerting.

Email path tested (full E2E):
  Outbound: Stalwart (port 588) -> K8s Postfix (DKIM) -> VPN Postfix -> Internet
  Inbound:  Internet -> VPN Postfix -> K8s Postfix -> Stalwart -> bot inbox
"""

import imaplib
import logging
import os
import re
import smtplib
import ssl
import threading
import time
from email import policy
from email.mime.text import MIMEText
from email.parser import BytesParser
from email.utils import parsedate_to_datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("email-probe")

# ---------------------------------------------------------------------------
# Configuration from environment
# ---------------------------------------------------------------------------
SMTP_HOST = os.environ.get("SMTP_HOST", "stalwart")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "588"))
IMAP_HOST = os.environ.get("IMAP_HOST", "stalwart")
IMAP_PORT = int(os.environ.get("IMAP_PORT", "994"))
BOT_EMAIL = os.environ["BOT_EMAIL"]
BOT_PASSWORD = os.environ["BOT_PASSWORD"]
TARGET_EMAIL = os.environ["TARGET_EMAIL"]
PROBE_INTERVAL = int(os.environ.get("PROBE_INTERVAL", "300"))
PROBE_TIMEOUT = int(os.environ.get("PROBE_TIMEOUT", "300"))
TENANT_NAME = os.environ.get("TENANT_NAME", "unknown")
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9090"))
INFRA_DOMAIN = os.environ.get("INFRA_DOMAIN", "")

# Domains used to identify MT infrastructure in Received headers.
# Includes both the infra domain (VPN/K8s Postfix) and email domain (Stalwart).
_infra_domains = set()
_bot_domain = BOT_EMAIL.split("@", 1)[1] if "@" in BOT_EMAIL else ""
if _bot_domain:
    _infra_domains.add(_bot_domain)
if INFRA_DOMAIN:
    _infra_domains.add(INFRA_DOMAIN)

# ---------------------------------------------------------------------------
# Metrics state (protected by lock for thread safety)
# ---------------------------------------------------------------------------
_lock = threading.Lock()
_metrics = {
    "up": 1,
    "send_seconds": 0.0,
    "roundtrip_seconds": 0.0,
    "consecutive_failures": 0,
    "last_success_timestamp": 0.0,
    "send_total": 0,
    "send_errors_total": 0,
    "roundtrip_total": 0,
    "roundtrip_errors_total": 0,
    "inbound_total_seconds": 0.0,
    "inbound_infra_seconds": 0.0,
}


def _set(**kwargs):
    with _lock:
        _metrics.update(kwargs)


def _inc(**kwargs):
    with _lock:
        for k, v in kwargs.items():
            _metrics[k] = _metrics.get(k, 0) + v


def _render_metrics():
    with _lock:
        m = dict(_metrics)
    t = TENANT_NAME
    lines = [
        f'email_probe_up{{tenant="{t}"}} {m["up"]}',
        f'email_probe_send_seconds{{tenant="{t}"}} {m["send_seconds"]:.3f}',
        f'email_probe_roundtrip_seconds{{tenant="{t}"}} {m["roundtrip_seconds"]:.3f}',
        f'email_probe_consecutive_failures{{tenant="{t}"}} {m["consecutive_failures"]}',
        f'email_probe_last_success_timestamp{{tenant="{t}"}} {m["last_success_timestamp"]:.0f}',
        f'email_probe_send_total{{tenant="{t}"}} {m["send_total"]}',
        f'email_probe_send_errors_total{{tenant="{t}"}} {m["send_errors_total"]}',
        f'email_probe_roundtrip_total{{tenant="{t}"}} {m["roundtrip_total"]}',
        f'email_probe_roundtrip_errors_total{{tenant="{t}"}} {m["roundtrip_errors_total"]}',
        f'email_probe_inbound_total_seconds{{tenant="{t}"}} {m["inbound_total_seconds"]:.3f}',
        f'email_probe_inbound_infra_seconds{{tenant="{t}"}} {m["inbound_infra_seconds"]:.3f}',
    ]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# HTTP server for /metrics and /healthz
# ---------------------------------------------------------------------------
class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            body = _render_metrics().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass  # silence request logs


def _start_http_server():
    server = HTTPServer(("0.0.0.0", METRICS_PORT), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    log.info("Metrics server listening on :%d", METRICS_PORT)


# ---------------------------------------------------------------------------
# TLS context (skip verification for cluster-internal connections)
# ---------------------------------------------------------------------------
def _insecure_ssl_ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


# ---------------------------------------------------------------------------
# Send probe email via SMTP
# ---------------------------------------------------------------------------
def _send_probe(probe_id):
    msg = MIMEText(f"Email probe {probe_id} sent at {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}")
    msg["Subject"] = f"[email-probe] {probe_id}"
    msg["From"] = BOT_EMAIL
    msg["To"] = TARGET_EMAIL

    t0 = time.monotonic()
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as smtp:
        smtp.starttls(context=_insecure_ssl_ctx())
        smtp.login(BOT_EMAIL, BOT_PASSWORD)
        smtp.sendmail(BOT_EMAIL, [TARGET_EMAIL], msg.as_string())
    elapsed = time.monotonic() - t0
    return elapsed


# ---------------------------------------------------------------------------
# Parse Received headers for inbound timing
# ---------------------------------------------------------------------------
def _parse_inbound_timing(header_bytes):
    """Extract inbound timing from Received headers.

    Returns (total_inbound_secs, infra_inbound_secs).  Either may be None if
    there are not enough parseable headers.

    total_inbound = newest Received timestamp - oldest Received timestamp
    infra_inbound = newest MT-infra Received timestamp - oldest MT-infra Received timestamp
    """
    msg = BytesParser(policy=policy.default).parsebytes(header_bytes)
    received_headers = msg.get_all("Received", [])

    if len(received_headers) < 2:
        return None, None

    all_ts = []
    infra_ts = []

    for hdr in received_headers:
        hdr_str = str(hdr)
        # Timestamp follows the last semicolon in a Received header
        parts = hdr_str.rsplit(";", 1)
        if len(parts) < 2:
            continue
        try:
            dt = parsedate_to_datetime(parts[1].strip())
            ts = dt.timestamp()
        except Exception:
            continue

        all_ts.append(ts)

        # Check if the "by" host belongs to MT infrastructure
        by_match = re.search(r"\bby\s+(\S+)", hdr_str)
        if by_match:
            by_host = by_match.group(1).lower()
            if any(domain in by_host for domain in _infra_domains if domain):
                infra_ts.append(ts)

    total_inbound = None
    if len(all_ts) >= 2:
        total_inbound = max(all_ts) - min(all_ts)

    infra_inbound = None
    if len(infra_ts) >= 2:
        infra_inbound = max(infra_ts) - min(infra_ts)

    return total_inbound, infra_inbound


# ---------------------------------------------------------------------------
# Poll IMAP for reply containing probe_id
# ---------------------------------------------------------------------------
def _wait_for_reply(probe_id, timeout):
    """Wait for a reply containing probe_id. Returns (found, header_bytes)."""
    deadline = time.monotonic() + timeout
    poll_interval = 15

    while time.monotonic() < deadline:
        try:
            imap = imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT, ssl_context=_insecure_ssl_ctx())
            imap.login(BOT_EMAIL, BOT_PASSWORD)
            imap.select("INBOX")
            _, data = imap.search(None, "SUBJECT", f'"{probe_id}"')
            msg_nums = data[0].split()
            if msg_nums:
                # Fetch headers for inbound timing analysis
                _, msg_data = imap.fetch(msg_nums[0], "(RFC822.HEADER)")
                imap.logout()
                hdrs = msg_data[0][1] if msg_data and msg_data[0] else None
                return True, hdrs
            imap.logout()
        except Exception as e:
            log.warning("IMAP poll error: %s", e)

        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(poll_interval, remaining))

    return False, None


# ---------------------------------------------------------------------------
# Clean up inbox to prevent unbounded growth
# ---------------------------------------------------------------------------
def _cleanup_inbox():
    try:
        imap = imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT, ssl_context=_insecure_ssl_ctx())
        imap.login(BOT_EMAIL, BOT_PASSWORD)
        imap.select("INBOX")
        _, data = imap.search(None, "ALL")
        msg_nums = data[0].split()
        if msg_nums:
            for num in msg_nums:
                imap.store(num, "+FLAGS", "\\Deleted")
            imap.expunge()
            log.info("Cleaned up %d messages from inbox", len(msg_nums))
        imap.logout()
    except Exception as e:
        log.warning("Inbox cleanup error: %s", e)


# ---------------------------------------------------------------------------
# Main probe loop
# ---------------------------------------------------------------------------
def _probe_loop():
    log.info(
        "Probe loop starting: smtp=%s:%d imap=%s:%d bot=%s target=%s interval=%ds timeout=%ds",
        SMTP_HOST, SMTP_PORT, IMAP_HOST, IMAP_PORT, BOT_EMAIL, TARGET_EMAIL,
        PROBE_INTERVAL, PROBE_TIMEOUT,
    )

    while True:
        probe_id = f"probe-{int(time.time())}-{os.getpid()}"
        log.info("Starting probe cycle: %s", probe_id)

        # Phase 1: Send
        try:
            send_elapsed = _send_probe(probe_id)
            _set(send_seconds=send_elapsed)
            _inc(send_total=1)
            log.info("Probe sent in %.2fs: %s", send_elapsed, probe_id)
        except Exception as e:
            log.error("Send failed for %s: %s", probe_id, e)
            _inc(send_errors_total=1, consecutive_failures=1)
            _cleanup_inbox()
            time.sleep(PROBE_INTERVAL)
            continue

        # Phase 2: Wait for reply
        t0 = time.monotonic()
        try:
            found, hdrs = _wait_for_reply(probe_id, PROBE_TIMEOUT)
            roundtrip = time.monotonic() - t0

            if found:
                _set(roundtrip_seconds=roundtrip, consecutive_failures=0, last_success_timestamp=time.time())
                _inc(roundtrip_total=1)
                log.info("Reply received in %.1fs: %s", roundtrip, probe_id)

                # Parse Received headers for inbound timing
                if hdrs:
                    try:
                        total_in, infra_in = _parse_inbound_timing(hdrs)
                        if total_in is not None:
                            _set(inbound_total_seconds=total_in)
                            log.info("Inbound total: %.2fs", total_in)
                        if infra_in is not None:
                            _set(inbound_infra_seconds=infra_in)
                            log.info("Inbound MT infra: %.2fs", infra_in)
                    except Exception as e:
                        log.warning("Failed to parse inbound timing: %s", e)
            else:
                _set(roundtrip_seconds=roundtrip)
                _inc(roundtrip_errors_total=1, consecutive_failures=1)
                log.warning("No reply within %ds: %s", PROBE_TIMEOUT, probe_id)
        except Exception as e:
            log.error("Reply check failed for %s: %s", probe_id, e)
            _inc(roundtrip_errors_total=1, consecutive_failures=1)

        # Phase 3: Cleanup
        _cleanup_inbox()

        log.info("Sleeping %ds until next probe", PROBE_INTERVAL)
        time.sleep(PROBE_INTERVAL)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    _start_http_server()
    _probe_loop()
