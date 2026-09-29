#!/bin/bash
# Moves this fork's commits onto the latest official Mac release, then rebuilds and installs.
#
# Usage: buildscripts/sync_upstream.sh [upstream-ref]
#   upstream-ref defaults to the newest non-beta mac-* release tag, e.g. mac-7.1.5.
#   Pass upstream/main to follow development instead of releases.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

if [ -n "$(git status --porcelain)" ]; then
	echo "There are uncommitted changes. Commit or stash them first."
	exit 1
fi

git fetch upstream --tags --quiet

TARGET="${1:-$(git tag --list 'mac-*' --sort=-v:refname | grep -vE 'b[0-9]+$|d[0-9]+$|rc[0-9]*$' | head -1)}"
# The fork's own commits are the ones not in any upstream branch or tag.
FIRST_FORK_COMMIT="$(git rev-list --reverse HEAD --not --remotes=upstream --tags | head -1)"
if [ -z "${FIRST_FORK_COMMIT}" ]; then
	echo "Couldn't find this fork's commits."
	exit 1
fi
BASE="$(git rev-parse "${FIRST_FORK_COMMIT}^")"

if git merge-base --is-ancestor "${TARGET}" HEAD; then
	echo "Already up to date: this build already includes ${TARGET}."
	exit 0
fi

echo "Moving $(git rev-list --count "${BASE}"..HEAD) fork commits onto ${TARGET}"
if ! git rebase --onto "${TARGET}" "${BASE}"; then
	git rebase --abort
	echo "The fork's changes conflict with ${TARGET}. Nothing was changed. Resolve the conflicts by hand (or ask for help), then run this again."
	exit 1
fi

git push --force-with-lease --quiet origin HEAD
"${PROJECT_ROOT}/buildscripts/install_local.sh"
