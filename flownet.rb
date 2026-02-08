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

  def caveats
    <<~EOS
      Start FlowNet:
        sudo brew services start flownet

      Check status:
        flowctl status

      View logs:
        flowctl logs
    EOS
  end
end
