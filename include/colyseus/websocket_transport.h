#pragma once
#include "colyseus/transport.h"
#include <memory>
#include <thread>
#include <atomic>
#include <queue>
#include <mutex>

struct wslay_event_context;
typedef struct wslay_event_context* wslay_event_context_ptr;

namespace Colyseus {

enum class WebSocketState {
    DISCONNECTED,
    CONNECTING,
    HANDSHAKE_SENDING,
    HANDSHAKE_RECEIVING,
    CONNECTED,
    REMOTE_DISCONNECT
};

class WebSocketTransport : public ITransport {
public:
    WebSocketTransport(const TransportEvents& events);
    ~WebSocketTransport() override;

    // ITransport interface implementation
    void connect(const std::string& url, const std::map<std::string, std::string>& options = {}) override;
    void send(const std::vector<uint8_t>& data) override;
    void sendUnreliable(const std::vector<uint8_t>& data) override;
    void close(int code = 1000, const std::string& reason = "") override;
    bool isOpen() const override;

private:
    TransportEvents events_;
    std::atomic<WebSocketState> state_;
    std::atomic<bool> running_;

    std::string url_;
    std::string clientKey_;
    std::string buffer_;
    size_t bufferOffset_;

    wslay_event_context_ptr ctx_;
    int socket_;

    std::unique_ptr<std::thread> tickThread_;
    std::queue<std::vector<uint8_t>> sendQueue_;
    std::mutex queueMutex_;

    // Internal tick loop (runs in thread)
    void tickLoop();
    void tickOnce();

    // wslay callbacks (static, call into instance methods)
    static void onMsgRecvCallback(wslay_event_context_ptr ctx, const struct wslay_event_on_msg_recv_arg* arg, void* user_data);
    static ssize_t recvCallback(wslay_event_context_ptr ctx, uint8_t* data, size_t len, int flags, void* user_data);
    static ssize_t sendCallback(wslay_event_context_ptr ctx, const uint8_t* data, size_t len, int flags, void* user_data);
    static int genmaskCallback(wslay_event_context_ptr ctx, uint8_t* buf, size_t len, void* user_data);

    // Instance methods for callbacks
    void handleMessageReceived(const uint8_t* data, size_t length, uint8_t opcode);
    ssize_t socketRecv(uint8_t* data, size_t len, int* wouldBlock);
    ssize_t socketSend(const uint8_t* data, size_t len, int* wouldBlock);

    // Connection state machine
    bool connectInit();
    bool connectTick();
    bool httpHandshakeInit();
    bool httpHandshakeSend();
    bool httpHandshakeReceive();

    void socketClose();
    void cleanupWslay();
};

}