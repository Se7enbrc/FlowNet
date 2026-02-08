class Flownet < Formula
  desc "AWDL suppression daemon for optimized WiFi performance"
  homepage "https://github.com/Se7enbrc/flownet"
  url "https://github.com/Se7enbrc/flownet/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "95bf9e6b4d7f77893e24ab0790aac4a73a1e06b47c1ebf74fcc49326f0791bbe"
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
      FlowNet requires root privileges to manage AWDL interfaces.

      To start FlowNet now and restart at boot:
        sudo brew services start flownet

      Check status:
        flowctl status

      View logs:
        flowctl logs

      Stop/restart:
        sudo brew services stop flownet
        sudo brew services restart flownet
    EOS
  end
end
