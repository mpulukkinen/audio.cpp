#pragma once

#include "engine/framework/runtime/model.h"

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace engine::model_spec {

struct ModelDependency {
    std::string kind;
    std::string family;
    std::string scope;
    std::string option;
    std::string option_key;
    bool required = false;
    std::vector<std::string> required_for;
    std::optional<std::string> path;
    std::optional<std::string> package;
};

[[nodiscard]] std::optional<runtime::CapabilitySet> advertised_capabilities(std::string_view family);
[[nodiscard]] std::optional<runtime::ModelCliInterface> cli_interface(std::string_view family);
[[nodiscard]] std::vector<ModelDependency> dependencies(std::string_view family);

}  // namespace engine::model_spec
