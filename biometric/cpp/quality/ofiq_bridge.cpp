#include "ofiq_native.h"
#include "ofiq_lib.h"
#include <onnxruntime_c_api.h>
#include <opencv2/core.hpp>
#include <algorithm>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <string>
namespace {
struct Session final { std::shared_ptr<OFIQ::Interface> engine; };
void empty_result(OFIQNativeResult& result) {
    result = {};
    result.return_code = static_cast<int32_t>(OFIQ::ReturnCode::UnknownError);
    for (size_t i=0; i<OFIQ_NATIVE_COMPONENT_COUNT; ++i) {
        result.components[i] = {static_cast<int32_t>(0x41+i),
            static_cast<int32_t>(OFIQ::QualityMeasureReturnCode::NotInitialized),
            std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::quiet_NaN()};
    }
}
}
extern "C" void *ofiq_native_create(const char *directory, int32_t *failure) {
    if (failure) *failure=1;
    if (!failure || !directory || std::strlen(directory)==0 || std::strlen(directory)>4096) return nullptr;
    try {
        if (std::string(OrtGetApiBase()->GetVersionString())!="1.22.0" || std::string(CV_VERSION)!="4.5.5") {
            *failure=3; return nullptr;
        }
        cv::setNumThreads(1);
        auto session=std::make_unique<Session>();
        session->engine=OFIQ::Interface::getImplementation();
        const auto initialized=session->engine->initialize(directory,"ofiq_config.jaxn");
        if (initialized.code!=OFIQ::ReturnCode::Success) { *failure=4; return nullptr; }
        *failure=0; return session.release();
    } catch (const std::bad_alloc&) { *failure=2; return nullptr; }
    catch (...) { *failure=3; return nullptr; }
}
extern "C" void ofiq_native_destroy(void *session) { delete static_cast<Session*>(session); }
extern "C" int32_t ofiq_native_assess(void *session, const uint8_t *rgb, size_t count,
    uint32_t width, uint32_t height, OFIQNativeResult *result) {
    if (result) empty_result(*result);
    if (!session || !result || !rgb || width==0 || height==0 || width>4096 || height>4096 ||
        static_cast<uint64_t>(width)*height>8388608 || static_cast<uint64_t>(width)*height*3!=count) return 1;
    try {
        OFIQ::Image image;
        image.width=static_cast<uint16_t>(width); image.height=static_cast<uint16_t>(height); image.depth=24;
        image.data.reset(new uint8_t[count],std::default_delete<uint8_t[]>());
        std::copy(rgb,rgb+count,image.data.get());
        OFIQ::FaceImageQualityAssessment assessment;
        OFIQ::FaceImageQualityPreprocessingResult preprocessing;
        const auto status=static_cast<Session*>(session)->engine->vectorQualityWithPreprocessingResults(
            image,assessment,preprocessing,static_cast<uint32_t>(OFIQ::PreprocessingResultType::Faces));
        result->return_code=static_cast<int32_t>(status.code);
        result->face_count=static_cast<int32_t>(preprocessing.m_faces.size());
        for (const auto& [measure,value]: assessment.qAssessments) {
            const int index=static_cast<int>(measure)-0x41;
            if (index<0 || index>=OFIQ_NATIVE_COMPONENT_COUNT) return 3;
            result->components[index]={static_cast<int32_t>(measure),static_cast<int32_t>(value.code),value.rawScore,value.scalar};
        }
        return 0;
    } catch (const std::bad_alloc&) { empty_result(*result); return 2; }
    catch (...) { empty_result(*result); return 3; }
}
