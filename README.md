# gpu-unlock-ada, repinned: RTX 4080 (AD103) tensor unlock, Linux

A fork of [JustAResearcher/gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada)
(v1.1.1, `d28c485`) carrying exactly one change: the pinned `nvidia-utils`
build input now resolves from Arch's permanent package archive. Upstream pins
`nvidia-utils-610.43.03-1-x86_64_v3.pkg.tar.zst` from the CachyOS archive
pool, which has rotated past that version, so `make install` 404s for
everybody ([upstream issue #145](https://github.com/JustAResearcher/gpu-unlock-ada/issues/145)).
The replacement package carries the pinned `gsp_ga10x.bin` byte-identical;
this fork's build produces bit-for-bit the upstream-pinned firmware payloads,
verified post-build against upstream's published payload hashes.

All credit for the unlock itself belongs to upstream and to the AD102 payload
authors ([TOTORONG/AD103_win_unlocker](https://huggingface.co/TOTORONG/AD103_win_unlocker)).
This repo adds the repin, an Arch one-command installer, and a new measured
result for a stock-clocked RTX 4080 at driver 620.70.06. Upstream's full
README (evidence for every supported card) is preserved as
[README-upstream.md](README-upstream.md).

## What it does

The kernel module runs in the initramfs before the NVIDIA driver binds,
brings up the GSP on its own pinned 610.43.03 boot assets, opens the
speed-select feature gate, issues a PCIe FLR, and steps away. The stock
driver then initialises an already-unlocked card. FP16/BF16/TF32 tensor
throughput with FP32 accumulation roughly doubles at the issue-rate level.
INT8, `dp4a` and scalar FP32 do not change. Nothing is written to the vBIOS;
an AC power cycle returns the card to stock.

## Measured result: RTX 4080, driver 620.70.06, Arch (CachyOS)

Card: MSI GeForce RTX 4080 (AD103, `10de:2704`, subsystem `1458`), 76 SMs,
custom raised-power-limit vBIOS, driver 620.70.06 open modules, kernel
7.3.3-1-cachyos, unlocked on the **first cold boot** with no Xid and no
display/compute errors. Driver-side confirmation: the repo's RM getter
reports `fmla32: 0` (full rate) on all fields.

Instruction issue rate, `mma_bench 20000 5` (same protocol as upstream's
published evidence), compared against the published matched run for a second
2704 card ([upstream `ada2702-ada2704-matched`](https://github.com/JustAResearcher/gpu-unlock-ada/tree/main/docs/evidence/ada2702-ada2704-matched)):

| mode | this card, unlocked | published stock (2704) | ratio |
|---|---:|---:|---:|
| f16/f32 (the unlocked path) | **223.3 TF/s** | 107.0 TF/s | **2.09×** |
| bf16/f32 | **222.1 TF/s** | 106.9 TF/s | **2.08×** |
| f16/f16 (control, never affected) | 223.4 TF/s | 214.2 TF/s | 1.04 |
| s8/s32 INT8 (control) | 444.2 TOP/s | 427.1 TOP/s | 1.04 |
| fp8/e4m3 | 442.6 TF/s | not published | see upstream FP8 notes |
| dp4a (control) | 110.5 TOP/s | 106.0 TOP/s | 1.04 |
| ffma scalar (control) | 53.3 TF/s | 50.8 TF/s | 1.05 |

Inside this card's own run, `f16/f32 ÷ f16/f16 = 1.000`. Stock is 0.50. Every
control sits at 1.04 of the published baseline (this card clocks ~4% higher);
only the two FP32-accumulate paths moved.

Application level, same machine, same Strata (llama.cpp) endpoint, model
`swift-1.5-iq3_s` (a quantised model), one run per state; method and raw
outputs in [`docs/evidence/rtx4080-cruachan/`](docs/evidence/rtx4080-cruachan/):

| prompt depth | stock tok/s | unlocked tok/s | gain |
|---|---:|---:|---:|
| 2K (1990 tok) | 978 | 1010 | +3.2% |
| 16K (~15.8K tok) | 2939 | 3381 | +15.1% |
| 32K (31811 tok) | 3490 | 3778 | +8.2% |
| 64K (~62.3K tok) | 3434 | 3990 | +16.2% |
| 128K (~127.9K tok) | 3325 | 4051 | +21.8% |

Honest reading of that second table: the 2K row is a clean matched pair. The
larger rows are single runs whose prompt token counts differ slightly between
states, and quantised matmuls are documented upstream *not* to consume the
FP32-accumulate tensor path, so part of the long-context gain may be
thermal/power behaviour rather than the tensor unlock. The mma table is the
measurement; the prefill table is an observation. Upstream's reported gains
for real cuBLAS GEMM (12-34%) are the expected application envelope.

## Install (Arch / CachyOS / EndeavourOS)

```sh
git clone https://github.com/gingertonik/gpu-unlock-ada-4080.git
cd gpu-unlock-ada-4080
./install.sh
```

The installer fetches dependencies, builds the packages from SHA-pinned
inputs (the build runs upstream's full test suite), and installs them. It
touches nothing on the GPU. Debian/Ubuntu and Fedora/RHEL users: `make
install-deb` / `make install-rpm` work as upstream describes; the repin
covers all three packaging paths.

## Enable

1. Print the exact kernel option for your card:
   `python3 tools/print_boot_option.py`
   For an RTX 4080 (`10de:2704`) it is:
   `gpu_unlock.targets=0000:01:00.0 gpu_unlock.rtx4080_experimental=1`
2. Append it to your kernel command line (limine: per-entry `cmdline:` in
   `/boot/efi/limine.conf`; systemd-boot: the entry file; grub:
   `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`).
3. **Cold boot:** clean shutdown, AC power out for 30 seconds, power on. A
   warm reboot will not unlock; the module skips an already-initialised card
   by design.
4. Verify:
   ```sh
   sudo dmesg | grep -i gpu_unlock   # want: pci 0000:01:00.0: gpu_unlock: unlocked
   python3 tools/read_sm_rates.py --expect-uuid "$(nvidia-smi --query-gpu=uuid --format=csv,noheader)"
   ```

## Uninstall / recovery

Remove the kernel option (the module is inert without it), then
`sudo pacman -Rns gpu-unlock-dkms gpu-unlock-firmware && sudo mkinitcpio -P`.
An AC power cycle clears the unlock state at the silicon level. The unlock
writes GPU registers in the same regions NVIDIA's own GSP flow writes at the
same stage; it flashes nothing. Published runs of this project report no
vBIOS losses; community reports around the wider unlock wave put such
incidents in the low single-digit percent, with no solid denominator.
Dumping your vBIOS (`nvflash --save`) before experimenting is cheap
insurance.

## Requirements and support

Arch-based, x86_64, DKMS, kernel headers for the running kernel, Secure Boot
disabled (the module is unsigned). Supported GPU IDs are exactly upstream's
list; the RTX 4080 (`10de:2704`) is an experimental target upstream tested
on two cards. This repo adds one. Driver 620.70.06 is, to the public record,
the newest driver with a verified 2704 unlock; upstream's proven range runs
580.178.04 to 615.78.08.

## License

GPL-2.0-only, as upstream. Firmware assets are generated locally at build
time from NVIDIA's own released packages; see `firmware/NOTICE.md`.
