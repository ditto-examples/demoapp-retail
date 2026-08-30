SIM = platform=iOS Simulator,name=iPhone 17 Pro

# First-time setup (and any time files are added/removed): regenerates
# Env.swift from the root .env, then the Xcode project.
setup:
	./buildEnv.sh ../.env Generated
	xcodegen

# --- Code quality (PLAN: production-readiness bar) ---
lint:
	swiftlint lint --config .swiftlint.yml

# CI gate: promotes warnings to errors.
lint-strict:
	swiftlint lint --strict --config .swiftlint.yml

format:
	swiftformat .

format-check:
	swiftformat --lint .

# Dead-code analysis (builds for indexing; slow). Informational — expected
# noise: assign-only warnings on Models.swift (document-mirror fields) and the
# vendored Anvil palette.
periphery:
	periphery scan --project ZavaRetail.xcodeproj --schemes ZavaRetail --disable-update-check -- -destination '$(SIM)'

# --- Build & test ---
build: setup
	xcodebuild -project ZavaRetail.xcodeproj -scheme ZavaRetail -destination '$(SIM)' build

test:
	xcodebuild -project ZavaRetail.xcodeproj -scheme ZavaRetail -destination '$(SIM)' -only-testing:ZavaRetailTests test

test-ui:
	xcodebuild -project ZavaRetail.xcodeproj -scheme ZavaRetail -destination '$(SIM)' -only-testing:ZavaRetailUITests test

# Coverage: unit + UI tests in one result bundle (the UI tests exercise the
# app process, so view code counts too). Fails under 85% total line coverage.
coverage:
	rm -rf build/TestResults.xcresult
	xcodebuild -project ZavaRetail.xcodeproj -scheme ZavaRetail -destination '$(SIM)' -resultBundlePath build/TestResults.xcresult test
	python3 scripts/check_coverage.py build/TestResults.xcresult 85
