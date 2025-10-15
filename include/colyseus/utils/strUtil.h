#pragma once
#include <string>

namespace Colyseus {
    namespace Utils {

        struct URLParts {
            std::string scheme;      // ws, wss
            std::string host;
            std::optional<uint16_t> port;
            std::string pathAndArgs;
            std::string url;
        };

        std::optional<URLParts> parseURL(const std::string& url);
        std::string base64Encode(const std::string& input);
        std::string base64Decode(const std::string& input);

    } // namespace Utils
} // namespace Colyseus