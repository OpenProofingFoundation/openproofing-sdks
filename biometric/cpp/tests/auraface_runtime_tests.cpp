#include "kenshiki/auraface.hpp"
#include "auraface_runtime.hpp"
#include <array>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <thread>
#include <vector>

namespace af = kenshiki::auraface;
namespace {
#include "auraface_baseline.inc"
std::size_t assertions = 0;
void check(bool value) {
    ++assertions;
    if (!value) throw std::runtime_error("auraface_runtime_assertion");
}
std::vector<std::byte> load(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream) throw std::runtime_error("fixture_missing");
    const auto size = stream.tellg();
    if (size < 0 || size > 65536) throw std::runtime_error("fixture_size");
    std::vector<std::byte> bytes(static_cast<std::size_t>(size));
    stream.seekg(0);
    if (!stream.read(reinterpret_cast<char*>(bytes.data()), size)) throw std::runtime_error("fixture_read");
    return bytes;
}
std::vector<std::byte> load_model(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream || stream.tellg() != static_cast<std::streamoff>(af::model_size))
        throw std::runtime_error("model_size");
    std::vector<std::byte> bytes(af::model_size);
    stream.seekg(0);
    if (!stream.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size())) ||
        stream.peek() != std::char_traits<char>::eof()) throw std::runtime_error("model_read");
    return bytes;
}
template<class Operation> void reject(af::Failure expected, Operation operation) {
    bool rejected = false;
    try { operation(); } catch (const af::Error& error) { rejected = error.reason() == expected; }
    check(rejected);
}
}
int main(int argc, char** argv) {
    try {
        if (argc != 2 && argc != 3) throw std::runtime_error("fixture_directory_required");
        const std::filesystem::path directory(argv[1]);
        std::array<float, af::tensor_elements> input{};
        input.fill(0.25F);
        auto bytes = load(directory / "valid.onnx");
        af::detail::Engine engine(bytes);
        bytes.assign(bytes.size(), std::byte{0}); bytes.clear(); bytes.shrink_to_fit();
        const auto result = engine.run(input);
        for (float feature : result) check(std::abs(feature - 0.25F) < 1e-6F);
        check(input.front() == 0.25F && input.back() == 0.25F);
        input.fill(-0.5F);
        const auto changed = engine.run(input);
        for (float feature : changed) check(std::abs(feature + 0.5F) < 1e-6F);
        std::array<float, af::feature_count> parallel_a{}, parallel_b{};
        std::thread a([&] { parallel_a = engine.run(input); });
        std::thread b([&] { parallel_b = engine.run(input); });
        a.join(); b.join();
        check(parallel_a == changed && parallel_b == changed);
        input.front() = std::numeric_limits<float>::quiet_NaN();
        reject(af::Failure::invalid_input, [&] { static_cast<void>(engine.run(input)); });
        input.front() = std::numeric_limits<float>::infinity();
        reject(af::Failure::invalid_input, [&] { static_cast<void>(engine.run(input)); });
        input.fill(0.25F);
        for (const auto* name : {"input_name", "output_name", "input_shape", "batch_two", "input_type", "output_shape", "output_type"}) {
            const auto fixture = load(directory / (std::string(name) + ".onnx"));
            reject(af::Failure::model_metadata, [&] { af::detail::Engine rejected(fixture); });
        }
        const auto malformed = load(directory / "malformed.onnx");
        reject(af::Failure::runtime_failure, [&] { af::detail::Engine rejected(malformed); });
        for (const auto* name : {"nan", "infinity", "zero"}) {
            const auto fixture = load(directory / (std::string(name) + ".onnx"));
            af::detail::Engine invalid(fixture);
            bool rejected = false;
            try { static_cast<void>(invalid.run(input)); }
            catch (const kenshiki::ContractError& error) {
                rejected = error.reason() == (std::string(name) == "zero" ? kenshiki::Failure::invalid_norm : kenshiki::Failure::nonfinite_feature);
            }
            check(rejected);
        }
        reject(af::Failure::artifact_size, [&] { af::Session rejected(malformed); });
        // Correct size bypasses the cheap bounds check, but must still fail the
        // exact artifact digest before the ONNX parser sees these invalid bytes.
        std::vector<std::byte> same_size(af::model_size);
        reject(af::Failure::artifact_integrity, [&] { af::Session rejected(same_size); });
        same_size.clear(); same_size.shrink_to_fit();
        if (argc == 3) {
            auto model = load_model(argv[2]);
            af::Session session(model);
            model.assign(model.size(), std::byte{0}); model.clear(); model.shrink_to_fit();
            std::vector<std::byte> rgb(af::tensor_elements);
            for (std::size_t p = 0; p < af::width * af::height; ++p)
                for (std::size_t c = 0; c < 3; ++c)
                    rgb[p * 3 + c] = static_cast<std::byte>((p * 37 + c * 83) % 256);
            const auto snapshot = kenshiki::PixelSnapshot::create({
                {"width", std::int64_t{112}}, {"height", std::int64_t{112}},
                {"orientation", std::int64_t{1}}, {"format", std::string("rgb8")},
                {"rowStrideBytes", std::int64_t{336}}, {"byteLength", std::int64_t{37632}},
                {"sha256", kenshiki::sha256(rgb)}}, rgb);
            const auto first = session.infer(snapshot);
            rgb.assign(rgb.size(), std::byte{0}); rgb.clear(); rgb.shrink_to_fit();
            const auto repeated = session.infer(snapshot);
            check(first.input_sha256() == snapshot.digest());
            check(first.input_sha256() == baseline_input_sha256);
            check(first.raw_features() == repeated.raw_features());
            check(first.embedding().cosine(repeated.embedding()) > 1.0 - 1e-12);
            for (float feature : first.raw_features()) check(std::isfinite(feature));
            const kenshiki::EmbeddingSpace expected(std::string(af::artifact_manifest_sha256()),
                kenshiki::EmbeddingDomain::face_identity, 512, 1e-12);
            const auto normalized = kenshiki::UnitEmbedding::normalize(first.raw_features(), expected);
            check(first.embedding().cosine(normalized) > 1.0 - 1e-12);
            const auto reference = kenshiki::UnitEmbedding::normalize(baseline_features, expected);
            double maximum_error = 0.0;
            for (std::size_t index = 0; index < af::feature_count; ++index)
                maximum_error = std::max(maximum_error, std::abs(static_cast<double>(first.raw_features()[index]) - baseline_features[index]));
            check(maximum_error <= baseline_max_error);
            check(first.embedding().cosine(reference) >= baseline_min_cosine);
            std::array<float, af::feature_count> concurrent_a{}, concurrent_b{};
            std::array<std::string, 2> concurrent_digest{};
            std::thread public_a([&] {
                const auto observation = session.infer(snapshot);
                concurrent_a = observation.raw_features(); concurrent_digest[0] = observation.input_sha256();
            });
            std::thread public_b([&] {
                const auto observation = session.infer(snapshot);
                concurrent_b = observation.raw_features(); concurrent_digest[1] = observation.input_sha256();
            });
            public_a.join(); public_b.join();
            check(concurrent_a == first.raw_features() && concurrent_b == first.raw_features());
            check(concurrent_digest[0] == snapshot.digest() && concurrent_digest[1] == snapshot.digest());
            std::cout << "auraface_real_model_max_feature_error=" << maximum_error << '\n';
            std::cout << "auraface_real_model_inference=passed\n";
        }
        std::cout << "auraface_runtime_assertions=" << assertions << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
