#include "engine/framework/model_spec/metadata.h"
#include "engine/framework/model_spec/package.h"
#include "engine/framework/model_spec/schema.h"
#include "engine/framework/io/json.h"
#include "test_assert.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

namespace json = engine::io::json;

std::filesystem::path make_temp_root() {
    const auto root = std::filesystem::temp_directory_path() / "audiocpp_model_spec_system_test";
    std::error_code ec;
    std::filesystem::remove_all(root, ec);
    std::filesystem::create_directories(root);
    return root;
}

std::filesystem::path write_text(
    const std::filesystem::path & root,
    const std::filesystem::path & relative_path,
    const std::string & text) {
    const auto path = root / relative_path;
    std::filesystem::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary);
    if (!out) {
        throw std::runtime_error("failed to create test file: " + path.string());
    }
    out << text;
    return path;
}

std::string legacy_spec_text(const std::string & dependencies) {
    return R"JSON({
  "family": "toy_model",
  "sources": [
    {
      "format": "safetensors",
      "roots": {
        "model": "."
      },
      "files": {
        "config": "model:config.json"
      },
      "optional_files": {
        "tokenizer": "model:tokenizer.json"
      },
      "tensors": {
        "weights": "model:model.safetensors"
      }
    }
  ],
  "dependencies": )JSON" + dependencies + R"JSON(
})JSON";
}

void expect_rejects(const std::string & label, const std::string & spec_text, const std::string & needle) {
    bool rejected = false;
    try {
        engine::model_spec::validate_spec(json::parse(spec_text), label);
    } catch (const std::runtime_error & error) {
        rejected = std::string(error.what()).find(needle) != std::string::npos;
    }
    engine::test::require(rejected, label + " should reject with: " + needle);
}

void test_legacy_dependencies_schema() {
    const auto spec = json::parse(legacy_spec_text(R"JSON([
    {
      "kind": "model",
      "family": "peer_model",
      "scope": "session",
      "option": "peer_model_path",
      "required": true
    },
    {
      "kind": "bundled_model",
      "family": "silero_vad",
      "path": "assets/framework/models/silero_vad",
      "scope": "request",
      "option": "vad_model_path",
      "required": false,
      "required_when": [
        {
          "scope": "request",
          "option_key": "audio_chunk_mode",
          "equals": "vad"
        }
      ]
    }
  ])JSON"));
    engine::model_spec::validate_spec(spec, "valid_legacy_dependencies");

    expect_rejects(
        "old_option_key",
        legacy_spec_text(R"JSON([
          {
            "kind": "model",
            "family": "peer_model",
            "scope": "session",
            "option_key": "toy_model.peer_model_path",
            "required": true
          }
        ])JSON"),
        "missing required field 'option'");
    expect_rejects(
        "invalid_scope",
        legacy_spec_text(R"JSON([
          {
            "kind": "model",
            "family": "peer_model",
            "scope": "prepare",
            "option": "peer_model_path",
            "required": true
          }
        ])JSON"),
        "unknown dependency scope 'prepare'");
    expect_rejects(
        "namespaced_local_option",
        legacy_spec_text(R"JSON([
          {
            "kind": "model",
            "family": "peer_model",
            "scope": "session",
            "option": "toy_model.peer_model_path",
            "required": true
          }
        ])JSON"),
        "dependency option must be local");
    expect_rejects(
        "old_required_for",
        legacy_spec_text(R"JSON([
          {
            "kind": "model",
            "family": "peer_model",
            "scope": "session",
            "option": "peer_model_path",
            "required": false,
            "required_for": ["decode"]
          }
        ])JSON"),
        "use typed required_when conditions");
    expect_rejects(
        "optional_missing_condition",
        legacy_spec_text(R"JSON([
          {
            "kind": "model",
            "family": "peer_model",
            "scope": "session",
            "option": "peer_model_path",
            "required": false
          }
        ])JSON"),
        "optional dependencies require typed conditions");
    expect_rejects(
        "required_with_condition",
        legacy_spec_text(R"JSON([
          {
            "kind": "model",
            "family": "peer_model",
            "scope": "session",
            "option": "peer_model_path",
            "required": true,
            "required_when": [
              {
                "scope": "request",
                "option_key": "return_timestamps",
                "equals": true
              }
            ]
          }
        ])JSON"),
        "required dependencies must not have conditions");
    expect_rejects(
        "dependency_package_hint",
        legacy_spec_text(R"JSON([
          {
            "kind": "model",
            "family": "peer_model",
            "scope": "session",
            "option": "peer_model_path",
            "required": false,
            "required_when": [
              {
                "scope": "request",
                "option_key": "return_timestamps",
                "equals": true
              }
            ],
            "package": "peer_model_q8_0"
          }
        ])JSON"),
        "dependency package hints are not part of the core contract");
    expect_rejects(
        "bundled_missing_path",
        legacy_spec_text(R"JSON([
          {
            "kind": "bundled_model",
            "family": "silero_vad",
            "scope": "session",
            "option": "vad_model_path",
            "required": false,
            "required_when": [
              {
                "scope": "request",
                "option_key": "audio_chunk_mode",
                "equals": "vad"
              }
            ]
          }
        ])JSON"),
        "missing required field 'path'");
}

void test_typed_schema_renamed_dependencies() {
    const auto typed = json::parse(R"JSON({
  "schema_version": 1,
  "family": "typed_model",
  "display_name": "Typed Model",
  "category": "asr",
  "status": "experimental",
  "tasks": ["asr"],
  "modes": ["offline"],
  "runtime": {
    "tags": ["gguf"]
  },
  "capabilities": {
    "timestamps": true,
    "speaker_reference": false,
    "style_condition": false,
    "voice_design": false,
    "languages": ["en"]
  },
  "options": {
    "request": [],
    "session": [],
    "load": []
  },
  "packages": [
    {
      "id": "typed_model_q8",
      "display_name": "Typed Model Q8",
      "format": "gguf",
      "precision": "q8_0",
      "target_directory": "Typed-Model",
      "download": {
        "kind": "huggingface_snapshot",
        "repo": "audio-cpp/typed-model"
      },
      "files": ["typed-model-q8_0.gguf"],
      "default": true
    }
  ],
  "layouts": {
    "gguf": {
      "format": "gguf",
      "roots": {
        "model": ".",
        "weights": "$gguf"
      },
      "files": {
        "config": "model:config.json"
      },
      "tensors": {
        "weights": "weights:"
      }
    }
  },
  "dependencies": [
    {
      "kind": "model",
      "family": "typed_aligner",
      "scope": "session",
      "option": "aligner_model_path",
      "required": false,
      "required_when": [
        {
          "scope": "request",
          "option_key": "return_timestamps",
          "equals": true
        },
        {
          "scope": "request",
          "option_key": "audio_chunk_seconds",
          "equals": 15
        }
      ]
    }
  ],
  "ui": {
    "recommended_package": "typed_model_q8",
    "tags": ["ASR"],
    "docs": ["docs/asr.md"]
  },
  "sources": [
    {
      "format": "gguf",
      "roots": {
        "model": ".",
        "weights": "$gguf"
      },
      "files": {
        "config": "model:config.json"
      },
      "tensors": {
        "weights": "weights:"
      }
    }
  ]
})JSON");
    engine::model_spec::validate_spec(typed, "typed_dependencies");

    expect_rejects(
        "typed_rejects_companions",
        R"JSON({
          "schema_version": 1,
          "family": "typed_model",
          "display_name": "Typed Model",
          "category": "asr",
          "status": "experimental",
          "tasks": ["asr"],
          "modes": ["offline"],
          "runtime": {"tags": ["gguf"]},
          "capabilities": {
            "timestamps": true,
            "speaker_reference": false,
            "style_condition": false,
            "voice_design": false,
            "languages": ["en"]
          },
          "options": {"request": [], "session": [], "load": []},
          "packages": [
            {
              "id": "typed_model_q8",
              "display_name": "Typed Model Q8",
              "format": "gguf",
              "precision": "q8_0",
              "target_directory": "Typed-Model",
              "download": {"kind": "huggingface_snapshot", "repo": "audio-cpp/typed-model"},
              "files": ["typed-model-q8_0.gguf"],
              "default": true
            }
          ],
          "layouts": {
            "gguf": {
              "format": "gguf",
              "roots": {"model": ".", "weights": "$gguf"},
              "files": {"config": "model:config.json"},
              "tensors": {"weights": "weights:"}
            }
          },
          "companions": [],
          "ui": {
            "recommended_package": "typed_model_q8",
            "tags": ["ASR"],
            "docs": ["docs/asr.md"]
          },
          "sources": [
            {
              "format": "gguf",
              "roots": {"model": ".", "weights": "$gguf"},
              "files": {"config": "model:config.json"},
              "tensors": {"weights": "weights:"}
            }
          ]
        })JSON",
        "missing required field 'dependencies'");
}

void test_dependency_option_mapping_from_production_spec() {
    const auto miotts_dependencies = engine::model_spec::dependencies("miotts");
    engine::test::require_eq(miotts_dependencies.size(), size_t{2}, "miotts dependency count");
    engine::test::require_eq(miotts_dependencies[0].family, std::string("miocodec"), "miotts codec dependency family");
    engine::test::require_eq(miotts_dependencies[0].scope, std::string("session"), "miotts codec dependency scope");
    engine::test::require_eq(miotts_dependencies[0].option, std::string("codec_model_path"), "miotts codec dependency option");
    engine::test::require_eq(
        miotts_dependencies[0].option_key,
        std::string("miotts.codec_model_path"),
        "miotts codec derived option key");
    engine::test::require(miotts_dependencies[0].required, "miotts codec dependency should be required");
    engine::test::require(
        miotts_dependencies[0].required_when.empty(),
        "miotts required codec dependency should not have conditions");

    engine::test::require_eq(miotts_dependencies[1].family, std::string("qwen3_asr"), "miotts ASR dependency family");
    engine::test::require_eq(
        miotts_dependencies[1].option_key,
        std::string("miotts.best_of_n_asr_model_path"),
        "miotts ASR derived option key");
    engine::test::require(!miotts_dependencies[1].required, "miotts ASR dependency should be optional");
    engine::test::require_eq(miotts_dependencies[1].required_when.size(), size_t{2}, "miotts ASR dependency conditions");
    engine::test::require_eq(
        miotts_dependencies[1].required_when[0].scope,
        std::string("session"),
        "miotts ASR condition scope");
    engine::test::require_eq(
        miotts_dependencies[1].required_when[0].option_key,
        std::string("miotts.best_of_n_enabled"),
        "miotts ASR condition option key");
    engine::test::require(
        miotts_dependencies[1].required_when[0].equals_type == engine::model_spec::ModelSpecValueType::Bool,
        "miotts ASR condition should compare bool");
    engine::test::require(miotts_dependencies[1].required_when[0].equals_bool, "miotts ASR condition bool");

    const auto qwen_dependencies = engine::model_spec::dependencies("qwen3_asr");
    engine::test::require_eq(qwen_dependencies.size(), size_t{2}, "qwen3 ASR dependency count");
    engine::test::require_eq(
        qwen_dependencies[0].option_key,
        std::string("qwen3_asr.forced_aligner_model_path"),
        "qwen3 aligner derived option key");
    engine::test::require_eq(
        qwen_dependencies[0].required_when[0].option_key,
        std::string("return_timestamps"),
        "qwen3 aligner condition option key");
    engine::test::require(
        qwen_dependencies[0].required_when[0].equals_type == engine::model_spec::ModelSpecValueType::Bool,
        "qwen3 aligner condition should compare bool");
    engine::test::require(qwen_dependencies[0].required_when[0].equals_bool, "qwen3 aligner condition bool");
    engine::test::require_eq(
        qwen_dependencies[1].required_when[0].option_key,
        std::string("audio_chunk_mode"),
        "qwen3 VAD condition option key");
    engine::test::require(
        qwen_dependencies[1].required_when[0].equals_type == engine::model_spec::ModelSpecValueType::String,
        "qwen3 VAD condition should compare string");
    engine::test::require_eq(
        qwen_dependencies[1].required_when[0].equals_string,
        std::string("vad"),
        "qwen3 VAD condition string");
}

void test_loading_and_resource_bundle() {
    const auto root = make_temp_root();
    const auto model_root = root / "model";
    std::filesystem::create_directories(model_root);
    write_text(model_root, "config.json", "{\"ok\":true}");
    write_text(model_root, "model.safetensors", "");
    const auto spec_path = write_text(root, "toy_model.json", legacy_spec_text("[]"));

    const auto spec = engine::model_spec::load_spec(spec_path);
    engine::test::require_eq(
        spec.require("family").as_string(),
        std::string("toy_model"),
        "loaded spec family");
    const auto bundle = engine::model_spec::load_resource_bundle(model_root, spec_path);
    engine::test::require_eq(
        bundle.read_text("config"),
        std::string("{\"ok\":true}"),
        "resource bundle config");
    engine::test::require(bundle.has_file("weights"), "tensor source file should be registered");
    engine::test::require(!bundle.has_file("tokenizer"), "missing optional file should not be registered");

    std::filesystem::remove_all(root);
}

}  // namespace

int main() {
    try {
        test_legacy_dependencies_schema();
        test_typed_schema_renamed_dependencies();
        test_dependency_option_mapping_from_production_spec();
        test_loading_and_resource_bundle();
    } catch (const std::exception & error) {
        std::cerr << "model_spec_system_test failed: " << error.what() << "\n";
        return 1;
    }
    std::cout << "model_spec_system_test passed\n";
    return 0;
}
