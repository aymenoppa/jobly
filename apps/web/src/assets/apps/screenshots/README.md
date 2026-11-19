Screenshots on the Apps pages, like an app store listing's (features/apps/screenshots.ts). Each has a
light and a dark copy, shown with the app's theme.

The website analytics ones are Marketing's Website tab (features/marketing/WebsiteSection.tsx) with
made-up visits to a lawn care business's website over 30 days, rendered at 1440×900 in light and
dark with Playwright and saved as WebP by Chromium.

The team chat ones are the real chat screen (features/chat/ChatPage.tsx) with made-up people and
messages for a lawn care business, rendered at 1440×900 and saved as WebP. To retake them after the
chat screen changes, render it with sample data and screenshot it with Playwright in both themes.

The Sveltia CMS ones are the real Sveltia CMS (0.248.1) with its test backend, seeded with a made-up
lawn care business's website (Green Valley Lawn Care: blog posts, services, pages, hours), rendered
at 1440×900 in light and dark with Playwright and saved as WebP by Chromium.

The ABC Supply ones are the real Roofing → Catalog with a made-up roofing business (Summit Roofing)
whose ABC Supply connection answered from a local stand-in for ABC's API: a made-up catalog of
shingles, underlayment and trim in ABC's documented shapes, at made-up prices, with no pictures
(so the colors are drawn as swatches). Rendered at 1440×900 in light and dark with Playwright and
saved as WebP by Chromium.

The fal.ai ones are the real measuring map and Paving project page, with a demo paving business's
takeoff of a parking lot in Oakridge, VA on Virginia's state imagery (VGIN), taken from a local
instance with Playwright at 1440×900 in both themes and saved as WebP from Chromium's canvas.

The Snow ones are the real Snow page (features/snow) for a made-up snow contractor in Anchorage
(Northern Lights Snow & Lawn: six made-up customers, crews and past storms), taken from a local
instance the morning before a real forecast storm, with the US National Weather Service as the
forecast source and a made-up storm under way that day (four customers' visits at different
points). Rendered at 1440×900 in light and dark with Playwright, saved as WebP with cwebp.

The Open-Meteo ones are the same instance: the weather popup with Open-Meteo as the forecast source,
and Settings → Weather rules with the Open-Meteo app added (a stand-in connection, no real key) and
its paid service chosen. Rendered and saved the same way.

The others taken from that instance (website forms, Careers, Drive, Marketing, Google Business
Profile, Facebook and Instagram, Paving, Roofing, the five calendar apps, Claude, ChatGPT,
QuickBooks, Zoho Books, Stripe and Twilio) are the app's real screens for the same made-up
business, with made-up clients, requests, applicants, files, reviews, posts, projects, visits,
invoices, payments and texts put into its database, and files drawn or printed locally. Nothing
outside was connected: each connection is a stand-in row with no key, holding what a real sync
would have written (reviews, calendar events, Stripe fees and deposits, assistant activity). Three
things to know when retaking them:

- The instance had no email or Twilio keys, so for the Marketing and Twilio ones the browser
  answered /api/config as a server with email and texting set up would (and /api/social as one
  with a public address); the screens are otherwise as served.
- Jobly has no screen that shows what went to QuickBooks or Zoho Books, so theirs are the
  invoices list and one paid invoice: what the app sends, not the sending.
- The Claude and ChatGPT ones are each app's own page, scrolled to the connected assistants.
