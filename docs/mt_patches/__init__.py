"""
mothertree runtime patches for La Suite Docs (impress).

A Django app (see apps.py) whose only job is to redirect document-invitation
emails through the account portal's guest-landing page. Added to INSTALLED_APPS
by mt_settings.py; mounted read-only at /app/mt_patches (ConfigMap docs-mt-python).
"""
