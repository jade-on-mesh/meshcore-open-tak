// MeshCore Open TAK - AEIC's model-stage runner for Windows, where there is no
// fork(): each stage runs in this process instead of a child. Same interface
// and checks as mikecarper/AEIC mobile/native/recovery.cpp (shape, finite
// values, output byte limit), without the crash containment a child gives,
// which a desktop's memory doesn't need. tool/build_aeic_hd_desktop.sh builds
// it in place of recovery.cpp on Windows.

#include "recovery.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <utility>

namespace aeic_recovery {
namespace {

class InvalidTensor : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

std::uint64_t monotonic_ms() {
    using namespace std::chrono;
    return std::uint64_t(duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count());
}

bool same(Shape a, Shape b) { return a.c == b.c && a.h == b.h && a.w == b.w; }
bool finite(const std::vector<float>& values) {
    return std::all_of(values.begin(), values.end(), [](float value) { return std::isfinite(value); });
}

} // namespace

bool checked_elements(Shape shape, std::size_t max_bytes, std::size_t& elements,
                      std::string& reason) {
    elements = 0;
    if (shape.c <= 0 || shape.h <= 0 || shape.w <= 0 || max_bytes < sizeof(float)) {
        reason = "non-positive tensor dimension or insufficient byte limit";
        return false;
    }
    std::size_t count = 1;
    for (int dimension : {shape.c, shape.h, shape.w}) {
        const auto value = std::size_t(dimension);
        if (value > std::numeric_limits<std::size_t>::max() / count) {
            reason = "tensor element-count overflow";
            return false;
        }
        count *= value;
    }
    if (count > max_bytes / sizeof(float)) {
        reason = "tensor exceeds recovery output byte limit";
        return false;
    }
    elements = count;
    reason.clear();
    return true;
}

const char* status_name(Status status) {
    switch (status) {
        case Status::Success: return "success";
        case Status::InvalidRequest: return "invalid_request";
        case Status::SetupFailure: return "setup_failure";
        case Status::ChildException: return "child_exception";
        case Status::InvalidOutput: return "invalid_output";
        case Status::ChildSignal: return "child_signal";
        case Status::ChildExit: return "child_exit";
        case Status::Timeout: return "timeout";
        case Status::WaitFailure: return "wait_failure";
    }
    return "unknown";
}

SharedResult run_isolated_shared(
    Shape expected, const Options& options,
    const std::function<void(float*, std::size_t)>& child_work) {
    SharedResult shared;
    Result& result = shared.result;
    std::size_t count = 0;
    if (!checked_elements(expected, options.max_output_bytes, count, result.reason)) return shared;
    if (!child_work || !options.timeout_ms || !options.poll_ms) {
        result.reason = "callback, finite deadline, and positive poll interval are required";
        return shared;
    }
    std::shared_ptr<std::vector<float>> buffer;
    try {
        buffer = std::make_shared<std::vector<float>>(count);
    } catch (const std::exception& error) {
        result.status = Status::SetupFailure;
        result.reason = error.what();
        return shared;
    }
    float* payload = buffer->data();
    const std::uint64_t start = monotonic_ms();
    try {
        if (options.initialize_output)
            std::fill(payload, payload + count, std::numeric_limits<float>::quiet_NaN());
        child_work(payload, count);
    } catch (const InvalidTensor& error) {
        result.status = Status::InvalidOutput;
        result.reason = error.what();
        return shared;
    } catch (const std::exception& error) {
        result.status = Status::ChildException;
        result.reason = error.what();
        return shared;
    } catch (...) {
        result.status = Status::ChildException;
        result.reason = "stage threw an unknown exception";
        return shared;
    }
    result.elapsed_ms = monotonic_ms() - start;
    if (!std::all_of(payload, payload + count, [](float value) { return std::isfinite(value); })) {
        result.status = Status::InvalidOutput;
        result.reason = "stage returned incomplete or non-finite output values";
        return shared;
    }
    shared.owner = buffer;
    shared.values = payload;
    shared.elements = count;
    shared.shape = expected;
    result.status = Status::Success;
    result.exit_code = 0;
    return shared;
}

Result run_isolated(Shape expected, const Options& options,
                    const std::function<Tensor()>& child_work) {
    if (!child_work) {
        Result result;
        result.reason = "callback, finite deadline, and positive poll interval are required";
        return result;
    }
    SharedResult shared = run_isolated_shared(expected, options,
        [&](float* target, std::size_t count) {
            Tensor tensor = child_work();
            if (!same(tensor.shape, expected) || tensor.values.size() != count)
                throw InvalidTensor("child returned wrong shape or wrong element count");
            std::memcpy(target, tensor.values.data(), count * sizeof(float));
        });
    if (shared.result.ok()) {
        try {
            shared.result.output.shape = expected;
            shared.result.output.values.assign(shared.values, shared.values + shared.elements);
        } catch (const std::exception& error) {
            shared.result.status = Status::SetupFailure;
            shared.result.reason = error.what();
            shared.result.output = Tensor{};
        }
    }
    return std::move(shared.result);
}

Fallback make_fallback(Shape expected, std::size_t max_bytes,
                       const std::vector<Tensor>& inputs, FallbackPolicy policy) {
    Fallback result;
    std::size_t count = 0;
    if (!checked_elements(expected, max_bytes, count, result.reason)) return result;
    const Tensor* exact = nullptr;
    const Tensor* resized = nullptr;
    if (policy == FallbackPolicy::PreserveOrResize) {
        for (const Tensor& tensor : inputs) {
            std::size_t input_count = 0;
            std::string ignored;
            if (tensor.shape.c != expected.c ||
                !checked_elements(tensor.shape, max_bytes, input_count, ignored) ||
                tensor.values.size() != input_count || !finite(tensor.values)) continue;
            if (same(tensor.shape, expected)) { exact = &tensor; break; }
            if (!resized) resized = &tensor;
        }
    }
    try {
        result.output.shape = expected;
        if (exact) {
            result.output.values = exact->values;
            result.strategy = "preserve";
        } else if (resized) {
            result.output.values.resize(count);
            const Shape source = resized->shape;
            for (int c = 0; c < expected.c; ++c)
                for (int y = 0; y < expected.h; ++y)
                    for (int x = 0; x < expected.w; ++x) {
                        const int sy = int(std::uint64_t(y) * source.h / expected.h);
                        const int sx = int(std::uint64_t(x) * source.w / expected.w);
                        const std::size_t out = (std::size_t(c) * expected.h + y) * expected.w + x;
                        const std::size_t in = (std::size_t(c) * source.h + sy) * source.w + sx;
                        result.output.values[out] = resized->values[in];
                    }
            result.strategy = "nearest_resize";
        } else {
            result.output.values.assign(count, 0.f);
            result.strategy = "zeros";
        }
        result.valid = true;
        result.reason = "DEGRADED: substituted model output; lost details are not recoverable";
    } catch (const std::exception& error) {
        result.reason = error.what();
    }
    return result;
}

} // namespace aeic_recovery
