#!/usr/bin/env bash
#
# Rebuild llama.cpp static libraries for ClawD with Metal + multimodal enabled.
#
# Produces these files in deps/lib/:
#   libllama.a, libggml.a, libggml-base.a, libggml-cpu.a, libggml-blas.a,
#   libggml-metal.a, libmtmd.a
#
# And refreshes these headers in deps/include/:
#   llama.h, ggml*.h, gguf.h, mtmd.h, mtmd-helper.h
#
# Usage (run from the project root):
#   ./deps/build_llama.sh
#
# Requires: cmake, clang, git, and Xcode Command Line Tools.

set -euo pipefail

REPO_URL="https://github.com/ggml-org/llama.cpp"
PINNED_COMMIT="d132f22fc92f36848f7ccf2fc9987cd0b0120825"  # 2026-04-09 (tip at the time of this integration)

DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${DEPS_DIR}/llama.cpp-src"
BUILD_DIR="${SRC_DIR}/build"
LIB_DST="${DEPS_DIR}/lib"
INC_DST="${DEPS_DIR}/include"

echo "==> Ensuring llama.cpp source at ${PINNED_COMMIT}"
if [[ ! -d "${SRC_DIR}/.git" ]]; then
    git clone "${REPO_URL}" "${SRC_DIR}"
fi
( cd "${SRC_DIR}" && git fetch --depth 1 origin "${PINNED_COMMIT}" 2>/dev/null || true )
( cd "${SRC_DIR}" && git checkout "${PINNED_COMMIT}" 2>/dev/null || git checkout -q "${PINNED_COMMIT}" )

echo "==> Configuring cmake (Metal + multimodal)"
rm -rf "${BUILD_DIR}"
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=Apple \
    -DGGML_NATIVE=ON \
    -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_COMMON=ON \
    -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_OPENSSL=OFF

echo "==> Building (this can take a while)"
cmake --build "${BUILD_DIR}" --config Release -j "$(sysctl -n hw.ncpu)" \
    --target llama ggml ggml-base ggml-cpu ggml-blas ggml-metal mtmd

echo "==> Installing into deps/lib and deps/include"
mkdir -p "${LIB_DST}" "${INC_DST}"

# Static libs — search under the build tree because cmake scatters them across subdirs
copy_lib() {
    local name="$1"
    local found
    found="$(find "${BUILD_DIR}" -name "${name}" -type f | head -n 1)"
    if [[ -z "${found}" ]]; then
        echo "ERROR: ${name} not found under ${BUILD_DIR}" >&2
        return 1
    fi
    cp -v "${found}" "${LIB_DST}/${name}"
}

copy_lib libllama.a
copy_lib libggml.a
copy_lib libggml-base.a
copy_lib libggml-cpu.a
copy_lib libggml-blas.a
copy_lib libggml-metal.a
copy_lib libmtmd.a

# Headers — llama public includes + ggml headers + mtmd
cp -v "${SRC_DIR}/include/llama.h"        "${INC_DST}/llama.h"
cp -v "${SRC_DIR}/include/llama-cpp.h"    "${INC_DST}/llama-cpp.h"

for h in "${SRC_DIR}/ggml/include/"*.h; do
    cp -v "${h}" "${INC_DST}/"
done

cp -v "${SRC_DIR}/tools/mtmd/mtmd.h"        "${INC_DST}/mtmd.h"
cp -v "${SRC_DIR}/tools/mtmd/mtmd-helper.h" "${INC_DST}/mtmd-helper.h"

echo
echo "==> Done."
echo "    Libs   -> ${LIB_DST}"
echo "    Inc    -> ${INC_DST}"
echo "    Pinned -> ${PINNED_COMMIT}"
