<?php

namespace OCA\JitsiCalendar\AppInfo;

use OCP\AppFramework\App;
use OCP\AppFramework\Bootstrap\IBootstrap;
use OCP\AppFramework\Bootstrap\IBootContext;
use OCP\AppFramework\Bootstrap\IRegistrationContext;
use OCP\AppFramework\Services\IInitialState;
use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;
use OCP\IConfig;
use OCP\Util;

class Application extends App implements IBootstrap {
	public const APP_ID = 'jitsi_calendar';

	public function __construct(array $urlParams = []) {
		parent::__construct(self::APP_ID, $urlParams);
	}

	public function register(IRegistrationContext $context): void {
		$context->registerEventListener(
			\OCP\AppFramework\Http\Events\BeforeTemplateRenderedEvent::class,
			BeforeTemplateRenderedListener::class
		);
	}

	public function boot(IBootContext $context): void {
	}
}

class BeforeTemplateRenderedListener implements IEventListener {
	public function handle(Event $event): void {
		$app = new Application();
		$container = $app->getContainer();

		// Provide Jitsi host to frontend via initial state
		$config = $container->get(IConfig::class);
		$jitsiHost = $config->getAppValue('jitsi_calendar', 'jitsi_host', '');
		if ($jitsiHost) {
			$initialState = $container->get(IInitialState::class);
			$initialState->provideInitialState('jitsi_host', $jitsiHost);
		}

		Util::addScript('jitsi_calendar', 'jitsi-calendar');
		Util::addStyle('jitsi_calendar', 'jitsi-calendar');
	}
}
