<?php

namespace OCA\GuestBridge;

use OCP\Capabilities\ICapability;
use OCP\IConfig;

class Capabilities implements ICapability {

	private IConfig $config;

	public function __construct(IConfig $config) {
		$this->config = $config;
	}

	public function getCapabilities(): array {
		$apiUrl = $this->config->getSystemValueString('guest_bridge.api_url', '');
		$apiKey = $this->config->getSystemValueString('guest_bridge.api_key', '');

		return [
			'guest_bridge' => [
				'enabled' => true,
				'configured' => !empty($apiUrl) && !empty($apiKey),
			],
		];
	}
}
