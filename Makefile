.PHONY: build test ci security sbom clean

build:
	swift build -c release

test:
	swift test --parallel

ci: build test

security:
	chmod +x scripts/security-scan.sh
	./scripts/security-scan.sh

icon:
	chmod +x scripts/export-icon.sh
	./scripts/export-icon.sh

sbom:
	@mkdir -p .build
	syft dir:. -o cyclonedx-json > .build/sbom.cyclonedx.json
	@echo "wrote .build/sbom.cyclonedx.json"

clean:
	swift package clean
	rm -rf .build
