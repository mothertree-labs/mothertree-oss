<?php
// Lightweight OIDC health check — does NOT bootstrap full Nextcloud.
// Reads config.php for DB credentials, queries oc_appconfig directly.
//
// Used as a readiness probe via: php /var/www/html/oidc-health.php
// CLI mode: exit(0) = healthy, exit(1) = unhealthy
//
// IMPORTANT: Reports healthy when user_oidc is not yet configured (no row in DB).
// This prevents a deadlock on first deploy: deploy-nextcloud.sh waits for the
// pod to be Ready before running the OIDC config job, so the readiness probe
// must pass before OIDC is configured.

$configFile = '/var/www/html/config/config.php';
if (!file_exists($configFile)) {
    exit(0); // Nextcloud not installed yet — report healthy
}

require $configFile;

try {
    $dsn = "pgsql:host={$CONFIG['dbhost']};dbname={$CONFIG['dbname']}";
    $pdo = new PDO($dsn, $CONFIG['dbuser'], $CONFIG['dbpassword'], [
        PDO::ATTR_TIMEOUT => 2,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);
    $stmt = $pdo->prepare(
        "SELECT configvalue FROM oc_appconfig WHERE appid = 'user_oidc' AND configkey = 'allow_multiple_user_backends'"
    );
    $stmt->execute();
    $row = $stmt->fetch(PDO::FETCH_ASSOC);

    if (!$row) {
        // user_oidc not configured yet — report healthy
        exit(0);
    } elseif ($row['configvalue'] === '0') {
        exit(0);
    } else {
        // allow_multiple_user_backends is "1" — OIDC-only login is broken
        fwrite(STDERR, "FAIL: allow_multiple_user_backends={$row['configvalue']}\n");
        exit(1);
    }
} catch (Exception $e) {
    // DB unreachable — don't fail readiness for a transient DB issue
    exit(0);
}
