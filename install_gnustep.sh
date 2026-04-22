set -e

if [ -f /usr/lib/dyld ]
then
    echo "You're running on macOS, you don't need this"
    exit 1
fi

# Detect requirements

if ! command -v clang >/dev/null 2>&1
then
    echo "clang is not installed, use your package manager to install it first (Debian: sudo apt install clang)"
    exit 1
fi

if ! command -v pkg-config >/dev/null 2>&1
then
    echo "pkg-config is not installed, use your package manager to install it first (Debian: sudo apt install pkg-config)"
    exit 1
fi

if ! pkg-config icu-i18n 2>&1
then
    echo "libicu development package is not installed, use your package manager to install it first (Debian: sudo apt install libicu-dev)"
    exit 1
fi

if ! pkg-config libcurl 2>&1
then
    echo "libicu development package is not installed, use your package manager to install it first (Debian: sudo apt install libcurl4-openssl-dev)"
    exit 1
fi

if ! command -v git >/dev/null 2>&1
then
    echo "git is not installed, use your package manager to install it first (Debian: sudo apt install git)"
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1
then
    echo "cmake is not installed, use your package manager to install it first (Debian: sudo apt install cmake)"
    exit 1
fi

if ! command -v make >/dev/null 2>&1
then
    echo "make is not installed, use your package manager to install it first (Debian: sudo apt install make)"
    exit 1
fi

export CC=clang # Force Clang, you can't build ARC Objective-C with GCC

rm -rf GNUstep
mkdir GNUstep
cd GNUstep

# We'll "install" GNUstep base and make-tools here
mkdir root

# Clone required repos
git clone -c advice.detachedHead=false --depth 1 --branch v2.2 https://github.com/gnustep/libobjc2.git
git clone https://github.com/gnustep/tools-make.git
git clone -c advice.detachedHead=false --depth 1 --branch base-1_31_1 https://github.com/gnustep/base.git

cd libobjc2
mkdir build
cd build
cmake -DCMAKE_C_COMPILER=`which clang` -DCMAKE_CXX_COMPILER=`which clang++` .. -DCMAKE_BUILD_TYPE=Release -DTESTS=OFF
make -sj

echo "Objective-C's runtime built successully, enter your password to install it"
sudo make install

cd ../../tools-make

./configure --prefix=`realpath ../root` --with-layout=gnustep
make
make install

cd ../base
. ../root/System/Library/Makefiles/GNUstep.sh
LDFLAGS="-Wl,-rpath,/usr/local/lib -L/usr/local/lib" ./configure --disable-tls --disable-xslt
make -sj install

cd ../..

mv GNUstep/root/Local/Library/Headers GNUstepHeaders
echo "GNUstep's Foundation framework built successully, enter your password to install it"
sudo install GNUstep/root/Local/Library/Libraries/lib* /usr/local/lib/

rm -rf GNUstep