<?php

/**
 * Roundcube plugin: oauth_name
 *
 * Populates the user identity display name from the OAuth/OIDC
 * provider's "name" claim. Without this, Roundcube creates identities
 * with an empty name, so outbound emails show a bare email address
 * in the From header instead of "Display Name <email>".
 *
 * Handles both new users (via user_create hook) and existing users
 * whose identity name is empty (via login_after hook).
 */
class oauth_name extends rcube_plugin
{
    private $oauth_identity = null;

    public function init()
    {
        $this->add_hook('oauth_login', [$this, 'on_oauth_login']);
        $this->add_hook('user_create', [$this, 'on_user_create']);
        $this->add_hook('login_after', [$this, 'on_login_after']);
    }

    /**
     * Capture identity claims from the OAuth provider (fired before login).
     */
    public function on_oauth_login($args)
    {
        if (!empty($args['identity'])) {
            $this->oauth_identity = $args['identity'];
        }

        return $args;
    }

    /**
     * Set display name for new users from the OAuth "name" claim.
     */
    public function on_user_create($args)
    {
        if ($this->oauth_identity && !empty($this->oauth_identity['name'])) {
            $args['user_name'] = $this->oauth_identity['name'];
        }

        return $args;
    }

    /**
     * Update existing identity name if empty (backfill for users created
     * before this plugin was installed).
     */
    public function on_login_after($args)
    {
        if (!$this->oauth_identity || empty($this->oauth_identity['name'])) {
            return $args;
        }

        $rcmail = rcmail::get_instance();
        $user = $rcmail->user;

        if (!$user) {
            return $args;
        }

        $identity = $user->get_identity();

        if ($identity && empty($identity['name'])) {
            $user->update_identity($identity['identity_id'], [
                'name' => $this->oauth_identity['name'],
            ]);
        }

        return $args;
    }
}
