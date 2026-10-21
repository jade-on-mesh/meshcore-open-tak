cmake_minimum_required(VERSION 3.13)
project(meshcore_codec2 C)

set(CODEC2_ROOT ${CMAKE_CURRENT_LIST_DIR}/../../../../../third_party/codec2)

include(${CMAKE_CURRENT_LIST_DIR}/codec2_sources.cmake)

set(CODEC2_SRC_DIR ${CODEC2_ROOT}/src)

set(CODEC2_SOURCE_FILES "")
foreach(src ${CODEC2_SOURCES})
    list(APPEND CODEC2_SOURCE_FILES ${CODEC2_SRC_DIR}/${src})
endforeach()

add_library(codec2 SHARED ${CODEC2_SOURCE_FILES})

set_target_properties(codec2 PROPERTIES
    OUTPUT_NAME "codec2"
)

target_include_directories(codec2 PUBLIC
    ${CODEC2_ROOT}/src
    ${CODEC2_ROOT}/include
)

target_compile_definitions(codec2 PRIVATE GIT_HASH="Unknown")

if(ANDROID)
    target_compile_options(codec2 PRIVATE -std=gnu11)
endif()

# Math library required on some platforms.
target_link_libraries(codec2 m)

# ---------------------------------------------------------------------------
# MeshCore Open VOX: AV1 still images (libvox_av1.so) on libaom (BSD-2).
# CI builds libaom into third_party/aom-android/<ABI> before the app build
# (see .github/workflows/build.yml). Without it, image messages are disabled.
set(AOM_PREBUILT ${CMAKE_CURRENT_LIST_DIR}/../../../../../third_party/aom-android/${ANDROID_ABI})
if(ANDROID AND EXISTS ${AOM_PREBUILT}/lib/libaom.a)
    add_library(aom_static STATIC IMPORTED)
    set_target_properties(aom_static PROPERTIES
        IMPORTED_LOCATION ${AOM_PREBUILT}/lib/libaom.a)
    add_library(vox_av1 SHARED ${CMAKE_CURRENT_LIST_DIR}/vox_av1.c)
    target_include_directories(vox_av1 PRIVATE ${AOM_PREBUILT}/include)
    target_compile_options(vox_av1 PRIVATE -O2 -std=gnu11)
    target_link_libraries(vox_av1 aom_static m)
    target_link_options(vox_av1 PRIVATE -Wl,--exclude-libs,ALL)
else()
    message(WARNING "libaom not found at ${AOM_PREBUILT}: VOX image messages disabled")
endif()

# ---------------------------------------------------------------------------
# Data over sound (libggwave.so, MIT): share by sound and Wavest-compatible
# messages (lib/sound/).
enable_language(CXX)
set(GGWAVE_ROOT ${CMAKE_CURRENT_LIST_DIR}/../../../../../third_party/ggwave)
add_library(ggwave SHARED ${GGWAVE_ROOT}/src/ggwave.cpp)
target_include_directories(ggwave PRIVATE ${GGWAVE_ROOT}/include ${GGWAVE_ROOT}/src)
target_compile_definitions(ggwave PRIVATE GGWAVE_SHARED GGWAVE_BUILD)
target_compile_options(ggwave PRIVATE -O2 -std=c++17)

