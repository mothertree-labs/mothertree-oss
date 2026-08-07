# Mothertree — Project Brief (Business & Product)

*Background for marketing and sales work. One page, non-technical.*

## What Mothertree is

Mothertree is a **privacy-first, open-source alternative to Google Workspace / Microsoft 365 / Slack + Zoom**. Each customer organization gets its own private, branded collaboration suite — chat, collaborative documents, file storage, video conferencing, and email — running under its own domain, with all of its data isolated from every other customer.

Rather than building these tools from scratch, Mothertree integrates best-in-class open-source software (Matrix/Element for chat, Docs for real-time document editing, Nextcloud for files, Jitsi for video, Stalwart + Roundcube for email) into one coherent product: single sign-on across everything, one account per user, automated setup, and professional operations (monitoring, backups, deliverable email) handled by the Mothertree team.

## The problem it solves

Organizations that care about data privacy and independence face a bad trade-off today: hand their data to Big Tech SaaS, or try to self-host a dozen separate open-source tools — which requires a full-time IT team and still leaves hard problems (email deliverability, single sign-on, uptime) unsolved. Mothertree packages all of that operational complexity into a managed platform, so "owning your own collaboration stack" becomes practical for organizations without deep IT resources.

## Who it's for

Mission-driven organizations: **nonprofits, philanthropic funders and funder networks, advocacy groups, and values-aligned communities** — especially those with:

- **Data-sovereignty or privacy requirements** (their data should not live inside surveillance-capitalism platforms)
- **Jurisdictional needs** — Mothertree runs separate US and EU hosting regions, so a European organization's data can physically stay in the EU
- **Values alignment** — being open source (AGPL-licensed, publicly auditable code) is itself a buying criterion for this audience
- A desire for a **branded, all-in-one digital home** (everything on `their-org.org` domains) without hiring IT staff

## The product, from a user's perspective

One login (with passkey support) opens the whole suite on the organization's own domain:

| Capability | What the user gets |
|---|---|
| Chat | Team messaging and rooms (Matrix, via the Element web app) |
| Docs | Real-time collaborative document editing |
| Files | File storage, sync, and sharing (Nextcloud) |
| Video | Video conferencing with no third-party account (Jitsi) |
| Email | Full email hosting on the org's domain, plus webmail |
| Self-service | An account portal for users and an admin portal for org administrators |

## Key differentiators

1. **True isolation, not a UI partition** — each organization gets its own identity realm, databases, and storage; separation is architectural.
2. **Open source all the way down** — no proprietary lock-in; an organization could, in principle, take the code and run it themselves. This builds trust that no closed vendor can match.
3. **Email done properly** — full custom-domain email with real deliverability (SPF/DKIM/DMARC, reputable outbound relay). This is the hardest part of leaving Google/Microsoft, and most alternatives skip it.
4. **Multi-region by design** — US and EU production environments let customers choose where their data lives.
5. **Fast, low-touch onboarding** — new organizations are provisioned through automation, not bespoke projects, which keeps per-customer cost low and makes the model economically viable.

## Business model & status

Operator-managed SaaS on open foundations: the platform code is public (AGPL, `mothertree-oss` on GitHub), while each deployment's private configuration stays with the operator. The Mothertree team runs the infrastructure and onboards tenants. The platform is **live in production** in both US and EU regions, serving real organizations (including philanthropy/funder-network tenants), with continuous automated testing and deployment behind every release.

**One-liner:** *Mothertree gives mission-driven organizations their own private, branded Google-Workspace-style suite — chat, docs, files, video, and email — built entirely on open source, with their data in their jurisdiction and under their control.*
