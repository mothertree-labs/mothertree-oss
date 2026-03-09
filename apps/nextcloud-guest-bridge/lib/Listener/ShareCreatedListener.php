<?php

namespace OCA\GuestBridge\Listener;

use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;
use OCP\Share\Events\ShareCreatedEvent;
use OCP\Share\IShare;
use OCP\IConfig;
use OCP\IUserManager;
use Psr\Log\LoggerInterface;

/**
 * Listens for share creation events and provisions guest users when
 * a file/folder is shared with an external email address.
 *
 * When a share of type TYPE_EMAIL (4) is created:
 * 1. Suppress sharebymail's unauthenticated link email
 * 2. Call the account portal API to provision/notify the user
 *    - New users: creates Keycloak account + sends passkey setup email
 *    - Existing users: sends share notification email (Issue #168)
 * 3. After setup, they log in via OIDC and the share resolves to their user
 *
 * Does NOT interfere with:
 * - TYPE_LINK (3) — public links still work normally
 * - TYPE_USER (0) — shares with existing users are unaffected
 * - TYPE_GROUP (1) — group shares are unaffected
 */
class ShareCreatedListener implements IEventListener {

	private LoggerInterface $logger;
	private IConfig $config;
	private IUserManager $userManager;

	public function __construct(
		LoggerInterface $logger,
		IConfig $config,
		IUserManager $userManager
	) {
		$this->logger = $logger;
		$this->config = $config;
		$this->userManager = $userManager;
	}

	public function handle(Event $event): void {
		if (!($event instanceof ShareCreatedEvent)) {
			return;
		}

		$share = $event->getShare();

		// Only handle email shares (TYPE_EMAIL = 4)
		if ($share->getShareType() !== IShare::TYPE_EMAIL) {
			return;
		}

		// Suppress sharebymail's notification email immediately.
		// ShareManager checks $share->getMailSend() AFTER dispatching this event,
		// so setting it to false here prevents the unauthenticated link email.
		// The guest receives a passkey setup email from Account Portal instead.
		$share->setMailSend(false);

		$email = $share->getSharedWith();
		if (empty($email)) {
			return;
		}

		$this->logger->info(
			'Guest bridge: email share created for {email}, suppressed sharebymail notification',
			['app' => 'guest_bridge', 'email' => $email]
		);

		// Always call the account portal API, even for existing users.
		// For new users: creates the Keycloak account and sends a setup email.
		// For existing users: sends a share notification email so they know
		// a file was shared with them (Issue #168). Without this, existing
		// users receive no notification because setMailSend(false) above
		// suppresses sharebymail's email, and there's no other notification path.
		$this->provisionGuestUser($email, $share);
	}

	/**
	 * Call the account portal API to create a guest user in Keycloak.
	 * This is fire-and-forget — failures are logged but don't block the share.
	 */
	private function provisionGuestUser(string $email, IShare $share): void {
		$apiUrl = $this->config->getSystemValueString('guest_bridge.api_url', '');
		$apiKey = $this->config->getSystemValueString('guest_bridge.api_key', '');

		if (empty($apiUrl) || empty($apiKey)) {
			$this->logger->warning(
				'Guest bridge: API URL or key not configured, skipping guest provisioning for {email}',
				['app' => 'guest_bridge', 'email' => $email]
			);
			return;
		}

		$sharerUid = $share->getSharedBy();
		$sharerUser = $this->userManager->get($sharerUid);
		$sharerName = $sharerUser ? $sharerUser->getDisplayName() : $sharerUid;

		$payload = json_encode([
			'email' => $email,
			'firstName' => '',
			'lastName' => '',
			'shareContext' => [
				'type' => 'file',
				'documentName' => $share->getNode()->getName(),
				'sharerName' => $sharerName,
				'shareToken' => $share->getToken(),
			],
		]);

		$ch = curl_init($apiUrl);
		curl_setopt_array($ch, [
			CURLOPT_POST => true,
			CURLOPT_POSTFIELDS => $payload,
			CURLOPT_HTTPHEADER => [
				'Content-Type: application/json',
				'X-API-Key: ' . $apiKey,
			],
			CURLOPT_RETURNTRANSFER => true,
			CURLOPT_TIMEOUT => 10,
			CURLOPT_CONNECTTIMEOUT => 5,
		]);

		$response = curl_exec($ch);
		$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
		$curlError = curl_error($ch);
		curl_close($ch);

		if ($curlError) {
			$this->logger->error(
				'Guest bridge: API call failed for {email}: {error}',
				['app' => 'guest_bridge', 'email' => $email, 'error' => $curlError]
			);
			return;
		}

		$data = json_decode($response, true);

		if ($httpCode >= 200 && $httpCode < 300 && !empty($data['success'])) {
			$existing = !empty($data['existing']) ? ' (already existed)' : '';
			$this->logger->info(
				'Guest bridge: guest provisioned for {email}, userId={userId}{existing}',
				[
					'app' => 'guest_bridge',
					'email' => $email,
					'userId' => $data['userId'] ?? 'unknown',
					'existing' => $existing,
				]
			);
		} else {
			$errorMsg = $data['error'] ?? "HTTP $httpCode";
			$this->logger->error(
				'Guest bridge: provisioning failed for {email}: {error}',
				['app' => 'guest_bridge', 'email' => $email, 'error' => $errorMsg]
			);
		}
	}
}
