(function() {
	'use strict';

	// Only activate on Calendar pages
	if (!window.location.pathname.includes('/apps/calendar')) {
		return;
	}

	function getJitsiHost() {
		try {
			var stateEl = document.querySelector('#initial-state-jitsi_calendar-jitsi_host');
			if (stateEl && stateEl.value) {
				var host = JSON.parse(atob(stateEl.value));
				if (host) return host;
			}
		} catch (e) {}

		var hostname = window.location.hostname;
		var parts = hostname.split('.');
		if (parts.length >= 3) {
			parts[0] = 'jitsi';
			return 'https://' + parts.join('.');
		}
		return null;
	}

	function generateRandomId(len) {
		var c = 'abcdefghijklmnopqrstuvwxyz0123456789', r = '';
		for (var i = 0; i < len; i++) r += c.charAt(Math.floor(Math.random() * c.length));
		return r;
	}

	function sanitizeForUrl(text) {
		if (!text) return '';
		return text.toLowerCase()
			.replace(/[^a-z0-9\s-]/g, '')
			.replace(/\s+/g, '-')
			.replace(/-+/g, '-')
			.replace(/^-|-$/g, '');
	}

	function setNativeValue(el, value) {
		var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
		Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
		el.dispatchEvent(new Event('input', { bubbles: true }));
		el.dispatchEvent(new Event('change', { bubbles: true }));
	}

	function hasJitsiLink(value) {
		var host = getJitsiHost();
		if (!host) return false;
		return value.indexOf(host.replace(/^https?:\/\//, '')) !== -1;
	}

	function findLocationInput() {
		// Primary: Nextcloud Calendar's .property-location class
		var loc = document.querySelector('.property-location');
		if (loc) {
			var input = loc.querySelector('input') || loc.querySelector('textarea');
			if (input) return { input: input, container: loc };
		}
		// Fallback: any .property-text with a location-related placeholder
		var rows = document.querySelectorAll('.property-text');
		for (var i = 0; i < rows.length; i++) {
			var inp = rows[i].querySelector('input, textarea');
			if (inp) {
				var ph = (inp.placeholder || '').toLowerCase();
				if (ph.includes('locat') || ph.includes('ort') || ph.includes('lieu')) {
					return { input: inp, container: rows[i] };
				}
			}
		}
		return null;
	}

	function findTitleInput() {
		return document.querySelector('.property-title__input input') ||
			document.querySelector('.property-title input') ||
			document.querySelector('.property-title-time-picker input[type="text"]') ||
			document.querySelector('.app-sidebar-header__mainname-input');
	}

	function injectButton() {
		var found = findLocationInput();
		if (!found) return;

		var locationInput = found.input;
		var container = found.container;

		// Already injected for this container?
		var existing = container.parentNode.querySelector('.jitsi-meeting-btn');
		if (existing) return;

		var btn = createBtn();
		if (hasJitsiLink(locationInput.value || '')) {
			btn.style.display = 'none';
		}

		btn.addEventListener('click', function(e) {
			e.preventDefault();
			e.stopPropagation();

			var jitsiHost = getJitsiHost();
			if (!jitsiHost) return;
			if (!jitsiHost.startsWith('http')) jitsiHost = 'https://' + jitsiHost;

			var titleEl = findTitleInput();
			var title = titleEl ? titleEl.value : '';
			var sanitized = sanitizeForUrl(title);
			var roomName = (sanitized || 'meeting') + '-' + generateRandomId(8);
			var url = jitsiHost + '/' + roomName;

			var cur = (locationInput.value || '').trim();
			setNativeValue(locationInput, cur ? url + ' - ' + cur : url);
			btn.style.display = 'none';
		});

		// Re-show button if user removes the link by typing
		locationInput.addEventListener('input', function() {
			btn.style.display = hasJitsiLink(locationInput.value || '') ? 'none' : '';
		});

		container.parentNode.insertBefore(btn, container.nextSibling);
	}

	function createBtn() {
		var btn = document.createElement('button');
		btn.type = 'button';
		btn.className = 'jitsi-meeting-btn';
		btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
			'<polygon points="23 7 16 12 23 17 23 7"/>' +
			'<rect x="1" y="5" width="15" height="14" rx="2" ry="2"/>' +
			'</svg> Add Jitsi Meeting';
		return btn;
	}

	// Poll for button visibility (catches Vue reactivity clearing the field)
	setInterval(function() {
		var btn = document.querySelector('.jitsi-meeting-btn');
		if (!btn) return;
		var found = findLocationInput();
		if (!found) return;
		btn.style.display = hasJitsiLink(found.input.value || '') ? 'none' : '';
	}, 1000);

	// Watch for sidebar opening (location field appearing)
	var observer = new MutationObserver(function() {
		if (observer._t) clearTimeout(observer._t);
		observer._t = setTimeout(injectButton, 300);
	});

	function init() {
		observer.observe(document.getElementById('content') || document.getElementById('content-vue') || document.body, {
			childList: true,
			subtree: true
		});
		injectButton();
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
