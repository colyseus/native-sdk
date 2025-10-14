#include "colyseus/settings.h"
#include <sstream>

namespace NativeSDK {

    std::string Settings::getWebSocketEndpoint() const {
        std::string scheme = useSecureProtocol ? "wss" : "ws";
        std::stringstream ss;
        ss << scheme << "://" << serverAddress;
        
        int port = getPort();
        if (port != -1) {
            ss << ":" << port;
        }
        
        return ss.str();
    }

    std::string Settings::getWebRequestEndpoint() const {
        std::string scheme = useSecureProtocol ? "https" : "http";
        std::stringstream ss;
        ss << scheme << "://" << serverAddress;
        
        int port = getPort();
        if (port != -1) {
            ss << ":" << port;
        }
        
        return ss.str();
    }

    int Settings::getPort() const {
        if (serverPort.empty() || serverPort == "80" || serverPort == "443") {
            return -1;
        }
        
        try {
            return std::stoi(serverPort);
        } catch (...) {
            return -1;
        }
    }

}