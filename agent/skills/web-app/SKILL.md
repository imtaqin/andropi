---
name: web-app
description: Build polished web pages and small web apps the user can preview live inside AndroPI and deploy. Use for landing pages, tools, games, dashboards, prototypes, or any "make me a website/page/app" request.
---

# Web apps in AndroPI

The app shows a live preview of any `.html` file you write with the write or
edit tool (a Preview button on the tool call). Design for that.

## Defaults

- One self-contained `index.html` (inline CSS and JS) unless the user asks for
  a framework or the app clearly needs several files. Put each project in its
  own folder in the workspace, e.g. `workspace/<project>/index.html`.
- Mobile first: `<meta name="viewport" content="width=device-width, initial-scale=1">`,
  fluid layouts, 16px+ body text, 44px touch targets, no hover-only UI.
- Modern, deliberate look: a clear type scale, generous spacing, a restrained
  palette with one accent, light and dark via `prefers-color-scheme`.
- No build step needed to preview. CDN imports (esm.sh, jsdelivr, unpkg) are
  fine; the preview has network access.
- Persist small state in `localStorage`.

## Frameworks

If the user wants React/Vue/Svelte/Next, scaffold in the Linux container
(see the linux-container skill), then build to static files (`dist/`, `out/`)
so they can be previewed and deployed. Vite: `npm create vite@latest`.

## Finish

Tell the user the file path, that they can tap Preview, and that the rocket
button in the chat deploys the folder to Vercel, GitHub Pages or their server.
