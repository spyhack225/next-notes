#!/bin/zsh
#
# Installs the Google Workspace CLI, which Next Notes runs as its Workspace tool layer.
#
# Opened in Terminal rather than run inside the app on purpose: this installs software on
# the user's machine, Homebrew and npm both ask for input, and an installer that ran
# silently behind a progress bar would be doing exactly what a note-taking app should never
# do quietly. The user watches it, and can stop it.
set -e

echo "Installing the Google Workspace CLI (gws) for Next Notes."
echo

if command -v brew >/dev/null 2>&1; then
  echo "> brew install googleworkspace-cli"
  brew install googleworkspace-cli
elif command -v npm >/dev/null 2>&1; then
  echo "> npm install -g @googleworkspace/cli"
  npm install -g @googleworkspace/cli
else
  echo "Neither Homebrew nor npm is installed, and gws is published through both."
  echo "Install Homebrew from https://brew.sh and run this again."
  exit 1
fi

echo
gws --version
echo
echo "Done. Back in Next Notes, the Workspace tab will now offer the next step."
