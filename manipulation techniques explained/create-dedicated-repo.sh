#!/usr/bin/env bash
#
# create-dedicated-repo.sh
# ------------------------
# Moves the "manipulation techniques explained" folder into its OWN brand-new
# GitHub repository.
#
# WHY THIS SCRIPT EXISTS
#   The scripts were first delivered as a folder inside the existing
#   "win11-debloat" repository (that was the explicitly named location).
#   The request also asked for a *new repository*. The assistant that produced
#   these files could not create a new GitHub repo from its sandbox (no GitHub
#   CLI and no API token were available). This script lets YOU create the
#   dedicated repo in a few seconds from your own machine, where you ARE logged in.
#
# WHAT IT DOES
#   1. Creates a new local git repo from the contents of this folder.
#   2. Creates a new repo on GitHub (using the GitHub CLI, `gh`).
#   3. Pushes everything to the new repo's main branch.
#
# REQUIREMENTS
#   - git            (https://git-scm.com/)
#   - GitHub CLI gh  (https://cli.github.com/) , authenticated:  gh auth login
#
# USAGE
#   cd "manipulation techniques explained"
#   bash create-dedicated-repo.sh                 # defaults below
#   REPO_NAME="media-literacy-course" VISIBILITY="public" bash create-dedicated-repo.sh
#
set -euo pipefail

# ---- Settings (override with environment variables) -------------------------
REPO_NAME="${REPO_NAME:-manipulation-techniques-explained}"
VISIBILITY="${VISIBILITY:-public}"   # "public" or "private"
DESCRIPTION="${DESCRIPTION:-A 22-episode media-literacy documentary script series: spot the manipulation techniques used by advertisers and politicians.}"
# -----------------------------------------------------------------------------

echo "==> Target repo name : ${REPO_NAME}"
echo "==> Visibility       : ${VISIBILITY}"

# Sanity checks
command -v git >/dev/null 2>&1 || { echo "ERROR: git is not installed."; exit 1; }
command -v gh  >/dev/null 2>&1 || {
  echo "ERROR: GitHub CLI 'gh' is not installed. Install it from https://cli.github.com/ then run: gh auth login";
  exit 1;
}
gh auth status >/dev/null 2>&1 || { echo "ERROR: You are not logged in to gh. Run: gh auth login"; exit 1; }

# Work inside the folder this script lives in
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Initialise a fresh repo (only if one isn't already here)
if [ ! -d .git ]; then
  git init
  git checkout -b main 2>/dev/null || git branch -M main
fi

git add -A
git commit -m "Initial commit: Manipulation Techniques Explained (22-episode script series)" || echo "(nothing new to commit)"

# Create the GitHub repo and push. --source=. pushes the current folder.
gh repo create "${REPO_NAME}" \
  --"${VISIBILITY}" \
  --source=. \
  --remote=origin \
  --description "${DESCRIPTION}" \
  --push

echo ""
echo "==> Done. Your new repository is live:"
gh repo view "${REPO_NAME}" --json url --jq .url 2>/dev/null || echo "    (open it on github.com under your account: ${REPO_NAME})"
