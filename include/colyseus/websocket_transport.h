#pragma once
#include "colyseus/transport.h"
#include <memory>
#include <thread>
#include <atomic>
#include <queue>
#include <mutex>

namespace Colyseus {

    class WebSocketTransport : public ITransport {
    public:
        WebSocketTransport(const TransportEvents& events);
        ~WebSocketTransport() override;

        void connect(const std::string& url, const std::map<std::string, std::string>& options = {}) override;
        void send(const std::vector<uint8_t>& data) override;
        void sendUnreliable(const std::vector<uint8_t>& data) override;
        void close(int code = 1000, const std::string& reason = "") override;
        bool isOpen() const override;

    private:
        TransportEvents events_;
        std::atomic<bool> isOpen_;
        std::atomic<bool> running_;

        std::string url_;
        std::map<std::string, std::string> options_;

        std::unique_ptr<std::thread> connectionThread_;
        std::queue<std::vector<uint8_t>> sendQueue_;
        std::mutex queueMutex_;

        void* wslayCtx_; // wslay_event_context_ptr
        int socket_;

        void connectionLoop();
        bool performHandshake();
        void processEvents();
    };

}