{ config, lib, pkgs, modulesPath, ... }:
# Hardware burn-in stick: a live ISO that boots straight into an endless
# stress/verify cycle (burnin-run.sh) with a memtest-style status screen
# on tty1 (dashboard.py); tty2 is a root shell.
#
# Deliberately inert: no network, no ssh, nothing touches the internal
# disks (stressapptest runs without disk threads, memtester tests RAM
# only, everything else lives in tmpfs).
let
  burninRun = pkgs.writeShellApplication {
    name = "burnin-run";
    runtimeInputs = with pkgs; [
      coreutils gawk gnutar jq ripgrep zstd nix
      stress-ng stressapptest memtester
    ];
    text = builtins.readFile ./burnin-run.sh;
  };
  dashboard = pkgs.writers.writePython3Bin "burnin-dashboard" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./dashboard.py);
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/iso-image.nix" ];

  networking.hostName = "burnin";
  system.stateVersion = "26.05";

  isoImage = {
    makeEfiBootable = true;
    makeUsbBootable = true;
    # Boot menu: "Burn-in Stick · built on NixOS 26.05…" — not an
    # official NixOS image.
    prependToMenuLabel = "Burn-in Stick · built on ";
    appendToMenuLabel = "";
    volumeID = "BURNIN-STICK";
    squashfsCompression = "zstd -Xcompression-level 6";
  };
  image.baseName = lib.mkForce "burnin-stick";

  # Newest kernel and current microcode: test the hardware with the
  # software it will most likely run.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  hardware.cpu.intel.updateMicrocode = true;
  hardware.cpu.amd.updateMicrocode = true;
  boot.initrd.availableKernelModules = [ "xhci_pci" "ehci_pci" "usb_storage" "sd_mod" ];
  boot.kernelModules = [ "coretemp" ];
  boot.kernelParams = [
    # Never blank the console: a panic must stay readable after 40 h.
    "consoleblank=0"
  ];
  # A panic stays on screen (no automatic reboot) — memtest semantics.
  boot.kernel.sysctl."kernel.panic" = 0;
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # Readable on a 1080p screen.
  console = {
    earlySetup = true;
    packages = [ pkgs.terminus_font ];
    font = "ter-v22b";
  };

  # No network at all.
  networking.useDHCP = false;
  networking.interfaces = lib.mkForce { };
  networking.wireless.enable = false;
  networking.networkmanager.enable = false;
  services.openssh.enable = false;

  # Root shell on tty2+ (offline stick, physical access is the trust model).
  users.users.root.initialHashedPassword = "";
  services.getty.autologinUser = "root";
  # tty1 belongs to the dashboard.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  environment.systemPackages = [
    burninRun dashboard
    pkgs.stress-ng pkgs.stressapptest pkgs.memtester
    config.boot.kernelPackages.turbostat
    pkgs.lm_sensors pkgs.htop pkgs.ripgrep pkgs.jq
  ];

  # A live image has nowhere to persist a journal.
  services.journald.storage = "volatile";

  systemd.services.burnin = {
    description = "Endless hardware burn-in cycle";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    environment.BURNIN_STATE = "/run/burnin";
    serviceConfig = {
      ExecStart = lib.getExe burninRun;
      RuntimeDirectory = "burnin";
      RuntimeDirectoryPreserve = "yes";
      Restart = "on-failure";
      RestartSec = 10;
      # The test is supposed to eat memory; the dashboard is not.
      OOMScoreAdjust = 500;
    };
  };

  systemd.services.burnin-dashboard = {
    description = "Burn-in status screen on tty1";
    wantedBy = [ "multi-user.target" ];
    after = [ "burnin.service" "systemd-vconsole-setup.service" ];
    conflicts = [ "getty@tty1.service" ];
    path = [ config.systemd.package ];
    environment = {
      BURNIN_STATE = "/run/burnin";
      TERM = "linux";
    };
    serviceConfig = {
      ExecStart = lib.getExe dashboard;
      StandardInput = "tty-force";
      StandardOutput = "tty";
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVTDisallocate = true;
      Restart = "always";
      RestartSec = 2;
      Nice = -5;
      OOMScoreAdjust = -900;
    };
  };
}
