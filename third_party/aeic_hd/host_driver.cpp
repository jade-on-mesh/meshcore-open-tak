// MeshCore Open TAK - a Mac program around the iPhone's in-app AI sketch HD
// codec (aeic_hd_ios.cpp), so CI can run tool/aeic_desktop/self_test.py on
// exactly the code the iPhone app runs: same entry point, same output
// redirection, same in-process model stages. It behaves like the codec
// program: arguments in, the codec's output on stdout, its status out.
// Built by tool/build_aeic_hd_ios.sh with AEIC_HD_HOST_DRIVER=1.

#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>

extern "C" int aeic_hd_run(int argc, const char** argv, const char* log_path);

int main(int argc, char** argv) {
    char log_path[] = "/tmp/aeic_hd_host_XXXXXX";
    const int fd = mkstemp(log_path);
    if (fd < 0) return 125;
    close(fd);
    const int status = aeic_hd_run(argc, const_cast<const char**>(argv), log_path);
    if (FILE* log = std::fopen(log_path, "rb")) {
        char buffer[4096];
        size_t n;
        while ((n = std::fread(buffer, 1, sizeof buffer, log)) > 0) std::fwrite(buffer, 1, n, stdout);
        std::fclose(log);
    }
    std::fflush(stdout);
    unlink(log_path);
    return status;
}
