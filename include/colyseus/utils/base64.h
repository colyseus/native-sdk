#pragma once
#include <string>

namespace Colyseus {
    namespace Utils {

        std::string base64Encode(const std::string& input);
        std::string base64Decode(const std::string& input);

    } // namespace Utils
} // namespace Colyseus