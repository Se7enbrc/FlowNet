class Flownet < Formula
  desc "AWDL suppression daemon for optimized WiFi performance"
  homepage "https://github.com/Se7enbrc/flownet"
  url "https://github.com/Se7enbrc/flownet/archive/refs/tags/v1.0.1.tar.gz"
  sha256 "fa252b811dfc1c1bbb2200d463cd968b8e63edea4f054a908eb5dc83f13908d3"
  license "MIT"

  depends_on :macos
  depends_on xcode: :build

  def install
    # Build the daemon
    system "make"

    # Install binaries
    bin.install "build/flownet"
    bin.install "flowctl"

    # Install launchd plist
    (prefix/"LaunchDaemons").install "com.whaleyshire.flownet.plist"
  end

  def post_install
    # Install plist to system location (requires sudo)
    plist_path = "/Library/LaunchDaemons/com.whaleyshire.flownet.plist"
    daemon_path = "#{opt_bin}/flownet"
    log_path = "/var/log/flownet.log"

    # Create temporary plist with correct paths
    plist_content = <<~EOS
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>Label</key>
          <string>com.whaleyshire.flownet</string>
          <key>ProgramArguments</key>
          <array>
              <string>#{daemon_path}</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <dict>
              <key>SuccessfulExit</key>
              <false/>
          </dict>
          <key>ThrottleInterval</key>
          <integer>30</integer>
          <key>StandardOutPath</key>
          <string>#{log_path}</string>
          <key>StandardErrorPath</key>
          <string>#{log_path}</string>
          <key>UserName</key>
          <string>root</string>
          <key>ProcessType</key>
          <string>Background</string>
          <key>Nice</key>
          <integer>1</integer>
          <key>AbandonProcessGroup</key>
          <true/>
      </dict>
      </plist>
    EOS

    # Write plist to temp file
    temp_plist = "/tmp/flownet.plist"
    File.write(temp_plist, plist_content)

    # Install plist and start service (will prompt for sudo)
    system "sudo", "mv", temp_plist, plist_path
    system "sudo", "chmod", "644", plist_path
    system "sudo", "chown", "root:wheel", plist_path
    system "sudo", "touch", log_path
    system "sudo", "chmod", "644", log_path

    # Stop existing service if running (ignore errors)
    system "sudo", "launchctl", "bootout", "system/com.whaleyshire.flownet", [:err] => :close

    # Start the service
    system "sudo", "launchctl", "bootstrap", "system", plist_path
    system "sudo", "launchctl", "kickstart", "system/com.whaleyshire.flownet"

    ohai "FlowNet is now running!"
  end

  def caveats
    <<~EOS
      FlowNet is running and will start automatically at boot.

      Check status:
        flowctl status

      View logs:
        flowctl logs

      Stop/restart:
        sudo launchctl bootout system/com.whaleyshire.flownet
        sudo launchctl bootstrap system /Library/LaunchDaemons/com.whaleyshire.flownet.plist
    EOS
  end
end
