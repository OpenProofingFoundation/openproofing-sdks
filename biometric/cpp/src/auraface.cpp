#if defined(__clang__)
#pragma clang fp contract(off)
#endif
#include "kenshiki/auraface.hpp"
#include "auraface_runtime.hpp"
#if __has_include(<onnxruntime_cxx_api.h>)
#include <onnxruntime_cxx_api.h>
#else
#include <onnxruntime/onnxruntime_cxx_api.h>
#endif
#include <algorithm>
#include <cmath>
#include <cfenv>
#include <cstring>

#if defined(__FAST_MATH__)
#error "AuraFace requires IEEE floating-point semantics"
#endif
static_assert(ORT_API_VERSION == 22, "ONNX Runtime 1.22 headers required");

namespace kenshiki::auraface {
namespace {
constexpr std::string_view weight_sha256 = "a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60";
EmbeddingSpace space() {
    return EmbeddingSpace(std::string(artifact_manifest_sha256()), EmbeddingDomain::face_identity,
                          feature_count, 1e-12);
}
std::vector<std::byte> copy_model(std::span<const std::byte> model, bool pinned) {
    if (model.empty() || model.size() > model_size || (pinned && model.size() != model_size)) {
        throw Error(Failure::artifact_size);
    }
    std::vector<std::byte> owned(model.begin(), model.end());
    if (pinned && sha256(owned) != weight_sha256) throw Error(Failure::artifact_integrity);
    return owned;
}
void check_metadata(Ort::Session& session) {
    if (session.GetInputCount() != 1 || session.GetOutputCount() != 1 ||
        session.GetOverridableInitializerCount() != 0) throw Error(Failure::model_metadata);
    Ort::AllocatorWithDefaultOptions allocator;
    const auto input_name = session.GetInputNameAllocated(0, allocator);
    const auto output_name = session.GetOutputNameAllocated(0, allocator);
    const auto input_info = session.GetInputTypeInfo(0);
    const auto output_info = session.GetOutputTypeInfo(0);
    if (std::strcmp(input_name.get(), "data") != 0 || std::strcmp(output_name.get(), "1333") != 0 ||
        input_info.GetONNXType() != ONNX_TYPE_TENSOR || output_info.GetONNXType() != ONNX_TYPE_TENSOR) {
        throw Error(Failure::model_metadata);
    }
    const auto input = input_info.GetTensorTypeAndShapeInfo();
    const auto output = output_info.GetTensorTypeAndShapeInfo();
    if (input.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
        output.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
        input.GetShape() != std::vector<std::int64_t>{-1, 3, 112, 112} ||
        output.GetShape() != std::vector<std::int64_t>{1, 512}) throw Error(Failure::model_metadata);
}
} // namespace

class detail::Engine::Impl final {
public:
    explicit Impl(std::vector<std::byte> model)
        : owned(std::move(model)), env(ORT_LOGGING_LEVEL_FATAL, "kenshiki_inference") {
        env.DisableTelemetryEvents();
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(1);
        options.SetInterOpNumThreads(1);
        options.SetExecutionMode(ORT_SEQUENTIAL);
        options.SetGraphOptimizationLevel(ORT_ENABLE_ALL);
        session = Ort::Session(env, owned.data(), owned.size(), options);
        check_metadata(session);
    }
    std::vector<std::byte> owned;
    Ort::Env env;
    Ort::Session session{nullptr};
    std::mutex mutex;
};
detail::Engine::Engine(std::span<const std::byte> model) try : Engine(copy_model(model, false)) {}
catch (const std::bad_alloc&) { throw Error(Failure::resource_limit); }
detail::Engine::Engine(std::vector<std::byte> model) {
    if (model.empty() || model.size() > model_size) throw Error(Failure::artifact_size);
    if (std::strcmp(OrtGetApiBase()->GetVersionString(), "1.22.0") != 0) throw Error(Failure::runtime_version);
    try { impl_ = std::make_unique<Impl>(std::move(model)); }
    catch (const Ort::Exception&) { throw Error(Failure::runtime_failure); }
    catch (const std::bad_alloc&) { throw Error(Failure::resource_limit); }
}
detail::Engine::~Engine() = default;
std::array<float, feature_count> detail::Engine::run(const std::array<float, tensor_elements>& tensor) {
    if (std::fegetround() != FE_TONEAREST ||
        !std::all_of(tensor.begin(), tensor.end(), [](float value) { return std::isfinite(value); })) {
        throw Error(Failure::invalid_input);
    }
    const std::lock_guard<std::mutex> lock(impl_->mutex);
    try {
        // ORT's mutable tensor interface must never receive caller-owned storage.
        auto owned_input = tensor;
        std::array<float, feature_count> features{};
        const std::array<std::int64_t, 4> input_shape{1, 3, 112, 112};
        const std::array<std::int64_t, 2> output_shape{1, 512};
        auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        auto input = Ort::Value::CreateTensor<float>(memory, owned_input.data(), owned_input.size(), input_shape.data(), input_shape.size());
        auto output = Ort::Value::CreateTensor<float>(memory, features.data(), features.size(), output_shape.data(), output_shape.size());
        const char* inputs[]{"data"};
        const char* outputs[]{"1333"};
        impl_->session.Run(Ort::RunOptions{nullptr}, inputs, &input, 1, outputs, &output, 1);
        if (!output.IsTensor() || output.GetTensorTypeAndShapeInfo().GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
            output.GetTensorTypeAndShapeInfo().GetShape() != std::vector<std::int64_t>{1, 512} ||
            output.GetTensorTypeAndShapeInfo().GetElementCount() != feature_count) throw Error(Failure::output_metadata);
        // Reuse numerical admission, including typed nonfinite/norm failures.
        static_cast<void>(UnitEmbedding::normalize(features, space()));
        return features;
    } catch (const Ort::Exception&) { throw Error(Failure::runtime_failure); }
    catch (const std::bad_alloc&) { throw Error(Failure::resource_limit); }
}

class Session::Impl final {
public:
    explicit Impl(std::span<const std::byte> model)
        : engine(copy_model(model, true)) {}
    detail::Engine engine;
};
Session::Session(std::span<const std::byte> model) try : impl_(std::make_unique<Impl>(model)) {}
catch (const std::bad_alloc&) { throw Error(Failure::resource_limit); }
Session::~Session() = default;
EmbeddingResult Session::infer(const PixelSnapshot& pixels) try {
    const auto tensor = aligned_tensor(pixels);
    const auto features = impl_->engine.run(tensor);
    return EmbeddingResult(pixels.digest(), features, UnitEmbedding::normalize(features, space()));
} catch (const std::bad_alloc&) { throw Error(Failure::resource_limit); }
} // namespace kenshiki::auraface
