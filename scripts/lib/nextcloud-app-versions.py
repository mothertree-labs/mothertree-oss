#!/usr/bin/env python3
"""Release selection for the pinned Nextcloud apps.

Single source of truth for "which release should app X be on", shared by the
report and the --update writeback in scripts/check-nextcloud-app-versions.sh.
They used to each pick `releases[0]` independently, which is how a release
candidate reached apps/manifests/nextcloud/app-versions.json.

Two separate defects in that `releases[0]`:
  * it includes prereleases — the store lists 6.6.0-rc.2 above 6.5.4;
  * the store orders releases as STRINGS, so `8.9.0` sorts above `8.11.0` and
    user_oidc reported "up to date" two minor versions behind.

Selection rules:
  * skip nightlies (`isNightly`) and prereleases (any semver `-suffix`) unless
    --allow-prerelease;
  * pick the highest version by semver order, not the API's array order;
  * only report an update when the candidate is strictly newer than the pin, so
    a reordered or withdrawn release can never propose a downgrade;
  * every download URL — the one already pinned as well as any newly proposed
    one — must be https on an allow-listed host. NOTE this is a review aid, not
    a fetch-time control: the init container fetches with `curl -sfL`, which
    follows redirects, and verifies no checksum (see issue #654).

Fail-fast (this project's rule: never silently skip). These are errors, not
lines of output nobody reads:
  * a pinned app missing from the store, or with no installable release;
  * a version string we cannot parse — see UnparseableVersion below;
  * a pin that is itself a prerelease, without --allow-prerelease;
  * a selected release served from a non-allow-listed host.

Exit codes:  0 up to date · 1 error · 2 updates available
"""
import hashlib
import io
import json
import os
import re
import sys
import tarfile
import urllib.error
import urllib.request
from urllib.parse import urlparse

_STABLE, _PRERELEASE = 1, 0

# Every release of all six pinned apps is served from github.com today (130/130,
# checked against the live store). An app moving hosts is a supply-chain change
# that a human should see, so a new host is an error rather than a silent trust
# extension. Override for a legitimate move:
#   MT_NC_ALLOWED_DOWNLOAD_HOSTS=github.com,codeberg.org
_DEFAULT_ALLOWED_HOSTS = ("github.com",)


def allowed_hosts():
    override = os.environ.get("MT_NC_ALLOWED_DOWNLOAD_HOSTS", "").strip()
    if not override:
        return set(_DEFAULT_ALLOWED_HOSTS)
    return {h.strip().lower() for h in override.split(",") if h.strip()}


# urlsplit() strips \t, \r and \n *before* parsing, so a URL carrying an
# embedded newline reports a perfectly respectable hostname while the raw string
# still contains a second line. That raw string is what reaches the manifest,
# and deploy-nextcloud.sh renders the manifest into "<app_id>|<url>" lines that
# the Nextcloud init container reads ONE PER LINE — so one smuggled newline
# installs an entirely unpinned app from an arbitrary host. Reject first, parse
# second. Note url.strip() is not sufficient: the newline is embedded, not
# trailing.
_UNSAFE_URL_CHARS = re.compile(r"[\x00-\x20\x7f]")

_ASCII_DIGITS = re.compile(r"[0-9]+")
_PRERELEASE_IDENT = re.compile(r"[0-9A-Za-z-]+")  # semver identifier charset


class UnparseableVersion(ValueError):
    """A version string whose core components are not all numeric.

    This used to coerce non-numeric components to 0, which is a filter bypass
    rather than a parse: `6.6.0.rc2` became (6, 6, 0, 0) — sorting ABOVE stable
    6.5.4 and never matching the `-` prerelease test. Refusing to parse is the
    only safe reading of a version we do not understand.
    """


def parse_version(version):
    """Return (sort_key, is_prerelease). Raises UnparseableVersion.

    The sort key orders a stable release above any prerelease of the same core
    version (1.4.0 > 1.4.0-rc.2), per semver precedence.
    """
    if not isinstance(version, str) or not version:
        raise UnparseableVersion(repr(version))

    # Everything after "+" is build metadata: ignored for ordering, but it stays
    # in the raw string that is printed into the commit message and PR body and
    # written to the manifest. Unvalidated, "1.0.0+x -> y" style payloads survive
    # the workflow's `grep ' -> '` filter and fabricate lines in the very summary
    # a human reviews. Same charset semver already requires of identifiers.
    versioned, plus, build = version.partition("+")
    if plus and not all(_PRERELEASE_IDENT.fullmatch(i) for i in build.split(".")):
        raise UnparseableVersion(version)

    core, hyphen, prerelease = versioned.partition("-")

    # str.isdigit() is NOT an ASCII test: Arabic-Indic "\u0663" satisfies it and
    # int()s to 3, so "\u0663.0.0" would parse as a perfectly ordinary stable
    # 3.0.0 while rendering as something else entirely in the PR body. Worse,
    # superscripts like "\u00b2" pass isdigit() but make int() raise a bare
    # ValueError that `except UnparseableVersion` cannot catch. Match ASCII
    # digits explicitly instead.
    components = core.split(".")
    if not (1 <= len(components) <= 4) or not all(_ASCII_DIGITS.fullmatch(c) for c in components):
        raise UnparseableVersion(version)
    parts = [int(c) for c in components]
    parts += [0] * (4 - len(parts))
    core_key = tuple(parts)

    if not hyphen:
        return (core_key, _STABLE, ()), False

    identifiers = prerelease.split(".")
    if not prerelease or not all(_PRERELEASE_IDENT.fullmatch(i) for i in identifiers):
        raise UnparseableVersion(version)

    # Semver: numeric identifiers sort below alphanumeric ones, and compare
    # numerically among themselves.
    pre_key = tuple(
        (0, int(ident), "") if ident.isdigit() else (1, 0, ident)
        for ident in identifiers
    )
    return (core_key, _PRERELEASE, pre_key), True


def select_release(releases, allow_prerelease=False):
    """Return (release, stats) — the highest installable release, or None.

    `stats["unparseable"]` is kept apart from the routine nightly/prerelease
    skips. Silently falling back past a version we cannot read is the same
    silent-stall this script exists to remove: if upstream re-tags as "v8.11.0",
    that entry is skipped, the older 8.9.0 below it wins, and the app reports
    "up to date" forever behind a green scheduled run. All 4667 releases in the
    store parse today, so an unparseable entry is a real anomaly worth stopping
    on rather than expected noise.
    """
    candidates = []
    stats = {"nightly": 0, "prerelease": 0, "unparseable": []}
    for release in releases:
        if release.get("isNightly"):
            stats["nightly"] += 1
            continue
        try:
            key, is_prerelease = parse_version(release.get("version"))
        except UnparseableVersion:
            stats["unparseable"].append(release.get("version"))
            continue
        if is_prerelease and not allow_prerelease:
            stats["prerelease"] += 1
            continue
        candidates.append((key, release))

    if not candidates:
        return None, stats
    return max(candidates, key=lambda pair: pair[0])[1], stats


def check_download_url(url, hosts):
    """Return an error string if `url` is not an allow-listed https download."""
    if not url:
        return "has no download URL"
    if _UNSAFE_URL_CHARS.search(url):
        return "contains whitespace or control characters"
    try:
        parsed = urlparse(url)
    except ValueError as exc:
        # urlparse raises on an unterminated IPv6 literal and on netlocs that
        # fail NFKC normalisation (fullwidth solidus/at). Letting that escape
        # would abort the per-app loop with a traceback, so the other five apps
        # would never be checked — and the operator would see a stack trace
        # instead of the error line this function exists to produce.
        return f"could not be parsed as a URL ({exc})"
    if parsed.scheme != "https":
        return f"is served over {parsed.scheme or '(no scheme)'}, not https"
    host = (parsed.hostname or "").lower()
    if host not in hosts:
        return (f"is served from {host or '(no host)'}, which is not in the "
                f"allowed download hosts ({', '.join(sorted(hosts))})")
    return None


_SHA256_RE = re.compile(r"[0-9a-f]{64}")


class _HttpsOnlyRedirect(urllib.request.HTTPRedirectHandler):
    """Follow redirects only to https URLs (GitHub hands release assets to
    another host, so redirects must work, but never a downgrade)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlparse(newurl).scheme != "https":
            raise urllib.error.URLError(f"refusing non-https redirect to {newurl!r}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_tarball(url):
    """Return the bytes of the release tarball at `url` (https only).

    MT_NC_TARBALL_FIXTURES=<dir> is a test hook: read <dir>/<basename of url>
    instead of touching the network.
    """
    fixtures = os.environ.get("MT_NC_TARBALL_FIXTURES")
    if fixtures:
        with open(os.path.join(fixtures, os.path.basename(urlparse(url).path)), "rb") as f:
            return f.read()
    if urlparse(url).scheme != "https":
        raise ValueError(f"not https: {url!r}")
    opener = urllib.request.build_opener(_HttpsOnlyRedirect)
    req = urllib.request.Request(url, headers={"User-Agent": "mothertree-nc-app-versions"})
    with opener.open(req, timeout=300) as resp:
        return resp.read()


def tarball_sha256(app_id, url):
    """sha256 of the release tarball, after checking it really is `app_id`.

    The init container extracts <app_id>/ from the tarball and requires
    <app_id>/appinfo/info.xml, so pinning a digest for anything else would
    only move the failure to pod boot.
    """
    data = fetch_tarball(url)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        names = set(tar.getnames())
    if f"{app_id}/appinfo/info.xml" not in names:
        raise ValueError(f"tarball has no {app_id}/appinfo/info.xml")
    return hashlib.sha256(data).hexdigest()


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    unknown = flags - {"--update", "--allow-prerelease"}
    if unknown:
        # A typo like `--updates` used to be accepted and silently do nothing.
        print(f"ERROR: unknown option(s): {' '.join(sorted(unknown))}", file=sys.stderr)
        return 1
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 1
    manifest_path, api_path = args
    allow_prerelease = "--allow-prerelease" in flags
    update_mode = "--update" in flags
    hosts = allowed_hosts()

    with open(manifest_path) as f:
        manifest = json.load(f)
    with open(api_path) as f:
        app_index = {a["id"]: a for a in json.load(f)}

    updates, errors = [], []

    for app_id, info in sorted(manifest["apps"].items()):
        # Support both formats: {"version": "x", "url": "..."} and plain "version"
        pinned = info["version"] if isinstance(info, dict) else info

        try:
            pinned_key, pinned_is_pre = parse_version(pinned)
        except UnparseableVersion:
            errors.append(f"{app_id}: pinned version {pinned!r} is not a version "
                          f"we can parse")
            continue

        # Re-check what is ALREADY pinned, every run. Validating only newly
        # proposed URLs leaves a manifest whose pin is equal to or ahead of the
        # store permanently unexamined — it would report "up to date" or "ahead
        # of the store" and exit clean no matter what URL it carried.
        if not isinstance(info, dict):
            errors.append(f"{app_id}: pin must be an object with version, url "
                          f"and sha256 (#654)")
            continue
        problem = check_download_url(info.get("url"), hosts)
        if problem:
            errors.append(f"{app_id}: the pinned download URL {problem}")
            continue
        # The init container refuses a tarball that does not match this pin
        # (#654); a pin without one would fail every Nextcloud pod boot.
        if not _SHA256_RE.fullmatch(str(info.get("sha256", ""))):
            errors.append(f"{app_id}: the pinned sha256 is missing or malformed "
                          f"(got {info.get('sha256')!r})")
            continue

        if pinned_is_pre and not allow_prerelease:
            # Left alone, this reports "up to date" forever: an RC's core version
            # is ahead of the newest stable, so it looks like a pin ahead of the
            # store and no update is ever proposed for the app.
            errors.append(f"{app_id}: pinned at prerelease {pinned} — pin a stable "
                          f"release, or re-run with --allow-prerelease")
            continue

        app = app_index.get(app_id)
        if app is None:
            errors.append(f"{app_id}: pinned at {pinned} but not in the app store "
                          f"for this platform version")
            continue

        chosen, stats = select_release(app.get("releases", []), allow_prerelease)

        if stats["unparseable"]:
            # Falling back past these would hide a newer release behind a green
            # run — e.g. upstream re-tagging as "v8.11.0" above a readable 8.9.0.
            bad = ", ".join(repr(v) for v in stats["unparseable"][:5])
            errors.append(f"{app_id}: {len(stats['unparseable'])} release(s) have "
                          f"version strings we cannot parse ({bad}) — a newer "
                          f"release may be hidden behind them")
            continue

        if chosen is None:
            errors.append(f"{app_id}: pinned at {pinned}, no installable release "
                          f"({stats['nightly']} nightly, {stats['prerelease']} "
                          f"prerelease rejected)")
            continue

        latest = chosen["version"]
        latest_key, _ = parse_version(latest)

        if latest_key > pinned_key:
            problem = check_download_url(chosen.get("download"), hosts)
            if problem:
                errors.append(f"{app_id}: the {latest} download URL {problem}")
                continue
            print(f"  {app_id}: {pinned} -> {latest}")
            updates.append((app_id, chosen))
        elif latest_key < pinned_key:
            # Pin ahead of the newest stable release: a release pulled from the
            # store, or a hand-edited manifest. Say so instead of ignoring it.
            print(f"  {app_id}: {pinned} (no update; ahead of the store, "
                  f"newest stable is {latest})")
        else:
            print(f"  {app_id}: {pinned} (up to date)")

    if errors:
        print("", file=sys.stderr)
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        print(f"\n{len(errors)} pinned app(s) could not be resolved — refusing to "
              f"report a clean result.", file=sys.stderr)
        return 1

    if not updates:
        print("\nAll apps are up to date")
        return 0

    print(f"\n{len(updates)} update(s) available")

    if update_mode:
        # Fetch and hash every selected release BEFORE touching the manifest:
        # one bad tarball must not leave a half-written file behind.
        digests, fetch_errors = {}, []
        for app_id, chosen in updates:
            try:
                digests[app_id] = tarball_sha256(app_id, chosen["download"])
            except Exception as exc:  # network, tar, missing info.xml
                fetch_errors.append(f"{app_id}: could not verify the {chosen['version']} "
                                    f"tarball: {exc}")
        if fetch_errors:
            print("", file=sys.stderr)
            for err in fetch_errors:
                print(f"ERROR: {err}", file=sys.stderr)
            print("\nManifest NOT updated.", file=sys.stderr)
            return 1
        for app_id, chosen in updates:
            fields = {"version": chosen["version"], "url": chosen["download"],
                      "sha256": digests[app_id]}
            existing = manifest["apps"][app_id]
            if isinstance(existing, dict):
                # Merge unrelated fields, but DROP anything bound to the bytes of
                # the old release. A checksum is the case that matters (#654):
                # carrying a 6.4.2 sha256 onto the 6.5.4 tarball either breaks
                # the install or, worse, leaves the manifest asserting a checksum
                # for a different file while the diff shows an UNCHANGED sha256
                # line — no signal at all for the reviewer.
                #
                # The sha256 is recomputed above from the release just
                # selected (#654) and set by `fields`; the key list below is a
                # tripwire for any other stale content-bound value.
                for content_bound in ("sha256", "sha512", "checksum", "integrity",
                                      "digest", "signature", "signatureDigest"):
                    existing.pop(content_bound, None)
                existing.update(fields)
            else:
                manifest["apps"][app_id] = fields
        with open(manifest_path, "w") as f:
            json.dump(manifest, f, indent=2)
            f.write("\n")
        print("Manifest updated successfully")

    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
