#!/usr/bin/env bash
# Rebase fork-main onto the upstream `tip` tag.
# See FORK_CHANGES.md → "Pulling upstream updates" for why `tip` not `upstream/main`.
set -euo pipefail

cd "$(dirname "$0")/.."

git fetch upstream --tags --force
git checkout fork-main
git rebase tip
git push --force-with-lease
