# (newer) FireTV(s) Firmware Extractor
Extracts firmware packages from newer Fire TV devices (4K Select, etc.) that run Yocto Linux instead of Fire OS/Android. Handles SWUpdate CPIO archives, squashfs filesystems, and FIT boot images.

## Setup
**Dependencies:**
```bash
sudo apt install cpio gzip squashfs-tools binwalk device-tree-compiler wget git file zstd build-essential bison flex libssl-dev libgnutls28-dev libuuid-dev
```

**Build u-boot tools:**
```bash
git clone --depth 1 https://github.com/u-boot/u-boot.git /tmp/u-boot
cd /tmp/u-boot
make tools-only_defconfig && make tools-only -j$(nproc)
sudo cp tools/dumpimage tools/mkimage /usr/local/bin/
```

## Usage
**Local:**
```bash
sudo bash extract.sh firmware.zip
```

**With GitHub push:**
```bash
export GH_TOKEN="token"
export GH_USER="username"
sudo -E bash extract.sh firmware.zip
```

**GitHub Actions:**
Set secrets `GH_TOKEN` and `GH_USER`, then run workflow with firmware URL.

## Output
```
repo/
├── system-rootfs/
├── vendor-rootfs/
├── boot/
├── firmware/
└── install-scripts/
```

> [!NOTE]
> Large files (>50MB) compressed with zstd. Decompress: `zstd -d file.zst`

## Credits
[u-boot tools](https://github.com/u-boot/u-boot) for FIT extraction
