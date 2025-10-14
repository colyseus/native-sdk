#include "colyseus/settings.h"
#include <sstream>

namespace NativeSDK {

    void Settings::setRequestHeaders(const std::map<std::string, std::string>& newHeaders) {
        headers = newHeaders;
    }

    const std::map<std::string, std::string>& Settings::getRequestHeaders() const {
        return headers;
    }

    std::string Settings::getWebSocketEndpoint() const {
        return buildEndpoint(getWebSocketScheme());
    }

    std::string Settings::getWebRequestEndpoint() const {
        return buildEndpoint(getWebRequestScheme());
    }

    std::string Settings::getWebSocketScheme() const {
        return useSecureProtocol ? "wss" : "ws";
    }

    std::string Settings::getWebRequestScheme() const {
        return useSecureProtocol ? "https" : "http";
    }

    int Settings::getPort() const {
        if (!shouldIncludeServerPort()) {
            return -1;
        }

        try {
            return std::stoi(serverPort);
        } catch (...) {
            return -1;
        }
    }

    Settings Settings::clone() const {
        Settings copy;
        copy.serverAddress = serverAddress;
        copy.serverPort = serverPort;
        copy.useSecureProtocol = useSecureProtocol;
        copy.headers = headers;
        return copy;
    }

    std::string Settings::buildEndpoint(const std::string& scheme) const {
        std::stringstream ss;
        ss << scheme << "://" << serverAddress;

        int port = getPort();
        if (port != -1) {
            ss << ":" << port;
        }

        return ss.str();
    }

    bool Settings::shouldIncludeServerPort() const {
        return !serverPort.empty() &&
               serverPort != "80" &&
               serverPort != "443";
    }

}