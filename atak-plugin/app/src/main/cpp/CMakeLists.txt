# MeshCore ATAK plugin native codecs (direct-radio mode only; in app mode the
# MeshCore Open TAK app does the encoding).
#
#   libmtak_codecs.so = Codec2 (LGPL-2.1, from ../../third_party/codec2)
#                     + AV1 stills (vox_av1.c, shared with the app, on libaom)
#                     + the JNI shim
#
# libaom is optional: run scripts/build-libaom.sh first (it writes
# third_party/aom-android/<ABI>, the same place the app's CI uses). Without
# it the plugin builds without direct-mode photos.
cmake_minimum_required(VERSION 3.10.2)
project(mtak_codecs C)

set(REPO_ROOT ${CMAKE_CURRENT_LIST_DIR}/../../../../..)
set(CODEC2_ROOT ${REPO_ROOT}/third_party/codec2)
include(${REPO_ROOT}/android/app/src/main/cpp/codec2_sources.cmake)

set(SOURCES ${CMAKE_CURRENT_LIST_DIR}/mtak_jni.c)
foreach(src ${CODEC2_SOURCES})
    list(APPEND SOURCES ${CODEC2_ROOT}/src/${src})
endforeach()

set(AOM_PREBUILT ${REPO_ROOT}/third_party/aom-android/${ANDROID_ABI})
if(EXISTS ${AOM_PREBUILT}/lib/libaom.a)
    list(APPEND SOURCES ${REPO_ROOT}/android/app/src/main/cpp/vox_av1.c)
    set(HAVE_AOM 1)
else()
    message(WARNING "libaom not found for ${ANDROID_ABI}: direct-mode photos disabled")
endif()

add_library(mtak_codecs SHARED ${SOURCES})
target_include_directories(mtak_codecs PRIVATE ${CODEC2_ROOT}/src ${CODEC2_ROOT}/include)
target_compile_definitions(mtak_codecs PRIVATE GIT_HASH="Unknown")
target_compile_options(mtak_codecs PRIVATE -std=gnu11 -O2)
target_link_libraries(mtak_codecs m log)
if(HAVE_AOM)
    add_library(aom_static STATIC IMPORTED)
    set_target_properties(aom_static PROPERTIES IMPORTED_LOCATION ${AOM_PREBUILT}/lib/libaom.a)
    target_include_directories(mtak_codecs PRIVATE ${AOM_PREBUILT}/include)
    target_compile_definitions(mtak_codecs PRIVATE MTAK_HAVE_AOM=1)
    target_link_libraries(mtak_codecs aom_static)
    set_property(TARGET mtak_codecs APPEND_STRING PROPERTY LINK_FLAGS " -Wl,--exclude-libs,ALL")
endif()
