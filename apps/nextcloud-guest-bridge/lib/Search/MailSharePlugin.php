<?php

namespace OCA\GuestBridge\Search;

use OCP\Collaboration\Collaborators\ISearchPlugin;
use OCP\Collaboration\Collaborators\ISearchResult;
use OCP\Collaboration\Collaborators\SearchResultType;
use OCP\IUserManager;
use OCP\Share\IShare;

/**
 * Ensures the email share option (TYPE_EMAIL) is always available in the
 * share dialog, even when the email belongs to an existing Nextcloud user.
 *
 * Problem: Nextcloud's sharebymail SearchPlugin skips adding the email option
 * when the email matches an existing user. It assumes the UserPlugin will show
 * the user as a TYPE_USER share target. But in Mothertree's guest flow, TYPE_EMAIL
 * shares trigger guest_bridge provisioning. Without the email option, users cannot
 * re-share with previously provisioned guests via email (Issue #168).
 *
 * This plugin complements sharebymail's SearchPlugin by adding the email option
 * only when a local user with that email exists (the case sharebymail skips).
 * When no local user exists, sharebymail already provides the email option.
 */
class MailSharePlugin implements ISearchPlugin {

	private IUserManager $userManager;

	public function __construct(IUserManager $userManager) {
		$this->userManager = $userManager;
	}

	public function search($search, $limit, $offset, ISearchResult $searchResult) {
		if (!filter_var($search, FILTER_VALIDATE_EMAIL)) {
			return false;
		}

		// Only add the email option when the email belongs to an existing user.
		// When no user exists, sharebymail's SearchPlugin already adds the email
		// to the results. When a user DOES exist, sharebymail skips the email
		// (assuming TYPE_USER is sufficient). We add it back so that sharing via
		// email always works, even for known users.
		$users = $this->userManager->getByEmail($search);
		if (empty($users)) {
			return false;
		}

		$resultType = new SearchResultType('emails');
		$searchResult->addResultSet($resultType, [], [[
			'label' => $search,
			'uuid' => $search,
			'name' => '',
			'type' => '',
			'value' => [
				'shareType' => IShare::TYPE_EMAIL,
				'shareWith' => $search,
			],
		]]);

		return false;
	}
}
