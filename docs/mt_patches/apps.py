"""
Invitation-email link override for La Suite Docs (impress).

Why this exists
---------------
When a document is shared with an address that has no Docs account, impress
sends an invitation email whose link points at the document. Our users must
instead land on the account portal's ``/guest-landing`` page, which knows the
invitee's address and the document id and walks them through account creation:

    ${ACCOUNT_PORTAL_URL}/guest-landing?email=<invitee>&doc=<document id>

Upstream builds the email in ``Document.send_email`` and unconditionally
``context.update({... "link": <doc url>?utm_source=... ...})`` — so a link put
into the context by the caller (``send_invitation_email``) is overwritten. The
previous implementation text-patched ``core/models.py`` at container start and
failed OPEN when the source drifted (GitHub issue #606: the pod booted, the
email carried the plain document link, nothing failed).

How it works
------------
``ready()`` wraps two methods on ``core.models.Document``:

* ``send_invitation_email(self, email, role, sender, language=None)`` — records
  the invitee and the guest-landing link in a ContextVar for the duration of
  the call (thread- and task-safe; nothing on the instance is mutated).
* ``send_email(self, subject, emails, context=None, language=None)`` — when a
  pin is active AND the recipients are exactly the pinned invitee, replaces the
  context with a dict subclass that keeps ``link`` no matter what upstream's
  ``context.update`` / ``context["link"] = ...`` does afterwards.

Any other ``send_email`` call (e.g. ``DocumentAskForAccess``) sees no pin and is
untouched.

Fail closed
-----------
Everything is verified at process start, before the first request:

1. ``inspect.signature`` of both methods must match the exact upstream
   signature we were written against.
2. ``ACCOUNT_PORTAL_URL`` (env) and ``EMAIL_URL_APP`` (Django setting, env
   ``DJANGO_EMAIL_URL_APP``) must be set — without the latter upstream falls
   back to the ``django.contrib.sites`` domain, which nobody configures anymore.
3. A self-test drives the REAL, wrapped ``send_invitation_email`` on an unsaved
   ``Document`` with ``django.core.mail.send_mail`` captured (no SMTP, no DB)
   and asserts the rendered HTML and text both carry our link and no
   ``utm_source``. This is what guards the "upstream overwrites link via
   context.update" semantics: if upstream ever builds a fresh dict instead of
   mutating ours, or stops passing the context through, the self-test sees the
   document link and raises.

Any failure raises from ``AppConfig.ready()``; Django's app registry propagates
it, gunicorn's worker fails to boot, and the pod never becomes Ready. Exactly
one ``[mt_patches] ok`` line is logged per process on success.
"""

import contextvars
import inspect
import logging
import os
import urllib.parse
import uuid
from types import SimpleNamespace
from unittest import mock

from django.apps import AppConfig
from django.conf import settings
from django.core.exceptions import ImproperlyConfigured
from django.test.utils import override_settings
from django.utils.html import escape

logger = logging.getLogger("mt_patches")

# The exact upstream signatures this module was written against
# (core/models.py, lasuite/impress-backend v5.6.1). Compared verbatim.
EXPECTED_SEND_INVITATION_SIGNATURE = "(self, email, role, sender, language=None)"
EXPECTED_SEND_EMAIL_SIGNATURE = "(self, subject, emails, context=None, language=None)"

# (invitee email, guest-landing link) while send_invitation_email is on the stack.
_pinned: contextvars.ContextVar = contextvars.ContextVar("mt_patches_pinned_link", default=None)


class PatchError(RuntimeError):
    """Raised when upstream no longer looks like what this patch expects."""


def guest_landing_link(account_portal_url, email, document_id):
    """Build the account-portal guest-landing URL for an invitee."""
    return (
        f"{account_portal_url}/guest-landing"
        f"?email={urllib.parse.quote(email)}&doc={document_id}"
    )


class PinnedLinkContext(dict):
    """A dict whose ``link`` key cannot be changed once set.

    Upstream's ``send_email`` calls ``context.update({...,"link": ...})``; this
    keeps our value through ``update``, item assignment, ``setdefault`` and
    ``|=``. Deleting the key is refused too, so a later refactor cannot
    quietly drop it and re-add the upstream link.
    """

    __slots__ = ("_pinned_link",)

    def __init__(self, base, link):
        super().__init__(base or {})
        self._pinned_link = link
        super().__setitem__("link", link)

    def __setitem__(self, key, value):
        if key == "link":
            value = self._pinned_link
        super().__setitem__(key, value)

    def update(self, *args, **kwargs):
        incoming = dict(*args, **kwargs)
        incoming.pop("link", None)
        super().update(incoming)

    def setdefault(self, key, default=None):
        if key == "link":
            return self._pinned_link
        return super().setdefault(key, default)

    def __ior__(self, other):
        self.update(other)
        return self

    def __delitem__(self, key):
        if key == "link":
            raise PatchError("refusing to delete the pinned invitation link")
        super().__delitem__(key)

    def pop(self, key, *default):
        if key == "link":
            raise PatchError("refusing to pop the pinned invitation link")
        return super().pop(key, *default)


def _mask_email(value):
    """'alice@example.com' -> 'a***@example.com'; never returns the local part."""
    value = str(value)
    local, sep, domain = value.partition("@")
    return f"{local[:1]}***@{domain}" if sep else f"{local[:1]}***"


def _check_signature(func, expected, label):
    actual = str(inspect.signature(func))
    if actual != expected:
        raise PatchError(
            f"core.models.Document.{label} signature changed: expected "
            f"{expected!r}, found {actual!r}. Re-verify mt_patches against the "
            "new upstream source before deploying this image."
        )


def _required_config():
    account_portal_url = os.environ.get("ACCOUNT_PORTAL_URL", "").strip().rstrip("/")
    if not account_portal_url:
        raise ImproperlyConfigured(
            "[mt_patches] ACCOUNT_PORTAL_URL is not set (docs-config ConfigMap); "
            "invitation emails cannot be routed to the account portal"
        )
    if not getattr(settings, "EMAIL_URL_APP", None):
        raise ImproperlyConfigured(
            "[mt_patches] EMAIL_URL_APP is not set (env DJANGO_EMAIL_URL_APP in "
            "docs-config); upstream would fall back to the django.contrib.sites "
            "domain, which is no longer maintained"
        )
    return account_portal_url


def install(document_cls, account_portal_url):
    """Wrap Document.send_invitation_email / Document.send_email in place."""
    if getattr(document_cls, "_mt_patches_installed", False):
        raise PatchError("mt_patches.install() called twice on the same Document class")

    original_send_invitation_email = document_cls.send_invitation_email
    original_send_email = document_cls.send_email
    _check_signature(
        original_send_invitation_email,
        EXPECTED_SEND_INVITATION_SIGNATURE,
        "send_invitation_email",
    )
    _check_signature(original_send_email, EXPECTED_SEND_EMAIL_SIGNATURE, "send_email")

    def send_invitation_email(self, email, role, sender, language=None):
        link = guest_landing_link(account_portal_url, email, self.id)
        token = _pinned.set((email, link))
        try:
            return original_send_invitation_email(self, email, role, sender, language)
        finally:
            _pinned.reset(token)

    def send_email(self, subject, emails, context=None, language=None):
        pin = _pinned.get()
        if pin is not None:
            invitee, link = pin
            if list(emails) != [invitee]:
                # send_invitation_email started emailing someone other than the
                # invitee while our pin was active: upstream semantics changed.
                # Addresses are masked; this message can land in pod logs.
                raise PatchError(
                    "send_email recipients while an invitation pin is active: "
                    f"{len(list(emails))} recipient(s) "
                    f"{[_mask_email(e) for e in emails]}, expected exactly "
                    f"[{_mask_email(invitee)!r}]"
                )
            context = PinnedLinkContext(context, link)
        return original_send_email(self, subject, emails, context, language)

    send_invitation_email.__wrapped__ = original_send_invitation_email
    send_email.__wrapped__ = original_send_email
    document_cls.send_invitation_email = send_invitation_email
    document_cls.send_email = send_email
    document_cls._mt_patches_installed = True


def self_test(document_cls, account_portal_url):
    """Send one invitation through the real code path with send_mail captured.

    No database access: the Document is never saved, EMAIL_URL_APP short-circuits
    the Site lookup, and send_mail is replaced before anything reaches SMTP. As a
    belt-and-braces guard the email backend is switched to locmem for the
    duration of the test, so a missed mock lands in django.core.mail.outbox
    (checked empty afterwards) instead of on the wire.
    """
    from django.core import mail as django_mail  # pylint: disable=import-outside-toplevel
    from core import models as core_models  # pylint: disable=import-outside-toplevel

    captured = []

    def capture_send_mail(subject, message, from_email, recipient_list, **kwargs):
        captured.append(
            {
                "subject": subject,
                "text": message,
                "from": from_email,
                "to": list(recipient_list),
                "html": kwargs.get("html_message"),
            }
        )

    document = document_cls(id=uuid.uuid4(), title="mt_patches self-test")
    sender = SimpleNamespace(full_name="mt_patches self-test", email="selftest@example.invalid")
    invitee = "invitee+selftest@example.invalid"
    expected_link = guest_landing_link(account_portal_url, invitee, document.id)

    with override_settings(EMAIL_BACKEND="django.core.mail.backends.locmem.EmailBackend"):
        django_mail.outbox = []
        with mock.patch.object(core_models, "send_mail", capture_send_mail):
            document.send_invitation_email(invitee, "editor", sender, "en-us")
        leaked = len(django_mail.outbox)
        django_mail.outbox = []
    if leaked:
        raise PatchError(
            f"self-test: {leaked} message(s) reached the Django email backend; "
            "core.models.send_mail was not intercepted (nothing was sent: the "
            "backend was locmem for the test)"
        )

    if len(captured) != 1:
        raise PatchError(f"self-test expected exactly one email, got {len(captured)}")
    mail = captured[0]
    if mail["to"] != [invitee]:
        raise PatchError(f"self-test email went to {mail['to']!r}, expected [{invitee!r}]")
    # Upstream renders both templates through the Django engine with autoescape
    # on, so "&doc=" arrives as "&amp;doc=" in the HTML AND the text part (the
    # e2e spec un-escapes it the same way). Accept either form.
    accepted = (expected_link, escape(expected_link))
    for part in ("html", "text"):
        body = mail[part] or ""
        if not any(form in body for form in accepted):
            raise PatchError(
                f"self-test: the {part} body does not contain the guest-landing link "
                f"{expected_link!r}; upstream no longer honours the pinned context "
                "(check Document.send_email's context handling)"
            )
        if "utm_source" in body:
            raise PatchError(
                f"self-test: the {part} body still contains upstream's utm_source "
                "document link; the pin did not take"
            )
    # The pin must not leak past the invitation call.
    if _pinned.get() is not None:
        raise PatchError("self-test: invitation pin leaked after the call")


class MtPatchesConfig(AppConfig):
    """Installs and self-tests the invitation-link override at process start."""

    name = "mt_patches"
    verbose_name = "mothertree patches"

    def ready(self):
        from core.models import Document  # pylint: disable=import-outside-toplevel

        account_portal_url = _required_config()
        install(Document, account_portal_url)
        self_test(Document, account_portal_url)
        logger.info("[mt_patches] ok — invitation links routed to %s/guest-landing", account_portal_url)
