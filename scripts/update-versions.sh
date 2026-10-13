#!/usr/bin/env bash
# Bumps the pinned versions in the Dockerfile.
#
# Hermes Agent follows the image Nous Research tags as `stable` on Docker Hub
# and is bumped as soon as that moves. Hermes WebUI publishes a release almost
# every day, so it is only bumped together with an agent release, on Mondays,
# or when FORCE_ALL=1. That keeps "update available" notices for template
# users to roughly one a week.
#
# Prints a markdown summary of changes. Prints nothing if nothing changed.
# Needs curl and jq. Set GITHUB_TOKEN to avoid GitHub's anonymous rate limit.
set -euo pipefail

DOCKERFILE="$(dirname "$0")/../Dockerfile"
HUB="https://hub.docker.com/v2/repositories/nousresearch/hermes-agent"
GH="https://api.github.com/repos/nesquena/hermes-webui"

current() { sed -n "s/^ARG $1=//p" "$DOCKERFILE"; }
set_arg() { sed -i.bak "s|^ARG $1=.*|ARG $1=$2|" "$DOCKERFILE" && rm -f "$DOCKERFILE.bak"; }
github() {
  curl -fsSL -H 'Accept: application/vnd.github+json' \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$GH/$1"
}

changes=""

# --- Hermes Agent: the version tag that shares the `stable` tag's digest.
stable_digest="$(curl -fsSL "$HUB/tags/stable" | jq -r .digest)"
agent_tag="$(curl -fsSL "$HUB/tags?page_size=100&ordering=last_updated" | jq -r --arg d "$stable_digest" '
  [.results[]
   | select(.digest == $d)
   | .name
   | select(test("^(rc\\.[0-9]+-)?v[0-9][0-9.]*$"))]
  | (map(select(startswith("v"))) + .) | .[0] // empty')"
if [ -z "$stable_digest" ] || [ "$stable_digest" = null ] || [ -z "$agent_tag" ]; then
  echo "Could not resolve the Hermes Agent stable image on Docker Hub" >&2
  exit 1
fi
agent_version="${agent_tag#rc.*-}"
old_digest="$(current HERMES_AGENT_DIGEST)"
if [ "$old_digest" != "$stable_digest" ]; then
  old_version="$(current HERMES_AGENT_VERSION)"
  set_arg HERMES_AGENT_TAG "$agent_tag"
  set_arg HERMES_AGENT_DIGEST "$stable_digest"
  set_arg HERMES_AGENT_VERSION "$agent_version"
  changes+="- Hermes Agent: \`${old_version}\` → \`${agent_version}\` (image \`${agent_tag}\`)"$'\n'
fi
agent_changed="$changes"

# --- Hermes WebUI: the newest release, stable or experimental.
if [ -n "$agent_changed" ] || [ "$(date -u +%u)" = 1 ] || [ "${FORCE_ALL:-}" = 1 ]; then
  webui_tag="$(github 'releases?per_page=20' | jq -r '
    [.[] | select(.draft | not) | select(.tag_name | test("^(exp-)?v[0-9]"))]
    | sort_by(.published_at) | last | .tag_name // empty')"
  [ -n "$webui_tag" ] || { echo "Could not find the latest Hermes WebUI release" >&2; exit 1; }
  old_webui="$(current HERMES_WEBUI_VERSION)"
  if [ "$old_webui" != "$webui_tag" ]; then
    webui_sha="$(github "commits/$webui_tag" | jq -r .sha)"
    [[ "$webui_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "Could not resolve $webui_tag to a commit" >&2; exit 1; }
    set_arg HERMES_WEBUI_VERSION "$webui_tag"
    set_arg HERMES_WEBUI_COMMIT "$webui_sha"
    changes+="- Hermes WebUI: \`${old_webui}\` → \`${webui_tag}\`"$'\n'
  fi
fi

printf '%s' "$changes"
