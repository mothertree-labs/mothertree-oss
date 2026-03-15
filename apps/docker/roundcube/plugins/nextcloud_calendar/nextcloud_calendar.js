/**
 * Override calendar button to open Nextcloud Calendar in a new tab.
 */
if (window.rcmail) {
    rcmail.addEventListener('init', function() {
        var url = rcmail.env.nextcloud_calendar_url;
        if (!url) return;

        var btn = document.querySelector('#taskmenu a.button-calendar');
        if (!btn) return;

        btn.href = url;
        btn.target = '_blank';
        btn.rel = 'noopener';

        // Capture-phase listener fires before Roundcube's own handlers
        btn.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopImmediatePropagation();
            window.open(url, '_blank', 'noopener');
        }, true);
    });
}
