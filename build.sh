#\!/usr/bin/env bash
cd "$(dirname "$0")"
export PATH="/home/ryan/.local/ps4nim/bin:$PATH"
export OO_PS4_TOOLCHAIN="/home/ryan/code/ps4/OpenOrbis/PS4Toolchain"
export app_SERVICE_ID="IV0000-HTOS00002_00-SAVEDATA00000000"
export app_TITLE_ID="HTOS00002"
export app_VERSION="3.01"
export app_TITLE="CECIE Web Queue"
export app_PKG_DIR="pkg"
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
nim build_pkg src/main
