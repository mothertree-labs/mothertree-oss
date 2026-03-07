const nodemailer = require('nodemailer');

// In-cluster SMTP (Postfix uses self-signed certs). Do NOT point SMTP_HOST
// at an external server without also setting SMTP_TLS_REJECT_UNAUTHORIZED=true.
const transporter = nodemailer.createTransport({
  host: process.env.SMTP_HOST || 'postfix-internal.infra-mail.svc.cluster.local',
  port: parseInt(process.env.SMTP_PORT || '587', 10),
  secure: false,
  tls: { rejectUnauthorized: process.env.SMTP_TLS_REJECT_UNAUTHORIZED === 'true' },
});

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function sanitizeForSubject(str) {
  return String(str).replace(/[\r\n]/g, ' ');
}

async function sendShareInviteEmail({ to, sharerName, documentName, guestLandingUrl, brandName }) {
  const safeName = sanitizeForSubject(sharerName);
  const safeDoc = sanitizeForSubject(documentName);
  const subject = `${safeName} shared "${safeDoc}" with you`;

  const eName = escapeHtml(sharerName);
  const eDoc = escapeHtml(documentName);
  const eBrand = escapeHtml(brandName || 'Mothertree');
  const eUrl = escapeHtml(guestLandingUrl);

  const html = `
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h2 style="color: #1a1a1a; margin-bottom: 5px;">${eBrand}</h2>
  </div>
  <p style="font-size: 16px; line-height: 1.5;">
    <strong>${eName}</strong> shared a file with you:
  </p>
  <div style="background: #f5f5f5; border-radius: 8px; padding: 16px; margin: 20px 0;">
    <p style="margin: 0; font-size: 15px;"><strong>${eDoc}</strong></p>
  </div>
  <p style="font-size: 15px; line-height: 1.5;">
    To view this file, you'll need to set up a free account. It only takes a moment.
  </p>
  <div style="text-align: center; margin: 30px 0;">
    <a href="${eUrl}" style="display: inline-block; background: #0070f3; color: white; text-decoration: none; padding: 12px 32px; border-radius: 6px; font-size: 16px; font-weight: 500;">
      View File
    </a>
  </div>
  <p style="font-size: 13px; color: #666; margin-top: 30px;">
    If you weren't expecting this email, you can safely ignore it.
  </p>
</body>
</html>`;

  const text = `${sharerName} shared "${documentName}" with you.\n\nTo view this file, set up your account: ${guestLandingUrl}\n\nIf you weren't expecting this email, you can safely ignore it.`;

  const fromDomain = process.env.EMAIL_DOMAIN || process.env.TENANT_DOMAIN || 'example.com';

  await transporter.sendMail({
    from: `"${eBrand}" <noreply@${fromDomain}>`,
    to,
    subject,
    html,
    text,
  });
}

module.exports = { sendShareInviteEmail };
