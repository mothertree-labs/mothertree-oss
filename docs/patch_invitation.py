import os
import re

models_path = "/app/core/models.py"

with open(models_path, "r") as f:
    content = f.read()

# Check if already patched
if "ADMIN_PORTAL_URL" in content:
    print("[invitation-patch] Already patched")
else:
    # 1. In send_email: change context.update({...}) to use defaults that caller context can override
    old_pattern = '        context.update(\n            {\n                "brandname": settings.EMAIL_BRAND_NAME,\n                "document": self,\n                "domain": domain,\n                "link": f"{domain}/docs/{self.id}/",\n                "document_title": self.title or str(_("Untitled Document")),\n                "logo_img": settings.EMAIL_LOGO_IMG,\n            }\n        )'

    new_pattern = '        defaults = {\n                "brandname": settings.EMAIL_BRAND_NAME,\n                "document": self,\n                "domain": domain,\n                "link": f"{domain}/docs/{self.id}/",\n                "document_title": self.title or str(_("Untitled Document")),\n                "logo_img": settings.EMAIL_LOGO_IMG,\n            }\n        defaults.update(context)\n        context = defaults'

    if old_pattern in content:
        content = content.replace(old_pattern, new_pattern)
        print("[invitation-patch] Patched send_email to allow context override")
    else:
        print("[invitation-patch] WARNING: Could not find send_email pattern to patch")

    # 2. In send_invitation_email: add admin portal link to context before calling send_email
    old_send_call = "        self.send_email(subject, [email], context, language)"

    new_send_call = """        # Redirect invitation link through admin portal guest landing
        _admin_url = os.environ.get("ADMIN_PORTAL_URL", "")
        if _admin_url:
            import urllib.parse
            context["link"] = f"{_admin_url}/guest-landing?email={urllib.parse.quote(email)}&doc={self.id}"
        self.send_email(subject, [email], context, language)"""

    if old_send_call in content:
        # Only replace the first occurrence (in send_invitation_email)
        content = content.replace(old_send_call, new_send_call, 1)
        print("[invitation-patch] Patched send_invitation_email to use admin portal link")
    else:
        print("[invitation-patch] WARNING: Could not patch send_invitation_email")

    # Ensure import os is present
    if "\nimport os\n" not in content and not content.startswith("import os\n"):
        content = "import os\n" + content

    with open(models_path, "w") as f:
        f.write(content)

    print("[invitation-patch] Done")
