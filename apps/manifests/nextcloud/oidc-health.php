<?php
// Lightweight OIDC + split-brain health check — does NOT bootstrap full Nextcloud.
// Reads config.php for DB credentials, queries oc_appconfig directly.
//
// Used as a readiness probe via: php /var/www/html/oidc-health.php
// CLI mode: exit(0) = healthy, exit(1) = unhealthy
//
// Checks:
//   1. OIDC-only login is enforced (allow_multiple_user_backends = 0)
//   2. No app version mismatch between disk and DB (split-brain detection)
//
// IMPORTANT: Reports healthy when user_oidc is not yet configured (no row in DB).
// This prevents a deadlock on first deploy: deploy-nextcloud.sh waits for the
// pod to be Ready before running the OIDC config job, so the readiness probe
// must pass before OIDC is configured.
//
// Split-brain detection: When some pods restart and download newer app versions
// while others keep old versions, `occ upgrade` on the new pod updates the DB
// schema. Old pods then have a file/DB version mismatch — they serve HTTP 503
// on all app routes but the liveness probe (status.php) still returns 200.
// This check catches that condition and removes the broken pod from service.

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

    // Check 1: OIDC-only login enforcement
    $stmt = $pdo->prepare(
        "SELECT configvalue FROM oc_appconfig WHERE appid = 'user_oidc' AND configkey = 'allow_multiple_user_backends'"
    );
    $stmt->execute();
    $row = $stmt->fetch(PDO::FETCH_ASSOC);

    if ($row && $row['configvalue'] !== '0') {
        fwrite(STDERR, "FAIL: allow_multiple_user_backends={$row['configvalue']}\n");
        exit(1);
    }
    // If no row: user_oidc not configured yet — skip this check (first deploy)

    // Check 2: App version mismatch detection (split-brain)
    // Compare app versions on disk (info.xml) against DB (oc_appconfig installed_version).
    // A mismatch means this pod has different app files than what the DB expects,
    // which causes Nextcloud to return 503 on all app routes.
    $appsToCheck = ['richdocuments', 'calendar', 'user_oidc', 'external', 'notify_push'];
    foreach ($appsToCheck as $appId) {
        $infoXml = "/var/www/html/custom_apps/$appId/appinfo/info.xml";
        if (!file_exists($infoXml)) {
            continue; // App not installed on disk — skip
        }

        $xml = @simplexml_load_file($infoXml);
        if (!$xml || !isset($xml->version)) {
            continue; // Can't parse version — skip rather than fail
        }
        $diskVersion = (string)$xml->version;

        $stmt = $pdo->prepare(
            "SELECT configvalue FROM oc_appconfig WHERE appid = ? AND configkey = 'installed_version'"
        );
        $stmt->execute([$appId]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);

        if ($row && $row['configvalue'] !== $diskVersion) {
            fwrite(STDERR, "FAIL: $appId version mismatch: disk=$diskVersion db={$row['configvalue']}\n");
            exit(1);
        }
    }

    exit(0);
} catch (Exception $e) {
    // DB unreachable — don't fail readiness for a transient DB issue
    exit(0);
}
