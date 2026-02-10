#!/bin/sh
set -e

echo "=== Environment ==="
echo "Ruby: $(ruby --version)"
echo "Gem: $(gem --version)"
echo "CI_PRIMARY_REPOSITORY_PATH: $CI_PRIMARY_REPOSITORY_PATH"
echo "HOME: $HOME"
echo "PATH: $PATH"

echo "=== Installing CocoaPods ==="
gem install cocoapods --user-install --no-document

# Add user gem bin to PATH
export PATH="$(ruby -r rubygems -e 'puts Gem.user_dir')/bin:$PATH"
echo "Updated PATH: $PATH"
echo "Pod version: $(pod --version)"

echo "=== Running pod install ==="
cd "$CI_PRIMARY_REPOSITORY_PATH"
pod install

echo "=== CocoaPods installation complete ==="
