#!/bin/bash
set -e
test $1 || (echo "Usage $0 <release number>" && exit)

# mem_wc.ko is not built here: it needs a prepared MiSTer kernel tree
MEM_WC_KO=mister-utils/mem_wc/mem_wc.ko
if [ ! -f "$MEM_WC_KO" ]; then
    echo "$MEM_WC_KO is missing; build it first:"
    echo "  make -C mister-utils/mem_wc KDIR=<MiSTer kernel tree> LOCALVERSION= KBUILD_MODPOST_WARN=1"
    exit 1
fi

cp Scripts/DreamSTer.sh dist/Scripts
cp polly2-rtl/quartus/polly2/output_files/polly2.rbf dist/minicast/polly2-rtl.rbf
cd minicast
./build.sh
cd ..
cp minicast/build/minicast.elf dist/minicast/minicast.elf

# MiSTer helpers from the mister-utils submodule, built outside its tree so
# the submodule stays clean
UTILS_BUILD=$(mktemp -d)
trap 'rm -rf "$UTILS_BUILD"' EXIT
for tool in load_fpga_bitstream setup_hdmi; do
    cmake -DCMAKE_TOOLCHAIN_FILE="$PWD/mister-utils/$tool/toolchain.cmake" \
          -S "mister-utils/$tool" -B "$UTILS_BUILD/$tool"
    cmake --build "$UTILS_BUILD/$tool" --parallel
    cp "$UTILS_BUILD/$tool/$tool" "dist/minicast/$tool"
done
cp "$MEM_WC_KO" dist/minicast/mem_wc.ko

cd dist
rm "DreamSTer-r$1.zip" || true
zip -r "DreamSTer-r$1.zip" Scripts/ minicast/
echo Made release DreamSTer-r$1.zip
