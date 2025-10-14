//
// Created by Bharath Sharama on 14/10/25.
//

#pragma once
#include <string>
#include <map>
#include <functional>
#include <cstdint>
#include <vector>

namespace Colyseus {

    struct TransportEvents {
        std::function<void()> onOpen;
        std::function<void(const std::vector<uint8_t>& data)> onMessage;
        std::function<void(int code, const std::string& reason)> onClose;
        std::function<void(const std::string& error)> onError;
    };

    class ITransport {
    public:
        virtual ~ITransport() = default;

        virtual void connect(const std::string& url, const std::map<std::string, std::string>& options = {}) = 0;
        virtual void send(const std::vector<uint8_t>& data) = 0;
        virtual void sendUnreliable(const std::vector<uint8_t>& data) = 0;
        virtual void close(int code = 1000, const std::string& reason = "") = 0;
        virtual bool isOpen() const = 0;
    };

    // Factory function type for creating transports
    using TransportFactory = std::function<ITransport*(const TransportEvents&)>;

    // Default WebSocket transport factory
    ITransport* createWebSocketTransport(const TransportEvents& events);

}