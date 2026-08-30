# First-time setup (and any time the project file must be regenerated):
# generates Env.swift from the root .env, then regenerates the Xcode project.
setup:
	./buildEnv.sh ../.env Generated
	xcodegen

build: setup
	xcodebuild -project ZavaRetail.xcodeproj -scheme ZavaRetail -destination 'generic/platform=iOS Simulator' build
