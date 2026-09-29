---
name: github
description: Work with GitHub from the phone - clone, commit, push, branches, pull requests, issues, releases, Actions status - using git and the GitHub REST API. Use for any GitHub task or when the user mentions a repo, PR, issue or CI.
---

# GitHub

When the user has connected GitHub in AndroPI, `$GITHUB_TOKEN` is set and git
is already authenticated for https://github.com (clone, pull and push just
work; commits use their name and email). There is no `gh` CLI; use curl.

```sh
api() { curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "https://api.github.com$@"; }
```

If `$GITHUB_TOKEN` is empty, ask the user to connect GitHub under
Accounts & servers, then continue.

## Common tasks

- Who am I: `api /user`
- My repos: `api "/user/repos?sort=pushed&per_page=30"`
- Create a repo: `api /user/repos -X POST -d '{"name":"demo","private":false}'`
- Open a PR:
  ```sh
  api /repos/OWNER/REPO/pulls -X POST -d '{"title":"...","head":"branch","base":"main","body":"..."}'
  ```
- Issues: `api "/repos/OWNER/REPO/issues?state=open"`, comment with
  `-X POST /repos/OWNER/REPO/issues/N/comments -d '{"body":"..."}'`
- CI: `api "/repos/OWNER/REPO/actions/runs?head_sha=$(git rev-parse HEAD)"`;
  job logs: `api /repos/OWNER/REPO/actions/jobs/JOB_ID/logs`

## Git habits

- Check `git status` and `git remote -v` before committing or pushing.
- Small, descriptive commits. Never force-push to the default branch unless
  asked.
- Use `jq`-free parsing: `node -e` or `python3 -c` to read JSON responses.
