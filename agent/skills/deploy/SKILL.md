---
name: deploy
description: Publish a site or app from the phone to Vercel, GitHub Pages or the user's own server over SSH, and check that it went live. Use when the user asks to deploy, publish, host, ship or put something online.
---

# Deploy

The easiest path is the rocket button in the AndroPI chat: it deploys the
current project folder and shows CI and build logs live. Suggest it first.
When the user wants you to do it, use these.

## Vercel (`$VERCEL_TOKEN`)

Static folders deploy without a build. From the folder to publish:

```sh
npx --yes vercel@latest deploy --prod --yes --token "$VERCEL_TOKEN"
```

This needs Node.js; if `npx` is missing, use the Linux container (see the
linux-container skill). The command prints the live URL.

## GitHub Pages (`$GITHUB_TOKEN`)

1. Commit and push the site to a GitHub repo (see the github skill).
2. Enable Pages from the branch root:
   ```sh
   curl -fsSL -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
     https://api.github.com/repos/OWNER/REPO/pages \
     -d '{"source":{"branch":"main","path":"/"}}'
   ```
   (HTTP 409 means it is already enabled.)
3. Watch the "pages build and deployment" run in
   `/repos/OWNER/REPO/actions/runs?head_sha=...` until it succeeds, then give
   the user `https://OWNER.github.io/REPO/`.

## Own server (SSH)

Saved servers are aliases in `~/.ssh/config`: `ssh <name>` works, and the
device key is `~/.ssh/id_ed25519`.

```sh
rsync -az --delete --exclude .git ./ <name>:/var/www/site/
# or, if rsync is missing on the server:
scp -S ssh -r ./. <name>:/var/www/site/
```

Always verify at the end: `curl -sI <url>` should return 200.
