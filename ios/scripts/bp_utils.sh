#!/bin/bash
#
# signinhub-ios / scripts/bp_utils.sh
#
# 基于 beeware/Python-Apple-support 的 Python.xcframework/build/utils.sh 改写：
#   1. 只保留 iOS 设备/模拟器分支（我们只出 arm64 真机包）。
#   2. 签名改成 ad-hoc（`codesign -s -`）：CI 上没有证书，产物是未签名 IPA，
#      由用户用 TrollStore 在设备上重签安装。
#   3. 加了必要的日志与存在性检查，构建失败时能一眼看出卡在哪。
#
# 作用：把 xcframework 里的 CPython 标准库铺进 .app/python/lib，
#      并把 lib-dynload 下每个 .so 转成 iOS 允许加载的 .framework
#      （Python 侧由 AppleFrameworkLoader + .fwork 指针自动寻址）。
#
# 由 Xcode Build Phase 调用：
#   source "$SRCROOT/scripts/bp_utils.sh"
#   install_python "Python.xcframework"
#

# 注意：这里不能 `set -u`，Xcode 环境里有大量可能未定义的变量。

install_stdlib() {
    PYTHON_XCFRAMEWORK_PATH="$1"
    mkdir -p "$CODESIGNING_FOLDER_PATH/python/lib"

    if [ "$EFFECTIVE_PLATFORM_NAME" = "-iphonesimulator" ]; then
        if [ -d "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/ios-arm64-simulator" ]; then
            SLICE_FOLDER="ios-arm64-simulator"
        else
            SLICE_FOLDER="ios-arm64_x86_64-simulator"
        fi
    else
        SLICE_FOLDER="ios-arm64"
    fi
    echo "[bp_utils] slice=$SLICE_FOLDER archs=$ARCHS"

    if [ -d "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/lib" ]; then
        # 通用 stdlib（lib/python3.11/*.py）+ 架构相关部分（lib-arm64/python3.11/lib-dynload/*.so）
        rsync -a --delete "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/lib/" \
            "$CODESIGNING_FOLDER_PATH/python/lib/" --exclude 'libpython*.dylib'
        rsync -a "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/$SLICE_FOLDER/lib-$ARCHS/" \
            "$CODESIGNING_FOLDER_PATH/python/lib/" --exclude 'libpython*.dylib'
    else
        rsync -a --delete "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/$SLICE_FOLDER/lib/" \
            "$CODESIGNING_FOLDER_PATH/python/lib/" --exclude 'libpython*.dylib'
    fi
}

install_dylib() {
    PYTHON_XCFRAMEWORK_PATH="$1"
    INSTALL_BASE="$2"
    FULL_EXT="$3"

    EXT=$(basename "$FULL_EXT")
    MODULE_PATH=$(dirname "$FULL_EXT")
    MODULE_NAME=$(echo "$EXT" | cut -d "." -f 1)
    RELATIVE_EXT=${FULL_EXT#$CODESIGNING_FOLDER_PATH/}
    PYTHON_EXT=${RELATIVE_EXT/$INSTALL_BASE/}
    FULL_MODULE_NAME=$(echo "$PYTHON_EXT" | cut -d "." -f 1 | tr "/" ".")
    FRAMEWORK_BUNDLE_ID=$(echo "$PRODUCT_BUNDLE_IDENTIFIER.$FULL_MODULE_NAME" | tr "_" "-")
    FRAMEWORK_FOLDER="Frameworks/$FULL_MODULE_NAME.framework"

    if [ ! -d "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER" ]; then
        mkdir -p "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER"
        cp "$PROJECT_DIR/$PYTHON_XCFRAMEWORK_PATH/build/${PLATFORM_FAMILY_NAME}-dylib-Info-template.plist" \
            "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
        plutil -replace CFBundleExecutable -string "$FULL_MODULE_NAME" \
            "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
        plutil -replace CFBundleIdentifier -string "$FRAMEWORK_BUNDLE_ID" \
            "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/Info.plist"
    fi

    mv "$FULL_EXT" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME"
    # 在原 .so 位置留一个 .fwork 指针，内容是 framework 内二进制的相对路径
    echo "$FRAMEWORK_FOLDER/$FULL_MODULE_NAME" > "${FULL_EXT%.so}.fwork"
    # framework 内留一个 .origin 反指回原 .so 位置（模块 __file__ 用）
    echo "${RELATIVE_EXT%.so}.fwork" > "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME.origin"

    if [ -e "$MODULE_PATH/$MODULE_NAME.xcprivacy" ]; then
        cp "$MODULE_PATH/$MODULE_NAME.xcprivacy" \
            "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/PrivacyInfo.xcprivacy"
    fi

    # ad-hoc 签名（无证书场景）；失败不致命，TrollStore 安装时会重签。
    /usr/bin/codesign --force --sign - --timestamp=none \
        "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER" >/dev/null 2>&1 \
        || echo "[bp_utils] WARN ad-hoc sign failed: $FRAMEWORK_FOLDER"
}

process_dylibs() {
    PYTHON_XCFRAMEWORK_PATH="$1"
    LIB_PATH="$2"
    COUNT=0
    while IFS= read -r FULL_EXT; do
        [ -z "$FULL_EXT" ] && continue
        install_dylib "$PYTHON_XCFRAMEWORK_PATH" "$LIB_PATH/" "$FULL_EXT"
        COUNT=$((COUNT + 1))
    done <<< "$(find "$CODESIGNING_FOLDER_PATH/$LIB_PATH" -name "*.so" 2>/dev/null)"
    echo "[bp_utils] converted $COUNT .so -> .framework under $LIB_PATH"
}

install_python() {
    PYTHON_XCFRAMEWORK_PATH="$1"
    shift || true

    install_stdlib "$PYTHON_XCFRAMEWORK_PATH"
    PYTHON_VER=$(ls -1 "$CODESIGNING_FOLDER_PATH/python/lib" | grep -E "^python3\.[0-9]+$" | head -n 1)
    if [ -z "$PYTHON_VER" ]; then
        echo "[bp_utils] ERROR: 没找到 python/lib/python3.x，install_stdlib 失败"
        exit 1
    fi
    echo "[bp_utils] stdlib version = $PYTHON_VER"
    process_dylibs "$PYTHON_XCFRAMEWORK_PATH" "python/lib/$PYTHON_VER/lib-dynload"

    for package_path in "$@"; do
        echo "[bp_utils] processing extra package: $package_path"
        process_dylibs "$PYTHON_XCFRAMEWORK_PATH" "$package_path"
    done

    echo "[bp_utils] python runtime installed at $CODESIGNING_FOLDER_PATH/python"
}
