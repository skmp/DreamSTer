#!/bin/bash
set -e
test $1 || (echo "Usage $0 <release number>" && exit)

cp Scripts/DreamSTer.sh dist/Scripts
cp polly2-rtl/quartus/polly2/output_files/polly2.rbf dist/minicast/polly2-rtl.rbf
cd minicast
./build.sh
cd ..
cp minicast/build/minicast.elf dist/minicast/minicast.elf
cd dist
rm "DreamSTer-r$1.zip" || true
zip -r "DreamSTer-r$1.zip" Scripts/ minicast/
echo Made release DreamSTer-r$1.zip
