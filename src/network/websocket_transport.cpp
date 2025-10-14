//
// Created by Bharath Sharama on 14/10/25.
//
#include "colyseus/websocket_transport.h"
#include <wslay/wslay.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <cstring>
#include <iostream>

namespace Colyseus {

WebSocketTransport::WebSocketTransport(const TransportEvents& events)
    : events_(events),
      isOpen_(false),
      running_(false),
      wslayCtx_(nullptr),
      socket_(-1) {
}

WebSocketTransport::~WebSocketTransport() {
    close();
}

void WebSocketTransport::connect(const std::string& url, const std::map<std::string, std::string>& options) {
    if (running_) {
        return;
    }

    url_ = url;
    options_ = options;
    running_ = true;

    connectionThread_ = std::make_unique<std::thread>(&WebSocketTransport::connectionLoop, this);
}

void WebSocketTransport::send(const std::vector<uint8_t>& data) {
    if (!isOpen_) {
        return;
    }

    std::lock_guard<std::mutex> lock(queueMutex_);
    sendQueue_.push(data);
}

void WebSocketTransport::sendUnreliable(const std::vector<uint8_t>& data) {
    // WebSocket doesn't support unreliable, log warning
    std::cerr << "WebSocketTransport: unreliable messages not supported" << std::endl;
}

void WebSocketTransport::close(int code, const std::string& reason) {
    if (!running_) {
        return;
    }

    running_ = false;
    isOpen_ = false;

    if (wslayCtx_) {
        // TODO: Send close frame via wslay
        wslay_event_context_free((wslay_event_context_ptr)wslayCtx_);
        wslayCtx_ = nullptr;
    }

    if (socket_ >= 0) {
        ::close(socket_);
        socket_ = -1;
    }

    if (connectionThread_ && connectionThread_->joinable()) {
        connectionThread_->join();
    }

    if (events_.onClose) {
        events_.onClose(code, reason);
    }
}

bool WebSocketTransport::isOpen() const {
    return isOpen_;
}

void WebSocketTransport::connectionLoop() {
    // TODO: Full implementation
    // 1. Parse URL
    // 2. Create socket
    // 3. Connect
    // 4. Perform WebSocket handshake
    // 5. Setup wslay
    // 6. Event loop

    if (!performHandshake()) {
        if (events_.onError) {
            events_.onError("Failed to connect");
        }
        running_ = false;
        return;
    }

    isOpen_ = true;

    if (events_.onOpen) {
        events_.onOpen();
    }

    while (running_) {
        processEvents();
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}

bool WebSocketTransport::performHandshake() {
    // TODO: Implement WebSocket handshake
    // Parse URL, create socket, send HTTP upgrade request
    return false;
}

void WebSocketTransport::processEvents() {
    // TODO: Use wslay_event_recv/send
    // Process incoming messages
    // Send queued messages
}

ITransport* createWebSocketTransport(const TransportEvents& events) {
    return new WebSocketTransport(events);
}

}