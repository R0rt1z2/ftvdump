#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

usage() {
    echo "Usage: sudo $0 <file|url> [output_dir]"
    exit 1
}

[ $# -lt 1 ] && usage

INPUT="$1"
OUTPUT_DIR="${2:-extracted}"
ACTUAL_USER=${SUDO_USER:-$USER}
SOURCE_URL="$INPUT"

GITHUB_TOKEN=""
GITHUB_USER=""
REPO_NAME=""
GIT_EMAIL=""
GIT_NAME=""

if [ -f ".github_token" ]; then
    GITHUB_TOKEN=$(cat .github_token)
fi

if [ -f ".github_user" ]; then
    GITHUB_USER=$(cat .github_user)
fi

if [ -f ".repo_name" ]; then
    REPO_NAME=$(cat .repo_name)
fi

if [ -f ".git_email" ]; then
    GIT_EMAIL=$(cat .git_email)
fi

if [ -f ".git_name" ]; then
    GIT_NAME=$(cat .git_name)
fi

[ -n "$GH_TOKEN" ] && GITHUB_TOKEN="$GH_TOKEN"
[ -n "$GH_USER" ] && GITHUB_USER="$GH_USER"
[ -n "$GH_REPO" ] && REPO_NAME="$GH_REPO"
[ -n "$GIT_USER_EMAIL" ] && GIT_EMAIL="$GIT_USER_EMAIL"
[ -n "$GIT_USER_NAME" ] && GIT_NAME="$GIT_USER_NAME"

if [[ "$INPUT" =~ ^https?:// ]]; then
    echo "Downloading..."
    TEMP=$(mktemp)
    wget -q --show-progress -O "$TEMP" "$INPUT" || exit 1
    ARCHIVE="$TEMP"
else
    [ ! -f "$INPUT" ] && echo "File not found: $INPUT" && exit 1
    ARCHIVE="$INPUT"
    SOURCE_URL="file://$(realpath $INPUT)"
fi

ARCHIVE_SHA256=$(sha256sum "$ARCHIVE" | awk '{print $1}')
ARCHIVE_SIZE=$(stat -f%z "$ARCHIVE" 2>/dev/null || stat -c%s "$ARCHIVE")
ARCHIVE_NAME=$(basename "$ARCHIVE")

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

cpio -idv < "$ARCHIVE" 2>&1 | grep -v "not created" > /dev/null

[ -n "$TEMP" ] && rm -f "$TEMP"

chown -R $ACTUAL_USER:$ACTUAL_USER .
git init -q

if [ -n "$GIT_EMAIL" ]; then
    git config user.email "$GIT_EMAIL"
elif ! git config user.email > /dev/null 2>&1; then
    git config user.email "extract@local"
fi

if [ -n "$GIT_NAME" ]; then
    git config user.name "$GIT_NAME"
elif ! git config user.name > /dev/null 2>&1; then
    git config user.name "Extractor"
fi

for gz_file in *.gz; do
    [ -f "$gz_file" ] || continue
    gunzip -f "$gz_file"
done

rm -f sw-description.sig

OS_INFO=""
DEVICE_CODENAME=""
BRANCH_NAME="main"
OS_NAME=""
OS_VERSION=""
BUILD_DESC=""
BUILD_FINGERPRINT=""
BUILD_DATE=""
VERSION_NUMBER=""
BUILD_ID=""

ROOTFS_SQUASHFS=$(find . -maxdepth 1 -name "rootfs*.squashfs*" -o -name "*rootfs*.squashfs*" | head -1)

if [ -n "$ROOTFS_SQUASHFS" ]; then
    echo "Extracting system rootfs..."
    unsquashfs -f -d "system-rootfs" "$ROOTFS_SQUASHFS" 2>&1 | grep -v "write_xattr" > /dev/null
    chown -R $ACTUAL_USER:$ACTUAL_USER "system-rootfs"
    rm -f "$ROOTFS_SQUASHFS"
    
    if [ -f "system-rootfs/etc/os-release" ]; then
        source "system-rootfs/etc/os-release"
        OS_NAME="$NAME"
        OS_VERSION="$OS_VERSION"
        BUILD_DESC="$BUILD_DESC"
        BUILD_FINGERPRINT="$BUILD_FINGERPRINT"
        BUILD_DATE="$BUILD_DATE"
        VERSION_NUMBER="$VERSION_NUMBER"
        
        BUILD_ID=$(echo "$BUILD_FINGERPRINT" | grep -oP '\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        
        OS_INFO="OS: $OS_NAME $OS_VERSION ($BRANCH_CODE)
Build: $BUILD_DESC
Fingerprint: $BUILD_FINGERPRINT
Date: $BUILD_DATE
Version: $VERSION_NUMBER"
        
        DEVICE_CODENAME=$(basename "$ROOTFS_SQUASHFS" | grep -oP 'rootfs-\K[^.]+')
        [ -z "$DEVICE_CODENAME" ] && DEVICE_CODENAME=$(echo "$BUILD_FINGERPRINT" | grep -oP '/\K[^:]+' | head -1)
        [ -n "$DEVICE_CODENAME" ] && [ -n "$BUILD_ID" ] && BRANCH_NAME="${DEVICE_CODENAME}-${BUILD_ID}"
        
        [ -z "$REPO_NAME" ] && [ -n "$DEVICE_CODENAME" ] && REPO_NAME="${DEVICE_CODENAME}_dump"
    fi
    
    find "system-rootfs" -type f -size +50M -exec zstd -19 --rm {} \; 2>/dev/null
    
    git add "system-rootfs"
    git commit -q -m "${DEVICE_CODENAME}: Import system rootfs

$OS_INFO"
fi

for squashfs_file in *.squashfs*; do
    [ -f "$squashfs_file" ] || continue
    [[ "$squashfs_file" == *"rootfs"* ]] && continue
    
    if [[ "$squashfs_file" == *"vendor"* ]]; then
        echo "Extracting vendor rootfs..."
        unsquashfs -f -d "vendor-rootfs" "$squashfs_file" 2>&1 | grep -v "write_xattr" > /dev/null
        chown -R $ACTUAL_USER:$ACTUAL_USER "vendor-rootfs"
        rm -f "$squashfs_file"
        
        find "vendor-rootfs" -type f -size +50M -exec zstd -19 --rm {} \; 2>/dev/null
        
        git add "vendor-rootfs"
        git commit -q -m "${DEVICE_CODENAME}: Import vendor rootfs

$OS_INFO"
    else
        echo "Extracting $(basename $squashfs_file)..."
        base_name=$(basename "$squashfs_file" | sed 's/\.squashfs.*//')
        unsquashfs -f -d "${base_name}" "$squashfs_file" 2>&1 | grep -v "write_xattr" > /dev/null
        chown -R $ACTUAL_USER:$ACTUAL_USER "${base_name}"
        rm -f "$squashfs_file"
        
        find "${base_name}" -type f -size +50M -exec zstd -19 --rm {} \; 2>/dev/null
        
        git add "${base_name}"
        git commit -q -m "${DEVICE_CODENAME}: Import ${base_name}

$OS_INFO"
    fi
done

if [ -f "boot.img" ]; then
    echo "Extracting boot..."
    mkdir -p boot
    
    dumpimage -l boot.img > boot/fit-info.txt 2>/dev/null
    dumpimage -T flat_dt -p 0 -o boot/kernel boot.img > /dev/null 2>&1
    dumpimage -T flat_dt -p 1 -o boot/ramdisk.gz boot.img > /dev/null 2>&1
    dumpimage -T flat_dt -p 2 -o boot/device-tree.dtb boot.img > /dev/null 2>&1
    
    [ -f boot/ramdisk.gz ] && gunzip -f boot/ramdisk.gz 2>/dev/null
    [ -f boot/device-tree.dtb ] && dtc -I dtb -O dts -o boot/device-tree.dts boot/device-tree.dtb 2>/dev/null
    
    if [ -f boot/ramdisk ]; then
        mkdir -p boot/ramdisk-extracted
        cd boot/ramdisk-extracted
        cpio -idv < ../ramdisk 2>/dev/null
        cd ../..
    fi
    
    chown -R $ACTUAL_USER:$ACTUAL_USER boot
    git add boot
    git commit -q -m "${DEVICE_CODENAME}: Import kernel and boot

$OS_INFO"
fi

echo "Organizing files..."
mkdir -p install-scripts firmware

for sh_file in *.sh; do
    [ -f "$sh_file" ] && mv "$sh_file" install-scripts/
done

for bin_file in *.bin *.img; do
    [ -f "$bin_file" ] && mv "$bin_file" firmware/
done

[ -d "install-scripts" ] && [ "$(ls -A install-scripts)" ] && git add install-scripts
[ -d "firmware" ] && [ "$(ls -A firmware)" ] && git add firmware

cat > README.md << EOF
## Device Information
- **Codename**: ${DEVICE_CODENAME:-Unknown}
- **OS Name**: ${OS_NAME:-Unknown}
- **OS Version**: ${OS_VERSION:-Unknown}
- **Build**: ${BUILD_DESC:-Unknown}
- **Build Fingerprint**: ${BUILD_FINGERPRINT:-Unknown}
- **Build Date**: ${BUILD_DATE:-Unknown}
- **Version Number**: ${VERSION_NUMBER:-Unknown}

> [!NOTE]
> Large files (>50MB) have been compressed with zstd. Decompress with: \`zstd -d <file>.zst\`
EOF

git add README.md
git add .
git commit -q -m "${DEVICE_CODENAME}: Import remaining files

$OS_INFO"

if [ -n "$BRANCH_NAME" ] && [ "$BRANCH_NAME" != "main" ]; then
    git branch -m "$BRANCH_NAME"
fi

chown -R $ACTUAL_USER:$ACTUAL_USER .

if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USER" ] && [ -n "$REPO_NAME" ]; then
    echo "Creating GitHub repository..."
    
    curl -s -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        https://api.github.com/user/repos \
        -d "{\"name\":\"$REPO_NAME\",\"private\":false}" > /dev/null 2>&1
    
    echo "Pushing to GitHub..."
    git remote add origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git" 2>/dev/null
    git push -u origin "$BRANCH_NAME" --force -q
    
    echo "Pushed to: https://github.com/${GITHUB_USER}/${REPO_NAME}"
fi

echo "Done: $OUTPUT_DIR (branch: $BRANCH_NAME, repo: $REPO_NAME)"
