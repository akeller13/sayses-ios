#!/bin/sh

echo "=== Environment ==="
echo "Ruby: $(ruby --version)"
echo "HOME: $HOME"
echo "CI_PRIMARY_REPOSITORY_PATH: $CI_PRIMARY_REPOSITORY_PATH"
echo "PATH: $PATH"
echo "Working directory: $(pwd)"
echo "Contents of repo root:"
ls -la "$CI_PRIMARY_REPOSITORY_PATH"

echo "=== Checking for existing CocoaPods ==="
if command -v pod >/dev/null 2>&1; then
    echo "CocoaPods already installed: $(pod --version)"
else
    echo "CocoaPods not found, installing via Homebrew..."
    if brew install cocoapods 2>&1; then
        echo "Homebrew install succeeded"
    else
        echo "Homebrew failed, trying gem install..."
        export GEM_HOME="$HOME/.gem"
        export PATH="$GEM_HOME/bin:$PATH"
        gem install cocoapods --no-document 2>&1
    fi
    echo "Pod location: $(which pod)"
    echo "Pod version: $(pod --version)"
fi

echo "=== Running pod install ==="
cd "$CI_PRIMARY_REPOSITORY_PATH"
pod install --repo-update 2>&1
POD_EXIT=$?

echo "=== pod install exit code: $POD_EXIT ==="

echo "=== Checking Pods directory ==="
if [ -d "$CI_PRIMARY_REPOSITORY_PATH/Pods" ]; then
    echo "Pods directory exists"
    ls "$CI_PRIMARY_REPOSITORY_PATH/Pods/Target Support Files/Pods-SAYses/" 2>&1 || echo "Target Support Files not found!"
else
    echo "ERROR: Pods directory does NOT exist!"
fi

exit $POD_EXIT
