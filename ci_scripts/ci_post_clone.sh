#!/bin/sh

echo "=== Environment ==="
echo "Ruby: $(ruby --version)"
echo "HOME: $HOME"
echo "CI_PRIMARY_REPOSITORY_PATH: $CI_PRIMARY_REPOSITORY_PATH"
echo "PATH: $PATH"

echo "=== Checking for existing CocoaPods ==="
if command -v pod >/dev/null 2>&1; then
    echo "CocoaPods already installed: $(pod --version)"
else
    echo "CocoaPods not found, installing via Homebrew..."
    brew install cocoapods 2>&1 || {
        echo "Homebrew failed, trying gem install..."
        export GEM_HOME="$HOME/.gem"
        export PATH="$GEM_HOME/bin:$PATH"
        gem install cocoapods --no-document 2>&1
    }
    echo "Pod version: $(pod --version)"
fi

echo "=== Running pod install ==="
cd "$CI_PRIMARY_REPOSITORY_PATH"
pod install --verbose 2>&1

echo "=== Done ==="
