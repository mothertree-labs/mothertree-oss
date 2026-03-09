<?php

namespace OCA\GuestBridge\AppInfo;

use OCP\AppFramework\App;
use OCP\AppFramework\Bootstrap\IBootContext;
use OCP\AppFramework\Bootstrap\IBootstrap;
use OCP\AppFramework\Bootstrap\IRegistrationContext;
use OCA\GuestBridge\Capabilities;
use OCA\GuestBridge\Listener\ShareCreatedListener;
use OCA\GuestBridge\Search\MailSharePlugin;
use OCP\Collaboration\Collaborators\ISearch;
use OCP\Share\Events\ShareCreatedEvent;

class Application extends App implements IBootstrap {
	public const APP_ID = 'guest_bridge';

	public function __construct(array $urlParams = []) {
		parent::__construct(self::APP_ID, $urlParams);
	}

	public function register(IRegistrationContext $context): void {
		$context->registerEventListener(ShareCreatedEvent::class, ShareCreatedListener::class);
		$context->registerCapability(Capabilities::class);
	}

	public function boot(IBootContext $context): void {
		$server = $context->getServerContainer();
		/** @var ISearch $collaboratorSearch */
		$collaboratorSearch = $server->get(ISearch::class);
		$collaboratorSearch->registerPlugin([
			'shareType' => 'SHARE_TYPE_EMAIL',
			'class' => MailSharePlugin::class,
		]);
	}
}
