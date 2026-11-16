// MeshCore Open TAK - AI sketch HD on iPhone.
//
// iOS doesn't let an app start a program, so mikecarper/AEIC's codec program
// (`aeic_decode`, which also encodes), which Android and the desktop apps run
// with Process.start, is built into the app here as a library and run on one
// of the app's own threads (lib/vox/aeic_hd_runner_io.dart calls aeic_hd_run
// from a background isolate). tool/build_aeic_hd_ios.sh compiles this file
// with the program's sources, against the same ncnn with the same fast paths
// off, so an iPhone encodes byte-identical to a phone or a computer.
//
// The program's main.cpp is included below with `main` renamed, rather than
// changed: everything it prints still goes to stdout, which aeic_hd_run points
// at a log file for the duration of a job, so the Dart side reads the same
// STAGE_END / ENCODE_COMPLETE / DECODE_COMPLETE lines it reads from a child
// process elsewhere. The build script adds one line to the copy of main.cpp
// it compiles, AEIC_STAGE_HOOK() at the top of each model stage, which is
// where a cancel takes effect (a stage itself can't be stopped part-way).
//
// Each model stage runs in-process (tool/aeic_desktop/recovery_inprocess.cpp,
// as on Windows): there is no fork() for an app. The app only ever runs the
// program without --best-effort, which is the path that doesn't isolate.

#include <atomic>
#include <cstdio>
#include <mutex>
#include <stdexcept>
#include <fcntl.h>
#include <sys/sysctl.h>
#include <unistd.h>

namespace {
std::atomic<bool> g_aeic_hd_cancel{false};
}

static void aeic_hd_stage_hook() {
    if (g_aeic_hd_cancel.load()) throw std::runtime_error("cancelled");
}
#define AEIC_STAGE_HOOK() aeic_hd_stage_hook()

#define main aeic_codec_main
#include "main.cpp"
#undef main

namespace {
std::mutex g_aeic_hd_run;
}

extern "C" {

__attribute__((visibility("default"), used))
int aeic_hd_available(void) { return 1; }

// The phone's RAM in bytes, or 0 when it can't be read.
__attribute__((visibility("default"), used))
unsigned long long aeic_hd_total_memory(void) {
    unsigned long long bytes = 0;
    size_t size = sizeof(bytes);
    if (sysctlbyname("hw.memsize", &bytes, &size, nullptr, 0) != 0) return 0;
    return bytes;
}

// Asks the running job to stop at its next model stage.
__attribute__((visibility("default"), used))
void aeic_hd_cancel(void) { g_aeic_hd_cancel.store(true); }

// Runs the codec program with argv (argv[0] is a name, as for a program),
// its output written to log_path. Returns its exit status: 0 for success.
// One job at a time; a second call waits for the first.
__attribute__((visibility("default"), used))
int aeic_hd_run(int argc, const char** argv, const char* log_path) {
    std::lock_guard<std::mutex> lock(g_aeic_hd_run);
    g_aeic_hd_cancel.store(false);
    recovery_events = 0;
    isolated_peak_kb = 0;

    const int log = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (log < 0) return 126;
    std::fflush(stdout);
    std::fflush(stderr);
    const int saved_out = dup(STDOUT_FILENO);
    const int saved_err = dup(STDERR_FILENO);
    dup2(log, STDOUT_FILENO);
    dup2(log, STDERR_FILENO);
    close(log);

    int status;
    try {
        status = aeic_codec_main(argc, const_cast<char**>(argv));
    } catch (...) {
        std::fprintf(stderr, "AEIC_ERROR uncaught exception\n");
        status = 1;
    }

    std::fflush(stdout);
    std::fflush(stderr);
    if (saved_out >= 0) { dup2(saved_out, STDOUT_FILENO); close(saved_out); }
    if (saved_err >= 0) { dup2(saved_err, STDERR_FILENO); close(saved_err); }
    if (g_aeic_hd_cancel.load()) status = 130;
    return status;
}

}  // extern "C"
