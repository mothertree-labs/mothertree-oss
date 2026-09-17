<?php

namespace OCA\GuestBridge\Middleware;

/**
 * Thrown by EmailShareLinkMiddleware to hand a redirect target back to itself.
 *
 * Middleware cannot return a response from beforeController, so the redirect
 * travels as an exception: MiddlewareDispatcher routes it to afterException on
 * every middleware that already ran, ours included.
 */
class EmailShareRedirect extends \Exception {

	private string $target;

	public function __construct(string $target) {
		parent::__construct('Redirecting to the email share this user received');
		$this->target = $target;
	}

	public function getTarget(): string {
		return $this->target;
	}
}
