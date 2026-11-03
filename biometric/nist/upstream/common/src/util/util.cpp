/**
 * This software was developed at the National Institute of Standards and
 * Technology (NIST) by employees of the Federal Government in the course
 * of their official duties. Pursuant to title 17 Section 105 of the
 * United States Code, this software is not subject to copyright protection
 * and is in the public domain. NIST assumes no responsibility  whatsoever for
 * its use by other parties, and makes no guarantees, expressed or implied,
 * about its quality, reliability, or any other characteristic.
 **/

#include <algorithm>
#include <limits>
#include <fstream>

#include "util.h"

using namespace std;
using namespace FRVT;

static const string inputFileStem = "input.txt.";

/**
 * Reads a PPM file into an Image object.
 * This function isn't intended to fully support the PPM format, only enough
 * to read the validation images.
 */
bool
readImage(
    const string &file,
    Image &image)
{
    /* Open PPM file. */
    ifstream input(file, ios::binary);
    if (!input.is_open()) {
        cerr << "[ERROR] Cannot open image: " << file << endl;
        return false;
    }

    /* Read in magic number. */
    string magicNumber;
    input >> magicNumber;
    if (magicNumber != "P6" && magicNumber != "P5") {
        cerr << "[ERROR] Error reading magic number from file." << endl;
        return false;
    }

    uint16_t maxValue;
    /* Read in image width, height, and max intensity value. */
    input >> image.width >> image.height >> maxValue;
    if (!input.good()) {
        cerr << "[ERROR] Error, premature end of file while reading header." << endl;
        return false;
    }

    if (magicNumber == "P5")
        image.depth = 8;
    else if (magicNumber == "P6")
        image.depth = 24;

    /* Skip line break. */
    input.ignore(numeric_limits<streamsize>::max(), '\n');

    uint8_t *data = new uint8_t[image.size()];
    image.data.reset(data, std::default_delete<uint8_t[]>());

    /* Read in raw pixel data. */
    input.read((char*)image.data.get(), image.size());
    if (!input.good()) {
        cerr << "[ERROR] Error, only read " << input.gcount() << " bytes." << endl;
        return false;
    }
    return true;
}

int
splitInputFile(
    const string &inputFile,
    const string &outputDir,
    int &numForks,
    vector<string> &fileVector)
{
    /* Read input file */
    ifstream inputStream(inputFile);
    if (!inputStream.is_open()) {
        cerr << "[ERROR] Failed to open stream for " << inputFile << "." << endl;
        return FAILURE;
    }

    /* Count number of lines in file */
    auto numLines = count(
            istreambuf_iterator<char>(inputStream),
            istreambuf_iterator<char>(), '\n');

    inputStream.clear();
    inputStream.seekg(0, ios::beg);

    /**
     * If the number of processes to fork is more than
     * the number of lines in the file, set numForks
     * to numLines
     */
    if (numLines < (uint32_t)numForks)
        numForks = numLines;
    /* This is the round-up of numLines/numForks */
    int numLinesPerFork = numLines / numForks + (numLines
            % numForks > 0 ? 1 : 0);
    /* re-assign the number of forks if the numbers don't work out */
    numForks = (numLines/numLinesPerFork) + ((numLines
            % numLinesPerFork) > 0 ? 1 : 0);

    for (int i = 0; i < numForks; i++) {
        string filepath = outputDir + "/" + inputFileStem + to_string(i);
        ofstream outputStream(filepath);
        if (!outputStream.is_open()) {
            cerr << "[ERROR] Failed to open stream for " << filepath << "." << endl;
            return FAILURE;
        }
        fileVector.push_back(filepath);

        for (int line_num = 1; line_num < numLinesPerFork + 1; line_num++) {
            string line;
            if (getline(inputStream, line))
                outputStream << line << endl;
            else
                break;
        }
    }

    return SUCCESS;
}

vector<string>
split(
        const string &str,
        const char delimiter)
{
    vector<string> ret;

    std::string cur_str("");
    for (unsigned int i = 0; i < str.length(); i++)
    {
        if (str[i] == delimiter) {
            /* Don't insert empty tokens */
            if (cur_str == "")
                continue;

            /* Non-escaped delimiter reached: add token */
            ret.push_back(cur_str);
            cur_str = "";
        } else
            cur_str.push_back(str[i]);
    }

    /* Add partially formed token if not empty */
    if (cur_str != "")
        ret.push_back(cur_str);

    /* Add the original string if the delimiter was not found */
    if (ret.size() == 0)
        ret.push_back(str);

    return (ret);
}

std::map<std::string, Modality> mapStringToModality =
{
    { "face", Modality::Face },
    { "iris", Modality::Iris },
    { "mm", Modality::MM }
};

std::map<Modality, std::string> mapModalityToString =
{
    { Modality::Face, "face" },
    { Modality::Iris, "iris" },
    { Modality::MM, "mm" }
};

std::map<std::string, Action> mapStringToAction =
{
    /* 1:1 */
    { "createTemplate", Action::CreateTemplate },
    { "createMultiTemplates", Action::CreateMultiTemplates },
    { "match", Action::Match },
    /* 1:N */
    { "enroll_1N", Action::Enroll_1N },
    { "finalize_1N", Action::Finalize_1N },
    { "search_1N", Action::Search_1N },
    { "searchMulti_1N", Action::SearchMulti_1N },
    /* MORPH */
    { "detectNonScannedMorph", Action::DetectNonScannedMorph },
    { "detectScannedMorph", Action::DetectScannedMorph },
    { "detectUnknownMorph", Action::DetectUnknownMorph },
    { "detectNonScannedMorphWithProbeImg", Action::DetectNonScannedMorphWithProbeImg },
    { "detectScannedMorphWithProbeImg", Action::DetectScannedMorphWithProbeImg },
    { "detectUnknownMorphWithProbeImg", Action::DetectUnknownMorphWithProbeImg },
    { "detectNonScannedMorphWithProbeImgAndMeta", Action::DetectNonScannedMorphWithProbeImgAndMeta },
    { "detectScannedMorphWithProbeImgAndMeta", Action::DetectScannedMorphWithProbeImgAndMeta },
    { "detectUnknownMorphWithProbeImgAndMeta", Action::DetectUnknownMorphWithProbeImgAndMeta },
    { "compare", Action::Compare },
    { "demorph", Action::Demorph },
    { "demorphDifferentially", Action::DemorphDifferentially },
    /* QUALITY */
    { "scalarQ", Action::ScalarQ },
    { "scalarQWithReference", Action::ScalarQWithReference },
    { "scalarImageQ", Action::ScalarImageQ },
    { "scalarSubjectQ", Action::ScalarSubjectQ },
    { "vectorQ", Action::VectorQ },
    /* PAD */
    { "detectImpersonationPA", Action::DetectImpersonationPA },
    { "detectEvasionPA", Action::DetectEvasionPA },
    /* AGE ESTIMATION */
    { "estimateAge", Action::EstimateAge },
    { "verifyAge", Action::VerifyAge },
    { "estimateAgeWithReference", Action::EstimateAgeWithReference},
};

std::map<Action, std::string> mapActionToString =
{
    /* 1:1 */
    { Action::CreateTemplate, "createTemplate" },
    { Action::CreateMultiTemplates, "createMultiTemplates" },
    { Action::Match, "match" },
    /* 1:N */
    { Action::Enroll_1N, "enroll_1N" },
    { Action::Finalize_1N, "finalize_1N" },
    { Action::Search_1N, "search_1N" },
    { Action::SearchMulti_1N, "searchMulti_1N" },
    /* MORPH */
    { Action::DetectNonScannedMorph, "detectNonScannedMorph" },
    { Action::DetectScannedMorph, "detectScannedMorph" },
    { Action::DetectUnknownMorph, "detectUnknownMorph" },
    { Action::DetectNonScannedMorphWithProbeImg, "detectNonScannedMorphWithProbeImg" },
    { Action::DetectScannedMorphWithProbeImg, "detectScannedMorphWithProbeImg" },
    { Action::DetectUnknownMorphWithProbeImg, "detectUnknownMorphWithProbeImg" },
    { Action::DetectNonScannedMorphWithProbeImgAndMeta, "detectNonScannedMorphWithProbeImgAndMeta" },
    { Action::DetectScannedMorphWithProbeImgAndMeta, "detectScannedMorphWithProbeImgAndMeta" },
    { Action::DetectUnknownMorphWithProbeImgAndMeta, "detectUnknownMorphWithProbeImgAndMeta" },
    { Action::Compare, "compare" },
    { Action::Demorph, "demorph" },
    { Action::DemorphDifferentially, "demorphDifferentially" },
    /* QUALITY */
    { Action::ScalarQ, "scalarQ" },
    { Action::ScalarQWithReference, "scalarQWithReference" },
    { Action::ScalarImageQ, "scalarImageQ" },
    { Action::ScalarSubjectQ, "scalarSubjectQ" },
    { Action::VectorQ, "vectorQ" },
    /* PAD */
    { Action::DetectImpersonationPA, "detectImpersonationPA" },
    { Action::DetectEvasionPA, "detectEvasionPA" },
    /* AGE ESTIMATION */
    { Action::EstimateAge, "estimateAge" },
    { Action::VerifyAge, "verifyAge" },
    { Action::EstimateAgeWithReference, "estimateAgeWithReference" },
};

std::map<std::string, FRVT::Image::ImageDescription> mapStringToImgLabel =
{
    { "faceunknown", FRVT::Image::ImageDescription::FaceUnknown },
    { "faceiso", FRVT::Image::ImageDescription::FaceIso },
    { "facemugshot", FRVT::Image::ImageDescription::FaceMugshot },
    { "facephotojournalism", FRVT::Image::ImageDescription::FacePhotojournalism },
    { "facewild", FRVT::Image::ImageDescription::FaceWild },
    { "irisunknown", FRVT::Image::ImageDescription::IrisUnknown },
    { "irisnir", FRVT::Image::ImageDescription::IrisNIR },
    { "iriswild", FRVT::Image::ImageDescription::IrisWild },
};

std::map<FRVT::ReturnCode, std::string> mapRetCodeToString =
{
    { FRVT::ReturnCode::Success, "Success" },
    { FRVT::ReturnCode::UnknownError, "UnknownError" },
    { FRVT::ReturnCode::ConfigError, "ConfigError" },
    { FRVT::ReturnCode::RefuseInput, "RefuseInput" },
    { FRVT::ReturnCode::ExtractError, "ExtractError" },
    { FRVT::ReturnCode::ParseError, "ParseError" },
    { FRVT::ReturnCode::TemplateCreationError, "TemplateCreationError" },
    { FRVT::ReturnCode::VerifTemplateError, "VerifTemplateError" },
    { FRVT::ReturnCode::FaceDetectionError, "FaceDetectionError" },
    { FRVT::ReturnCode::NumDataError, "NumDataError" },
    { FRVT::ReturnCode::TemplateFormatError, "TemplateFormatError" },
    { FRVT::ReturnCode::EnrollDirError, "EnrollDirError" },
    { FRVT::ReturnCode::InputLocationError, "InputLocationError" },
    { FRVT::ReturnCode::MemoryError, "MemoryError" },
    { FRVT::ReturnCode::MatchError, "MatchError" },
    { FRVT::ReturnCode::NotImplemented, "NotImplemented" },
    { FRVT::ReturnCode::VendorError, "VendorError" },
};
