"""
mothertree settings for La Suite Docs (impress).

Loaded with DJANGO_SETTINGS_MODULE=mt_settings and DJANGO_CONFIGURATION=Production.
impress uses django-configurations: the settings module must expose a class named
by DJANGO_CONFIGURATION, and that class's upper-case attributes become the Django
settings. This module subclasses upstream's ``Production`` and overrides exactly
three attributes. It replaces the start-time regex rewrite of
``/app/impress/settings.py`` that the backend container used to run.

Mounted read-only at /app/mt_settings.py (ConfigMap ``docs-mt-python``); /app is
the image's working directory and is on sys.path, so a bare ``mt_settings`` import
resolves.

Every override below fails closed: if upstream renames a key or changes the shape
of a setting we build on, the import raises and the pod does not start.
"""

import impress.settings as _upstream

_MEDIA_MIDDLEWARE = "impress.middleware.MediaMiddleware"
_STORAGE_BACKEND = "storage_backends.LinodeS3Boto3Storage"
_PATCH_APP = "mt_patches"

# Shape checks on what we build on. A KeyError/AssertionError here is deliberate:
# it means upstream moved something and this override needs a human look.
_upstream_default_storage = _upstream.Production.STORAGES["default"]
if not isinstance(_upstream_default_storage.get("BACKEND"), str):
    raise RuntimeError(
        "[mt_settings] upstream STORAGES['default']['BACKEND'] is not a plain "
        f"string ({_upstream_default_storage!r}); refusing to override blindly"
    )
if _MEDIA_MIDDLEWARE in _upstream.Production.MIDDLEWARE:
    raise RuntimeError(
        f"[mt_settings] {_MEDIA_MIDDLEWARE} is already in upstream MIDDLEWARE; "
        "the mounted middleware.py would shadow an upstream module"
    )
if _PATCH_APP in _upstream.Production.INSTALLED_APPS:
    raise RuntimeError(
        f"[mt_settings] {_PATCH_APP} is already in upstream INSTALLED_APPS"
    )


class Production(_upstream.Production):
    """Upstream Production plus the three mothertree customizations."""

    # MediaMiddleware (ConfigMap storage-backends/middleware.py, mounted at
    # /app/impress/middleware.py) turns /media/<key> into a presigned Linode
    # Object Storage redirect. It must run before anything that could answer
    # a /media/ request, so it goes first.
    MIDDLEWARE = [_MEDIA_MIDDLEWARE, *_upstream.Production.MIDDLEWARE]

    # Presigned-URL storage backend (ConfigMap storage-backends/storage_backends.py,
    # mounted at /app/storage_backends.py). Only the default alias changes; the
    # staticfiles and SILKY_STORAGE aliases are inherited untouched.
    STORAGES = {
        **_upstream.Production.STORAGES,
        "default": {**_upstream_default_storage, "BACKEND": _STORAGE_BACKEND},
    }

    # mt_patches.apps.MtPatchesConfig.ready() installs the invitation-email
    # link override and self-tests it. Last so every upstream app is loaded
    # before it runs.
    INSTALLED_APPS = [*_upstream.Production.INSTALLED_APPS, _PATCH_APP]
