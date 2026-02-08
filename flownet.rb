class Flownet < Formula
  desc "AWDL suppression daemon for optimized WiFi performance"
  homepage "https://github.com/Se7enbrc/flownet"
  url "https://github.com/Se7enbrc/flownet/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "619fc59096680041f21b4519f8bf5700fbb0ed29cb0d4d3536bdfbf37c8b51ef"
  license "MIT"

  depends_on :macos
  depends_on xcode: :build

  def install
    # Build the daemon
    system "make"

    # Install binaries
    bin.install "build/flownet"
    bin.install "flowctl"
  end

  service do
    run [opt_bin/"flownet"]
    run_type :immediate
    keep_alive true
    log_path var/"log/flownet.log"
    error_log_path var/"log/flownet.log"
    require_root true
    process_type :background
  end

  def post_install
    system("sudo", "brew", "services", "start", "flownet")
  end

  def caveats
    <<~EOS
      FlowNet is now running and will start automatically at boot.

      Check status:
        flowctl status

      Stop/restart:
        sudo brew services stop flownet
        sudo brew services restart flownet
    EOS
  end
end
