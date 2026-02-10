#!/bin/sh
set -e

echo "Installing CocoaPods..."
brew install cocoapods

echo "Running pod install..."
pod install

echo "CocoaPods installation complete."
