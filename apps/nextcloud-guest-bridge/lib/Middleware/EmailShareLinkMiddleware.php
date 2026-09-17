<?php

namespace OCA\GuestBridge\Middleware;

use OCP\AppFramework\Http\RedirectResponse;
use OCP\AppFramework\Http\Response;
use OCP\AppFramework\Middleware;
use OCP\DB\QueryBuilder\IQueryBuilder;
use OCP\Files\Folder;
use OCP\Files\IRootFolder;
use OCP\IDBConnection;
use OCP\IRequest;
use OCP\IURLGenerator;
use OCP\IUserSession;
use OCP\Share\IManager as IShareManager;
use OCP\Share\IShare;
use Psr\Log\LoggerInterface;

/**
 * Sends a guest who opens an internal file link to the email share they received.
 *
 * Owners share links copied from Nextcloud — the sidebar's "Internal link" or the
 * browser address bar while editing — which point at /f/<fileid> or
 * /apps/files/files/<fileid>. Those only work for someone who can already see the
 * file in their own Files. An email share (TYPE_EMAIL) is never mounted for a user:
 * files_sharing's MountProvider mounts USER, GROUP, CIRCLE, ROOM, DECK and
 * SCIENCEMESH shares only. The file is reachable exclusively at /s/<token>, so the
 * guest used to land on "not found" even after logging in (Issue #718).
 *
 * This middleware watches the files app's view entry points and redirects to
 * /s/<token> when ALL of these hold:
 *
 *   1. someone is logged in and the file id is NOT reachable in their own Files
 *      (everyone who can already open the file keeps stock behaviour);
 *   2. an email share on that file — or on a folder containing it — is addressed
 *      to their uid, which for our Keycloak users is their email address
 *      (user_oidc runs with --mapping-uid=email);
 *   3. the share manager still accepts the token, i.e. /s/<token> would open.
 *
 * Recipients are matched on the Nextcloud uid, which under --mapping-uid=email is
 * the email address in the user's Keycloak token — the same identity the rest of the
 * platform is keyed on.
 *
 * Note that resolving a token through the share manager is what /s/<token> itself
 * does, including its side effect: an expired share is deleted as it is rejected.
 *
 * Security: only shares addressed to the caller are ever considered, so no one can
 * probe for other people's shares. The token reaches a session whose uid is the
 * recipient address, and the invite email already delivered that same token to that
 * mailbox. Revocation and expiry need no special handling — the guest is sent to the
 * very share the owner controls, so when it goes away, so does their access.
 */
class EmailShareLinkMiddleware extends Middleware {

	/**
	 * The files app entry points that take a file id. /f/{fileid} (showFile) is
	 * hardcoded in the server; the others back /apps/files/{view}/{fileid}, which
	 * is what the address bar shows while a file is open.
	 */
	private const FILES_VIEW_CONTROLLER = 'OCA\Files\Controller\ViewController';
	private const FILES_VIEW_METHODS = ['showfile', 'index', 'indexview', 'indexviewfileid'];

	/** Cap on the email shares considered per request — see folderEmailShares(). */
	private const MAX_CANDIDATE_SHARES = 25;

	private IRequest $request;
	private IUserSession $userSession;
	private IRootFolder $rootFolder;
	private IDBConnection $db;
	private IShareManager $shareManager;
	private IURLGenerator $urlGenerator;
	private LoggerInterface $logger;

	public function __construct(
		IRequest $request,
		IUserSession $userSession,
		IRootFolder $rootFolder,
		IDBConnection $db,
		IShareManager $shareManager,
		IURLGenerator $urlGenerator,
		LoggerInterface $logger
	) {
		$this->request = $request;
		$this->userSession = $userSession;
		$this->rootFolder = $rootFolder;
		$this->db = $db;
		$this->shareManager = $shareManager;
		$this->urlGenerator = $urlGenerator;
		$this->logger = $logger;
	}

	/**
	 * @param \OCP\AppFramework\Controller $controller
	 * @param string $methodName
	 * @throws EmailShareRedirect when the caller should be sent to their email share
	 */
	public function beforeController($controller, $methodName) {
		// Runs for every controller in every app (registered globally), so bail out
		// on the cheapest check first. is_a() with an object never autoloads.
		if (!is_a($controller, self::FILES_VIEW_CONTROLLER)) {
			return;
		}
		if (!in_array(strtolower($methodName), self::FILES_VIEW_METHODS, true)) {
			return;
		}

		// Deleted files live in the trashbin view and are looked up elsewhere.
		if ($this->request->getParam('view') === 'trashbin') {
			return;
		}

		$fileId = $this->request->getParam('fileid');
		if (!is_scalar($fileId) || !ctype_digit((string)$fileId)) {
			return;
		}

		$user = $this->userSession->getUser();
		if ($user === null) {
			return;
		}

		$target = null;
		try {
			$target = $this->findEmailShareTarget($user->getUID(), (int)$fileId);
		} catch (\Exception $e) {
			// Never break the files app over this: without a target the user gets
			// exactly the behaviour they had before this middleware existed.
			// The exception class, not its message: DBAL formats bound parameters into
			// the message, and the only string bound here is the lowercased uid — the
			// user's email address, which these lines must not carry into Loki.
			$this->logger->warning(
				'Guest bridge: could not look up email shares for file {fileId}: {error}',
				['app' => 'guest_bridge', 'fileId' => $fileId, 'error' => get_class($e)]
			);
			return;
		}

		if ($target !== null) {
			throw new EmailShareRedirect($target);
		}
	}

	/**
	 * @param \OCP\AppFramework\Controller $controller
	 * @param string $methodName
	 * @param \Exception $exception
	 * @throws \Exception the passed exception when it is not ours to handle
	 */
	public function afterException($controller, $methodName, \Exception $exception): Response {
		if ($exception instanceof EmailShareRedirect) {
			return new RedirectResponse($exception->getTarget());
		}
		throw $exception;
	}

	/**
	 * The /s/<token> URL of an email share this user received for $fileId, or null
	 * when they have none, the file is already theirs to open, or the share no
	 * longer resolves.
	 */
	private function findEmailShareTarget(string $uid, int $fileId): ?string {
		// Whoever can open the file normally must keep the normal Files view.
		if ($this->rootFolder->getUserFolder($uid)->getFirstNodeById($fileId) !== null) {
			return null;
		}

		// A share of the file itself is tried first: it opens the file, where a share
		// of the folder holding it can only open that folder.
		$candidates = [];
		foreach ($this->directEmailShares($uid, $fileId) as $share) {
			$candidates[] = [$share['token'], true];
		}
		foreach ($this->folderEmailShares($uid) as $share) {
			// A folder share of this very file id is already covered above.
			if ((int)$share['file_source'] !== $fileId) {
				$candidates[] = [$share['token'], false];
			}
		}

		foreach ($candidates as [$token, $isDirect]) {
			$target = $isDirect
				? $this->resolveDirectShare($token)
				: $this->resolveFolderShare($token, $fileId);
			if ($target !== null) {
				// No uid in the message: under --mapping-uid=email it is the user's
				// email address, and these lines ship to Loki.
				$this->logger->info(
					'Guest bridge: redirecting a recipient of an email share to it, for file {fileId}',
					['app' => 'guest_bridge', 'fileId' => $fileId]
				);
				return $target;
			}
		}

		return null;
	}

	/**
	 * Email shares of this file addressed to this user, newest first, capped.
	 *
	 * file_source is indexed, so this only ever touches the shares of this one
	 * file. lower() is needed because share_with keeps whatever capitalisation the
	 * owner typed while Keycloak lowercases addresses; applying it after the
	 * file_source narrowing keeps it off the hot path.
	 */
	private function directEmailShares(string $uid, int $fileId): array {
		$qb = $this->db->getQueryBuilder();
		$qb->andWhere($qb->expr()->eq('file_source', $qb->createNamedParameter($fileId, IQueryBuilder::PARAM_INT)));

		return $this->runShareQuery($qb, $uid);
	}

	/**
	 * Email shares of a FOLDER addressed to this user, newest first, capped.
	 *
	 * A folder share does not name the file, so it cannot be narrowed by
	 * file_source; (item_type, share_type) is indexed instead, which limits this to
	 * folder email shares. The cap then bounds the work below, which a user could
	 * otherwise inflate by addressing many folder shares to their own address. It
	 * applies before containment is known, so a user holding more than the cap in
	 * folder email shares reaches files through the newest ones; beyond that they
	 * get the stock "not found" rather than a wrong answer.
	 *
	 * Whether the file really sits inside one of them is settled by
	 * resolveFolderShare(), which asks the share's own node — evaluated in the
	 * owner's context, the only place the answer is knowable — and then confirms
	 * the path is genuinely below the share root via getRelativePath().
	 */
	private function folderEmailShares(string $uid): array {
		$qb = $this->db->getQueryBuilder();
		$qb->andWhere($qb->expr()->eq('item_type', $qb->createNamedParameter('folder')));

		return $this->runShareQuery($qb, $uid);
	}

	/** Shared tail of both lookups: recipient match, ordering and the cap. */
	private function runShareQuery(IQueryBuilder $qb, string $uid): array {
		$qb->select('token', 'file_source')
			->from('share')
			->andWhere($qb->expr()->eq('share_type', $qb->createNamedParameter(IShare::TYPE_EMAIL, IQueryBuilder::PARAM_INT)))
			->andWhere($qb->expr()->eq(
				$qb->func()->lower('share_with'),
				$qb->createNamedParameter(mb_strtolower($uid))
			))
			->orderBy('id', 'DESC')
			->setMaxResults(self::MAX_CANDIDATE_SHARES);

		$result = $qb->executeQuery();
		$shares = $result->fetchAll();
		$result->closeCursor();

		return $shares;
	}

	/**
	 * Resolve a share of the file itself. Returns null when the token no longer
	 * opens — an expired share, for instance, which /s/<token> would refuse too.
	 */
	private function resolveDirectShare(string $token): ?string {
		try {
			$this->shareManager->getShareByToken($token);
		} catch (\Exception $e) {
			// Any candidate that will not resolve is simply skipped: another one
			// may still be the right answer, and a throw here would be reported as
			// a failed lookup even though the lookup itself worked.
			return null;
		}

		return $this->urlGenerator->linkToRoute('files_sharing.sharecontroller.showShare', ['token' => $token]);
	}

	/**
	 * Resolve a share of a folder that contains the file. The public share view
	 * takes a directory, not a file id, so this opens the folder the file sits in.
	 */
	private function resolveFolderShare(string $token, int $fileId): ?string {
		try {
			$share = $this->shareManager->getShareByToken($token);
			$folder = $share->getNode();
		} catch (\Exception $e) {
			// Skip, don't abort: getNode() sets up the owner's storage and can fail
			// for reasons that say nothing about the remaining candidates
			// (NotFound, NotPermitted, a storage that will not initialise).
			return null;
		}

		if (!($folder instanceof Folder)) {
			return null;
		}

		$node = $folder->getFirstNodeById($fileId);
		if ($node === null) {
			return null;
		}

		$path = $folder->getRelativePath($node->getPath());
		if ($path === null) {
			return null;
		}
		$dir = $node instanceof Folder ? $path : dirname($path);

		return $this->urlGenerator->linkToRoute(
			'files_sharing.sharecontroller.showShare',
			['token' => $token, 'dir' => $dir]
		);
	}
}
