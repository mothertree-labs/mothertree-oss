<?php
// Bulk CalDAV app password generator — creates tokens via Nextcloud's internal
// ITokenProvider API without requiring allow_multiple_user_backends=1.
//
// Usage: echo '["user1@example.com","user2@example.com"]' | php create-caldav-tokens.php [token-name]
//
// Reads a JSON array of user IDs from stdin.
// Outputs a JSON object mapping user IDs to raw app passwords on stdout.
// Diagnostic messages go to stderr.
//
// The key insight: occ user:auth-tokens:add requires allow_multiple_user_backends=1
// because it resolves users via IUserManager::get(), which fails when only the OIDC
// backend is active. But ITokenProvider::generateToken() takes plain string UIDs —
// no user resolution needed. This script calls generateToken() directly, bypassing
// the backend check entirely.
//
// This eliminates the 6-minute window where allow_multiple_user_backends=1 poisons
// the readiness probe (oidc-health.php) on ALL Nextcloud pods, causing NextcloudDown
// alerts during every CI deploy.

define("OC_CONSOLE", 1);
require_once "/var/www/html/lib/base.php";

$tokenName = $argv[1] ?? "calendar-automation";

$provider = \OC::$server->get(\OC\Authentication\Token\IProvider::class);
$random = \OC::$server->get(\OCP\Security\ISecureRandom::class);

$input = trim(file_get_contents("php://stdin"));
$users = json_decode($input, true);
if (!is_array($users) || empty($users)) {
    fwrite(STDERR, "ERROR: pass a JSON array of user IDs on stdin\n");
    exit(1);
}

fwrite(STDERR, "Creating $tokenName tokens for " . count($users) . " users...\n");
$results = [];
$failed = 0;
$start = microtime(true);

foreach ($users as $uid) {
    $rawToken = $random->generate(72,
        \OCP\Security\ISecureRandom::CHAR_UPPER .
        \OCP\Security\ISecureRandom::CHAR_LOWER .
        \OCP\Security\ISecureRandom::CHAR_DIGITS
    );
    try {
        $provider->generateToken(
            $rawToken,
            $uid,
            $uid,
            null, // no password — CalDAV auth uses the raw token directly
            $tokenName,
            \OCP\Authentication\Token\IToken::PERMANENT_TOKEN,
            \OCP\Authentication\Token\IToken::DO_NOT_REMEMBER
        );
        $results[$uid] = $rawToken;
    } catch (\Exception $e) {
        fwrite(STDERR, "  FAIL: $uid — " . $e->getMessage() . "\n");
        $failed++;
    }
}

$elapsed = microtime(true) - $start;
fwrite(STDERR, sprintf(
    "Done: %d created, %d failed in %.1fs (%.0f tokens/sec)\n",
    count($results), $failed, $elapsed,
    count($results) > 0 ? count($results) / $elapsed : 0
));

echo json_encode($results);
