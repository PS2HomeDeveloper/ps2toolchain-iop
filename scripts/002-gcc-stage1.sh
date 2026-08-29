#!/bin/bash
# 002-gcc-stage1.sh by ps2dev developers

## Exit with code 1 when any command executed returns a non-zero exit code.
onerr()
{
  exit 1;
}
trap onerr ERR

## Read information from the configuration file.
source "$(dirname "$0")/../config/ps2toolchain-iop-config.sh"

## Download the source code.
REPO_URL="$PS2TOOLCHAIN_IOP_GCC_REPO_URL"
REPO_REF="$PS2TOOLCHAIN_IOP_GCC_DEFAULT_REPO_REF"
REPO_FOLDER="$(s="$REPO_URL"; s=${s##*/}; printf "%s" "${s%.*}")"

# Checking if a specific Git reference has been passed in parameter $1
if test -n "$1"; then
  REPO_REF="$1"
  printf 'Using specified repo reference %s\n' "$REPO_REF"
fi

if test ! -d "$REPO_FOLDER"; then
  git clone --depth 1 -b "$REPO_REF" "$REPO_URL" "$REPO_FOLDER"
else
  git -C "$REPO_FOLDER" remote set-url origin "$REPO_URL"
  git -C "$REPO_FOLDER" fetch origin "$REPO_REF" --depth=1
  git -C "$REPO_FOLDER" checkout -f FETCH_HEAD
fi

cd "$REPO_FOLDER"

TARGET="mipsel-none-elf"
TARGET_ALIAS="iop"
TARG_XTRA_OPTS=""
TARGET_CFLAGS="-O2 -gdwarf-2 -gz"
OSVER=$(uname)

## If using MacOS Apple, set gmp, mpfr and mpc paths using TARG_XTRA_OPTS
## (this is needed for Apple Silicon but we will do it for all MacOS systems)
if [ "$(uname -s)" = "Darwin" ]; then
  ## Check if using brew
  if command -v brew &> /dev/null; then
    TARG_XTRA_OPTS="--with-system-zlib --with-gmp=$(brew --prefix gmp) --with-mpfr=$(brew --prefix mpfr) --with-mpc=$(brew --prefix libmpc)"
  elif command -v port &> /dev/null; then
  ## Check if using MacPorts
    MACPORT_BASE=$(dirname $(port -q contents gmp|grep gmp.h)|sed s#/include##g)
    printf 'Macport base is %s\n' "$MACPORT_BASE"
    TARG_XTRA_OPTS="--with-system-zlib --with-libiconv_prefix=$MACPORT_BASE --with-gmp=$MACPORT_BASE --with-mpfr=$MACPORT_BASE --with-mpc=$MACPORT_BASE"
  fi
fi

## Determine the maximum number of processes that Make can work with.
PROC_NR=$(getconf _NPROCESSORS_ONLN)

## ------------------------------------------------------------------
## STEP A: Build a NATIVE copy of GCC stage1 (runs on the CI machine).
## GCC's own build needs to EXECUTE "mipsel-none-elf-gcc" internally
## (to generate its "specs" file). Since the Android copy cannot run
## here, we build a native copy first and put it on PATH ahead of the
## Android one (see compilation.yml). This native copy is not shipped.
## ------------------------------------------------------------------
if [ -n "$NATIVE_PS2DEV" ]; then
  rm -rf "build-$TARGET-stage1-native"
  mkdir "build-$TARGET-stage1-native"
  cd "build-$TARGET-stage1-native"

  CC=gcc CXX=g++ AR=ar AS=as LD=ld RANLIB=ranlib STRIP=strip NM=nm \
  CFLAGS_FOR_TARGET="$TARGET_CFLAGS" \
  CXXFLAGS_FOR_TARGET="$TARGET_CFLAGS" \
  ../configure \
    --quiet \
    --prefix="$NATIVE_PS2DEV/$TARGET_ALIAS" \
    --target="$TARGET" \
    --enable-languages="c,c++" \
    --with-float=soft \
    --with-headers=no \
    --without-newlib \
    --without-cloog \
    --without-ppl \
    --disable-decimal-float \
    --disable-libada \
    --disable-libatomic \
    --disable-libffi \
    --disable-libgomp \
    --disable-libmudflap \
    --disable-libquadmath \
    --disable-libssp \
    --disable-libstdcxx-pch \
    --disable-multilib \
    --disable-shared \
    --disable-threads \
    --disable-target-libiberty \
    --disable-target-zlib \
    --disable-nls \
    --disable-tls \
    --disable-libstdcxx

  make --quiet -j "$PROC_NR" all
  make --quiet -j "$PROC_NR" install-strip
  make --quiet -j "$PROC_NR" clean

  cd ..
fi

## ------------------------------------------------------------------
## STEP B: Build the FINAL Android copy of GCC (what gets shipped).
## ------------------------------------------------------------------

## Create and enter the toolchain/build directory
rm -rf "build-$TARGET-stage1"
mkdir "build-$TARGET-stage1"
cd "build-$TARGET-stage1"

HOST_OPTS=""
if [ -n "$CONFIGURE_HOST" ]; then
  HOST_OPTS="--host=$CONFIGURE_HOST"
fi

## GCC's own build needs to EXECUTE the target compiler/assembler/linker
## internally (e.g. to generate its "specs" file) DURING the build itself,
## using an in-tree reference — not a PATH lookup. GCC has an official
## configure option made exactly for this situation in a real Canadian
## Cross build: --with-build-time-tools=DIR tells it to use already-built,
## natively-runnable tools from DIR instead of trying to run itself.
BUILD_TIME_TOOLS_OPTS=""
if [ -n "$NATIVE_PS2DEV" ] && [ -d "$NATIVE_PS2DEV/$TARGET_ALIAS/bin" ]; then
  BUILD_TIME_TOOLS_OPTS="--with-build-time-tools=$NATIVE_PS2DEV/$TARGET_ALIAS/bin"
fi

## --with-build-time-tools alone does not cover GCC's early "checking
## assembler for ... support" feature-detection tests, which still look
## inside "$prefix/$target/bin" (Android, cannot execute here) unless
## explicitly told otherwise via these _FOR_TARGET variables.
FOR_TARGET_OPTS=""
if [ -n "$NATIVE_PS2DEV" ] && [ -x "$NATIVE_PS2DEV/$TARGET_ALIAS/bin/$TARGET-as" ]; then
  FOR_TARGET_OPTS="AS_FOR_TARGET=$NATIVE_PS2DEV/$TARGET_ALIAS/bin/$TARGET-as"
  FOR_TARGET_OPTS="$FOR_TARGET_OPTS LD_FOR_TARGET=$NATIVE_PS2DEV/$TARGET_ALIAS/bin/$TARGET-ld"
  FOR_TARGET_OPTS="$FOR_TARGET_OPTS AR_FOR_TARGET=$NATIVE_PS2DEV/$TARGET_ALIAS/bin/$TARGET-ar"
  FOR_TARGET_OPTS="$FOR_TARGET_OPTS RANLIB_FOR_TARGET=$NATIVE_PS2DEV/$TARGET_ALIAS/bin/$TARGET-ranlib"
  FOR_TARGET_OPTS="$FOR_TARGET_OPTS NM_FOR_TARGET=$NATIVE_PS2DEV/$TARGET_ALIAS/bin/$TARGET-nm"
  FOR_TARGET_OPTS="$FOR_TARGET_OPTS OBJDUMP_FOR_TARGET=$NATIVE_PS2DEV/$TARGET_ALIAS/bin/$TARGET-objdump"
  FOR_TARGET_OPTS="$FOR_TARGET_OPTS READELF_FOR_TARGET=$NATIVE_PS2DEV/$TARGET_ALIAS/bin/$TARGET-readelf"
fi
if [ -n "$NATIVE_PS2DEV" ] && [ -x "$NATIVE_PS2DEV/$TARGET_ALIAS/bin/$TARGET-gcc" ]; then
  FOR_TARGET_OPTS="$FOR_TARGET_OPTS GCC_FOR_TARGET=$NATIVE_PS2DEV/$TARGET_ALIAS/bin/$TARGET-gcc"
fi

## Configure the build.
## -fno-char8_t keeps u8"..." literals as `const char[]` so libcody builds
## under host compilers that default to C++20 or later (e.g. GCC 16).
CC="$CC -fPIC -Wl,--no-relax" \
CXX="$CXX -fPIC -Wl,--no-relax" \
CFLAGS_FOR_TARGET="$TARGET_CFLAGS" \
CXXFLAGS_FOR_TARGET="$TARGET_CFLAGS" \
CXXFLAGS="-g -O1 -fno-char8_t" \
CXXFLAGS_FOR_BUILD="-g -O2 -fno-char8_t" \
../configure \
  --quiet \
  --prefix="$PS2DEV/$TARGET_ALIAS" \
  --target="$TARGET" \
  --enable-languages="c,c++" \
  --with-float=soft \
  --with-headers=no \
  --without-newlib \
  --without-cloog \
  --without-ppl \
  --disable-decimal-float \
  --disable-libada \
  --disable-libatomic \
  --disable-libffi \
  --disable-libgomp \
  --disable-libmudflap \
  --disable-libquadmath \
  --disable-libssp \
  --disable-libstdcxx-pch \
  --disable-multilib \
  --disable-shared \
  --disable-threads \
  --disable-target-libiberty \
  --disable-target-zlib \
  --disable-nls \
  --disable-tls \
  --disable-libstdcxx \
  --with-gmp="$ANDROID_DEPS_PREFIX" \
  --with-mpfr="$ANDROID_DEPS_PREFIX" \
  --with-mpc="$ANDROID_DEPS_PREFIX" \
  $HOST_OPTS \
  $TARG_XTRA_OPTS \
  $BUILD_TIME_TOOLS_OPTS \
  $FOR_TARGET_OPTS \
  CC_FOR_BUILD=/usr/bin/gcc \
  CXX_FOR_BUILD=/usr/bin/g++

## Compile and install.
make --quiet -j "$PROC_NR" all
make --quiet -j "$PROC_NR" install-strip
make --quiet -j "$PROC_NR" clean

## Exit the build directory.
cd ..
