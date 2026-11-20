# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

A single web application (`apps/web`) for desktop and mobile. It can be installed on Android and
iPhone and supports offline work in the field. The mobile experience runs on the web rather than
in a native application.

## Users

Jobly gives **office and field staff equal priority**. It serves businesses from a sole operator
who quotes, completes work and invoices clients to a larger company with an office team and
multiple crews. Each screen is designed for the person doing the work.

- **Office teams:** owners and general, office and operations managers handle requests, quotes,
  scheduling, invoicing, pay, marketing and reporting. Most work at a desk; owners also manage the
  business from their phones.
- **Field teams:** foremen and crew members use a phone at the property to view their day,
  directions and gate codes, complete checklists, capture photos, record materials and track time.
  Foremen manage their crews without access to prices.
- **Subcontractors:** sign in with a link or code, without a password, and access only their own
  jobs, agreed prices and paperwork.
- **Clients:** use the Client Hub without creating an account to approve quotes, make payments,
  view visits, request work and message the office. Prospective clients can submit booking forms
  on the business's own website.
- **People setting up Jobly:** typically business owners without a developer, deploying on
  Railway or hosting an instance themselves with Docker.

## Product Purpose

Jobly is free, open-source field service software for businesses that quote work, schedule crews,
serve clients at their properties and collect payment. It supports lawn care, paving, roofing,
cleaning, HVAC, snow removal and other service trades.

Requests, quotes, scheduling, field work, invoicing and a client portal come together in one
application the business owns. Success means a business can run its operation from the first
inquiry to a paid invoice on infrastructure it controls.

## Positioning

**You own it.** Ownership is the primary message whenever Jobly explains its value. Each business
runs an independent instance with its own application, database and files in accounts it owns
and controls. There is no subscription per seat, and the source code is available under
AGPL-3.0-only, with the additional terms in `NOTICE`. Jobly's creator does not host or operate
these instances or have access to their contents.

Supporting messages, in order of priority:

1. A complete workflow for the office and field, from requests and quotes to scheduling and
   payment, positioned as an alternative to Jobber.
2. Tools beyond the core workflow: an SOP knowledge base, equipment maintenance, satellite map
   measurements, plan sets aligned to maps, paving takeoffs and roofing packages.
3. Connections to services businesses already use, including QuickBooks, Zoho, Claude and ChatGPT.

## Operating Context

- **Office work:** extended browser sessions for scheduling, the sales board, finance and
  settings. Owners also check Home on a phone between jobs.
- **Field work:** phones used outdoors or in a truck cab, often with limited or no connectivity.
  Work is saved on the device and sent when connectivity returns. Controls must support use with
  a thumb or a glove.
- **Client interactions:** occasional visits through a link in a text or email, usually on a
  phone, without an account or training.
- **Business workflow:** request → quote → job → visits → invoice → payment. Use the product's
  established terms consistently: request, quote, job, visit, invoice, Client Hub, My day, the
  office, the crew and Apps, including built-in and connected apps.
- **Deployment and services:** the business pays its hosting provider directly, whether Railway
  or its own server provider. It supplies its own accounts and credentials for email through
  Resend or its mailbox, texting through Twilio, payments through Stripe, maps and AI.

## Capabilities and Constraints

- Default roles include General manager, Office manager, Operations manager, Foreman and
  Employee. Businesses can rename these roles, create custom roles and provide a separate
  Subcontractor sign-in. Access rules are enforced in the database as well as the interface.
- Built-in apps include Marketing, Drive, Team Chat, Careers, Paving, Roofing and Snow. They can
  be installed or uninstalled. Uninstalling hides the relevant tab and stops outgoing activity
  without deleting its data.
- Both light and dark modes are supported.
- Each instance is independent. Features that depend on external accounts, including texting,
  payments, AI, Google and Meta, require the business to connect its own services.

## Brand Commitments

- **Identity:** the Jobly name and geometric J mark use the established navy and amber palette.
  Brand assets live in `docs/brand/`, including the light and dark SVG and PNG wordmarks,
  `jobly-logo-tile.png`, `jobly-mark.svg` and `jobly-mark-512.png`. Application icons live in
  `apps/web/public/`. Use of the name and marks is governed by `NOTICE`; modified versions may
  not use them to name, promote or sell themselves, except to identify their origin truthfully.
- **Voice:** use everyday language, short sentences, direct address and concrete outcomes across
  the README, documentation and interface. Explain what happened and what to do next: "Saved on
  this phone. It sends when you have signal." State what failed and why. Refer to people as the
  office, the crew and clients, using the terms that fit their work.

## Evidence on Hand

- **Product screenshots:** `docs/images/` contains real application screens with demo data,
  including office views in light and dark modes and phone views of My day, a visit, Home and
  the Client Hub.
- **Demo environment:** `npm run seed:demo` loads sample data; `npm run screenshots` captures
  the documentation screenshots.
- **Website:** `jobly.com` contains a 24-second tour, comparisons and documentation for business
  owners. Its source lives outside this repository.
- **Customer evidence:** no customer proof is available for use. Do not name or quote businesses
  running Jobly or cite their figures. Do not invent testimonials, customers, ratings, usage
  statistics or press coverage.

## Product Principles

1. **Put ownership first.** The business controls its instance, data, files and keys. Jobly's
   creator does not host the instance or have access to its contents.
2. **Serve the office and field equally.** Design for the setting in which work happens, from a
   desktop browser to a phone with poor connectivity.
3. **Make outcomes clear.** Explain successes, partial failures and next steps in the business's
   own language. People should never have to guess what happened.
4. **Protect work and prevent surprises.** Preserve work when connectivity drops and retain data
   when an app is uninstalled. Explain irreversible actions and changes to client charges before
   they happen.
5. **Keep client access simple.** Approving a quote, making a payment or booking work should not
   require an account, an app installation or training.

## Accessibility & Inclusion

- Follow WCAG 2.1 Level A and AA requirements. Check each main screen with axe-core
  (`e2e/accessibility.spec.ts`).
- Route field interface text through `t()` and write it so it translates clearly
  (`packages/core/src/i18n/es/`).
- Design field screens for outdoor phone use, operation with a thumb or a glove, and work
  without connectivity.
