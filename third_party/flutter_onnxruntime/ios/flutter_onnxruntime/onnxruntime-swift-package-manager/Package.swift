// swift-tools-version: 5.9

// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// MeshCore Open TAK: masicai/onnxruntime-swift-package-manager 1.28.0
// (3fb68950a5967c8c120f9f99a1a850a43985a4c9), vendored as a local package for
// flutter_onnxruntime, without the ONNX Runtime Extensions product. Its binary
// came from download.onnxruntime.ai, whose certificate Apple's build machines
// reject (November 2026), which failed every iOS and macOS build; the plugin
// never uses it. The runtime itself still comes from masicai's GitHub release,
// pinned by checksum as before. See third_party/flutter_onnxruntime/VENDORED.md.

import PackageDescription

let package = Package(
    name: "onnxruntime",
    platforms: [.iOS(.v15),
                .macOS(.v14)],
    products: [
        .library(name: "onnxruntime",
                 type: .static,
                 targets: ["OnnxRuntimeBindings"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "OnnxRuntimeBindings",
                dependencies: ["onnxruntime"],
                path: "objectivec",
                exclude: ["ReadMe.md", "format_objc.sh", "test", "docs",
                            "ort_checkpoint.mm",
                            "ort_checkpoint_internal.h",
                            "ort_training_session_internal.h",
                            "ort_training_session.mm",
                            "include/ort_checkpoint.h",
                            "include/ort_training_session.h",
                            "include/onnxruntime_training.h"],
                cxxSettings: [
                    .define("SPM_BUILD"),
                ]),
        // ORT 1.28.0 as a library-format xcframework (masicai's repackaging of
        // Microsoft's pod archive, so App Store validation passes).
        .binaryTarget(name: "onnxruntime",
                      url: "https://github.com/masicai/onnxruntime-swift-package-manager/releases/download/1.28.0/onnxruntime-libs-1.28.0.zip",
                      checksum: "7e031979787f2da0f3ff45d18431db93c4443033020b210413b287a855870c3c"),
    ],
    cxxLanguageStandard: .cxx17
)
