#!/bin/sh
set -e

echo "Installing CocoaPods via gem..."
gem install cocoapods --no-document

echo "Running pod install..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
pod install

echo "CocoaPods installation complete."
