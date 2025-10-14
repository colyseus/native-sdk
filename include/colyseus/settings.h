#pragma once
#include <string>
#include <map>

namespace Colyseus {

    struct Settings {
        std::string serverAddress = "localhost";
        std::string serverPort = "2567";
        bool useSecureProtocol = false;
        std::map<std::string, std::string> headers;

        std::string getWebSocketEndpoint() const;
        std::string getWebRequestEndpoint() const;
        int getPort() const;
    };

    class Client {
    public:
        Client(const Settings& settings);
        void connect();
        void disconnect();

    private:
        Settings settings_;
    };

} // namespace NativeSDK