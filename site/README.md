# Iriz website

This directory contains the static public website and distribution material for [Iriz](https://github.com/daviddemri26/iriz).

## Pages

- `index.html` — product home page
- `privacy.html` — public privacy policy draft
- `support.html` — product requirements, permissions and common questions
- `press.html` — approved copy and downloadable brand assets
- `download.html` — dedicated direct-download and installation page
- `404.html` — static not-found page

## Distribution material

- `distribution/app-store-listing.md` — future Mac App Store metadata and screenshot story
- `distribution/release-checklist.md` — legal, commercial, listing and release preparation
- `assets/iriz-icon.png` — approved application artwork copied from the app project
- `assets/iriz-icon-1024.png` — listing-ready 1024 × 1024 application icon
- `assets/iriz-social-card.png` — landscape social and press preview

## Local preview

Serve this directory with any static HTTP server. For example:

```sh
cd site
python3 -m http.server 8080
```

Then open `http://localhost:8080`.

## Cloudflare Workers

The site has no framework, package manager, build step, database, cookies or analytics. It is deployed as a static-assets Worker at `https://lafayette-consulting.us/iriz/`. `worker.js` only maps that public path prefix to the static files in this directory.

Cloudflare Workers Builds uses:

- repository: `daviddemri26/iriz`;
- production branch: `main`;
- root directory: `/site`;
- no build command;
- deploy command: `npx wrangler deploy`; and
- build watch path: `site/*`.

`wrangler.jsonc` owns the production route, disables `workers.dev` and preview URLs, and configures the static-assets binding. Do not recreate a dashboard-only route because the next Wrangler deployment would replace it.

Before public distribution, publish a signed and notarized GitHub Release asset named exactly `Iriz.zip`, then verify the Home, Download, Privacy, Support, Press Kit and 404 routes after deployment.

Do not publish the Privacy Policy as final until the publisher identity, contact method, hosting configuration, OpenAI release setup and final shipping binary have been reviewed.
