#include "colyseus/websocket_transport.h"
#include <wslay/wslay.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <cstring>
#include <random>
#include <sstream>
#include <algorithm>
#include <iostream>

namespace {
    std::string createAcceptKey(const std::string& clientKey) {
    SHA1 sha;
    sha.update(clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"); // magic number here is WebSocket protocol GUID
    auto digest = sha.final();
    std::string hashStr(digest.begin(), digest.end());
    return Colyseus::Utils::base64Encode(hashStr);
}

    std::string getRandomBytes(size_t length) {
        std::random_device rd;
        std::mt19937_64 gen(rd());
        std::string result;
        result.resize(length);

        for (size_t i = 0; i < length; i++) {
            result[i] = static_cast<char>(gen() % 256);
        }

        return result;
    }
}

namespace Colyseus {

// wslay callbacks
void WebSocketTransport::onMsgRecvCallback(
    wslay_event_context_ptr /*ctx*/,
    const struct wslay_event_on_msg_recv_arg* arg,
    void* user_data) {

    auto ws = static_cast<WebSocketTransport*>(user_data);

    if (wslay_is_ctrl_frame(arg->opcode)) {
        if (arg->opcode == WSLAY_CONNECTION_CLOSE) {
            ws->state_ = WebSocketState::REMOTE_DISCONNECT;
        }
    } else {
        ws->handleMessageReceived(arg->msg, arg->msg_length, arg->opcode);
    }
}

ssize_t WebSocketTransport::recvCallback(
    wslay_event_context_ptr ctx,
    uint8_t* data,
    size_t len,
    int /*flags*/,
    void* user_data) {

    auto ws = static_cast<WebSocketTransport*>(user_data);

    // If buffer has data from handshake, use it first
    if (ws->bufferOffset_ < ws->buffer_.size()) {
        size_t available = ws->buffer_.size() - ws->bufferOffset_;
        size_t toCopy = std::min(len, available);
        std::memcpy(data, ws->buffer_.data() + ws->bufferOffset_, toCopy);
        ws->bufferOffset_ += toCopy;
        return toCopy;
    }

    int wouldBlock = 0;
    ssize_t ret = ws->socketRecv(data, len, &wouldBlock);

    if (wouldBlock) {
        wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
        return -1;
    } else if (ret < 0) {
        wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
        return -1;
    }

    return ret;
}

ssize_t WebSocketTransport::sendCallback(
    wslay_event_context_ptr ctx,
    const uint8_t* data,
    size_t len,
    int /*flags*/,
    void* user_data) {

    auto ws = static_cast<WebSocketTransport*>(user_data);

    int wouldBlock = 0;
    ssize_t ret = ws->socketSend(data, len, &wouldBlock);

    if (ret < 0) {
        wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
        return -1;
    } else if (wouldBlock) {
        wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
        return 0;
    }

    return ret;
}

int WebSocketTransport::genmaskCallback(
    wslay_event_context_ptr /*ctx*/,
    uint8_t* buf,
    size_t len,
    void* /*user_data*/) {

    static std::mt19937 rng(std::random_device{}());

    for (size_t offset = 0; offset < len; offset += sizeof(decltype(rng)::result_type)) {
        auto rnd = rng();
        std::memcpy(buf + offset, &rnd, std::min(len - offset, sizeof(rnd)));
    }

    return 0;
}

// Constructor/Destructor
WebSocketTransport::WebSocketTransport(const TransportEvents& events)
    : events_(events),
      state_(WebSocketState::DISCONNECTED),
      running_(false),
      bufferOffset_(0),
      ctx_(nullptr),
      socket_(-1) {
}

WebSocketTransport::~WebSocketTransport() {
    close();
}

// ITransport interface implementation
void WebSocketTransport::connect(const std::string& url, const std::map<std::string, std::string>& options) {
    if (state_ != WebSocketState::DISCONNECTED) {
        return;
    }

    url_ = url;

    if (!connectInit()) {
        if (events_.onError) {
            events_.onError("Failed to initialize connection");
        }
        return;
    }

    state_ = WebSocketState::CONNECTING;
    running_ = true;

    // Start tick thread
    tickThread_ = std::make_unique<std::thread>(&WebSocketTransport::tickLoop, this);
}

void WebSocketTransport::send(const std::vector<uint8_t>& data) {
    if (state_ != WebSocketState::CONNECTED) {
        return;
    }

    struct wslay_event_msg msg;
    msg.opcode = WSLAY_BINARY_FRAME;
    msg.msg = data.data();
    msg.msg_length = data.size();

    int ret = wslay_event_queue_msg(ctx_, &msg);
    if (ret != 0) {
        std::cerr << "Failed to queue message" << std::endl;
    }
}

void WebSocketTransport::sendUnreliable(const std::vector<uint8_t>& data) {
    std::cerr << "WebSocket does not support unreliable messages" << std::endl;
}

void WebSocketTransport::close(int code, const std::string& reason) {
    if (state_ == WebSocketState::DISCONNECTED) {
        return;
    }

    running_ = false;

    if (ctx_ && state_ == WebSocketState::CONNECTED) {
        wslay_event_queue_close(ctx_, code, reinterpret_cast<const uint8_t*>(reason.c_str()), reason.length());
        wslay_event_send(ctx_);
    }

    socketClose();
    cleanupWslay();

    if (tickThread_ && tickThread_->joinable()) {
        tickThread_->join();
    }

    state_ = WebSocketState::DISCONNECTED;

    if (events_.onClose) {
        events_.onClose(code, reason);
    }
}

bool WebSocketTransport::isOpen() const {
    return state_ == WebSocketState::CONNECTED;
}

// Internal methods
void WebSocketTransport::tickLoop() {
    while (running_) {
        tickOnce();
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}

void WebSocketTransport::tickOnce() {
    if (state_ == WebSocketState::CONNECTED) {
        int ret = wslay_event_recv(ctx_);
        if (ret != 0) {
            close(1006, "Receive error");
            return;
        }

        ret = wslay_event_send(ctx_);
        if (ret != 0) {
            close(1006, "Send error");
            return;
        }

        return;
    }

    if (state_ == WebSocketState::REMOTE_DISCONNECT) {
        uint16_t code = wslay_event_get_status_code_received(ctx_);
        close(code, "Remote disconnect");
        return;
    }

    // State machine for connection
    bool success = true;

    if (state_ == WebSocketState::CONNECTING) {
        if (connectTick()) {
            state_ = WebSocketState::HANDSHAKE_SENDING;
            httpHandshakeInit();
        } else {
            return; // Still connecting
        }
    }

    if (state_ == WebSocketState::HANDSHAKE_SENDING) {
        if (httpHandshakeSend()) {
            state_ = WebSocketState::HANDSHAKE_RECEIVING;
        } else {
            return;
        }
    }

    if (state_ == WebSocketState::HANDSHAKE_RECEIVING) {
        if (httpHandshakeReceive()) {
            state_ = WebSocketState::CONNECTED;

            // Initialize wslay
            struct wslay_event_callbacks callbacks = {
                recvCallback,
                sendCallback,
                genmaskCallback,
                nullptr,
                nullptr,
                nullptr,
                onMsgRecvCallback
            };

            wslay_event_context_client_init(&ctx_, &callbacks, this);

            if (events_.onOpen) {
                events_.onOpen();
            }
        }
    }
}

void WebSocketTransport::handleMessageReceived(const uint8_t* data, size_t length, uint8_t opcode) {
    if (events_.onMessage) {
        std::vector<uint8_t> message(data, data + length);
        events_.onMessage(message);
    }
}

bool WebSocketTransport::connectInit() {
    auto parsedURL = Utils::parseURL(url_);
    if (!parsedURL) {
        return false;
    }

    std::string host = parsedURL->host;
    int port = parsedURL->port.value_or(
        parsedURL->scheme == "wss" ? 443 : 80
    );

    // Store for handshake
    urlHost_ = host;
    urlPort_ = port;
    urlPath_ = "/" + parsedURL->pathAndArgs;

    // Create socket
    socket_ = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_ < 0) {
        return false;
    }

    // Set non-blocking
    int flags = fcntl(socket_, F_GETFL, 0);
    fcntl(socket_, F_SETFL, flags | O_NONBLOCK);

    // Resolve hostname
    struct hostent* server = gethostbyname(host.c_str());
    if (server == nullptr) {
        ::close(socket_);
        socket_ = -1;
        return false;
    }

    // Connect
    struct sockaddr_in server_addr;
    std::memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(port);
    std::memcpy(&server_addr.sin_addr.s_addr, server->h_addr, server->h_length);

    ::connect(socket_, (struct sockaddr*)&server_addr, sizeof(server_addr));

    return true;
}

bool WebSocketTransport::connectTick() {
    // Check if connection is established
    fd_set write_fds;
    FD_ZERO(&write_fds);
    FD_SET(socket_, &write_fds);

    struct timeval tv = {0, 0};
    int ret = select(socket_ + 1, nullptr, &write_fds, nullptr, &tv);

    if (ret > 0 && FD_ISSET(socket_, &write_fds)) {
        int error = 0;
        socklen_t len = sizeof(error);
        getsockopt(socket_, SOL_SOCKET, SO_ERROR, &error, &len);
        return error == 0;
    }

    return false;
}

bool WebSocketTransport::httpHandshakeInit() {
    clientKey_ = base64Encode(getRandomBytes(16));

    std::ostringstream request;
    request << "GET / HTTP/1.1\r\n"
            << "Host: localhost:2567\r\n"
            << "Upgrade: websocket\r\n"
            << "Connection: Upgrade\r\n"
            << "Sec-WebSocket-Version: 13\r\n"
            << "Sec-WebSocket-Key: " << clientKey_ << "\r\n"
            << "\r\n";

    buffer_ = request.str();
    bufferOffset_ = 0;

    return true;
}

bool WebSocketTransport::httpHandshakeSend() {
    while (bufferOffset_ < buffer_.size()) {
        int wouldBlock = 0;
        ssize_t sent = socketSend(
            reinterpret_cast<const uint8_t*>(buffer_.data() + bufferOffset_),
            buffer_.size() - bufferOffset_,
            &wouldBlock
        );

        if (sent < 0) {
            return false;
        }

        if (wouldBlock) {
            return false;
        }

        bufferOffset_ += sent;
    }

    buffer_.clear();
    bufferOffset_ = 0;
    return true;
}

bool WebSocketTransport::httpHandshakeReceive() {
    char buf[1024];
    int wouldBlock = 0;

    ssize_t received = socketRecv(reinterpret_cast<uint8_t*>(buf), sizeof(buf), &wouldBlock);

    if (received > 0) {
        buffer_.append(buf, received);
    }

    if (wouldBlock || buffer_.find("\r\n\r\n") == std::string::npos) {
        return false;
    }

    // Extract Sec-WebSocket-Accept header using regex
    std::regex acceptRegex("Sec-WebSocket-Accept: ([^\r\n]+)");
    std::smatch match;

    if (!std::regex_search(buffer_, match, acceptRegex)) {
        return false;
    }

    std::string receivedKey = match[1].str();
    std::string expectedKey = createAcceptKey(clientKey_);

    if (receivedKey != expectedKey) {
        return false;
    }

    // Remove handshake response, keep any extra data
    size_t endPos = buffer_.find("\r\n\r\n");
    buffer_.erase(0, endPos + 4);
    bufferOffset_ = 0;

    return true;
}

ssize_t WebSocketTransport::socketRecv(uint8_t* data, size_t len, int* wouldBlock) {
    *wouldBlock = 0;

    ssize_t ret = recv(socket_, data, len, 0);

    if (ret < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            *wouldBlock = 1;
            return 0;
        }
        return -1;
    }

    return ret;
}

ssize_t WebSocketTransport::socketSend(const uint8_t* data, size_t len, int* wouldBlock) {
    *wouldBlock = 0;

    ssize_t ret = ::send(socket_, data, len, 0);

    if (ret < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            *wouldBlock = 1;
            return 0;
        }
        return -1;
    }

    return ret;
}

void WebSocketTransport::socketClose() {
    if (socket_ >= 0) {
        ::close(socket_);
        socket_ = -1;
    }
}

void WebSocketTransport::cleanupWslay() {
    if (ctx_) {
        wslay_event_context_free(ctx_);
        ctx_ = nullptr;
    }
}

// Factory function
ITransport* createWebSocketTransport(const TransportEvents& events) {
    return new WebSocketTransport(events);
}

}