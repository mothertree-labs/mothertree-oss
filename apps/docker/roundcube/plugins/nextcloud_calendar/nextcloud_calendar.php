<?php

/**
 * Roundcube plugin: nextcloud_calendar
 *
 * Adds a "Calendar" button to the sidebar that opens the Nextcloud
 * Calendar app in a new tab, replacing the built-in Kolab calendar view.
 *
 * Config: $config['nextcloud_calendar_url'] = 'https://files.example.com/apps/calendar';
 */
class nextcloud_calendar extends rcube_plugin
{
    public $task = '?(?!login|logout).*';

    public function init()
    {
        $this->add_texts('localization/', false);
        $this->register_task('calendar');
        $this->add_hook('startup', [$this, 'on_startup']);
        $this->include_script('nextcloud_calendar.js');

        // Add the calendar button to the taskbar (sidebar navigation)
        $this->add_button(
            [
                'command'    => 'calendar',
                'class'      => 'button-calendar',
                'classsel'   => 'button-calendar button-selected',
                'innerclass' => 'button-inner',
                'label'      => 'nextcloud_calendar.calendar',
                'type'       => 'link',
            ],
            'taskbar'
        );

        $rcmail = rcmail::get_instance();
        $url = $rcmail->config->get('nextcloud_calendar_url', '');
        if ($url) {
            $rcmail->output->set_env('nextcloud_calendar_url', $url);
        }
    }

    /**
     * Server-side redirect for direct navigation to ?_task=calendar.
     */
    public function on_startup($args)
    {
        if ($args['task'] === 'calendar') {
            $rcmail = rcmail::get_instance();
            $url = $rcmail->config->get('nextcloud_calendar_url', '');
            if ($url) {
                header('Location: ' . $url);
                exit;
            }
        }

        return $args;
    }
}
