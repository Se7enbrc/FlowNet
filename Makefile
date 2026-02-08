.PHONY: all clean build install uninstall

BUILD_DIR=build
DAEMON_SRC=src/flownet-daemon.swift

all: build

build:
	@echo ""
	@echo "╔════════════════════════════════════════════════════════════╗"
	@echo "║                FlowNet Daemon Build                        ║"
	@echo "╚════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "🔨 Building daemon..."
	@rm -rf $(BUILD_DIR) 2>/dev/null || true
	@mkdir -p $(BUILD_DIR)
	@swiftc -o $(BUILD_DIR)/flownet $(DAEMON_SRC) -O
	@echo "   ✓ Daemon compiled"
	@echo ""
	@echo "✅ Build complete!"
	@echo ""
	@echo "   Daemon: $(BUILD_DIR)/flownet"
	@echo ""
	@echo "To install:"
	@echo "   sudo ./flowctl install"
	@echo ""
	@echo "Or manually:"
	@echo "   sudo cp $(BUILD_DIR)/flownet /usr/local/bin/"
	@echo "   sudo cp com.whaleyshire.flownet.plist /Library/LaunchDaemons/"
	@echo "   sudo launchctl bootstrap system /Library/LaunchDaemons/com.whaleyshire.flownet.plist"
	@echo ""

install: build
	@./flowctl install

uninstall:
	@./flowctl uninstall

clean:
	@rm -rf $(BUILD_DIR)
	@echo "✓ Clean"
