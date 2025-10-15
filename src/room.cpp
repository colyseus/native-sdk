#include "colyseus/room.h"
#include "colyseus/protocol.h"
#include <iostream>

namespace Colyseus {

Room::Room(const std::string& name, TransportFactory transportFactory)
    : name_(name),
      hasJoined_(false),
      transport_(nullptr),
      transportFactory_(transportFactory) {
}

Room::~Room() {
    if (transport_) {
        delete transport_;
    }
}

void Room::connect(const std::string& endpoint,
                   std::function<void()> onSuccess,
                   std::function<void(int, const std::string&)> onErrorCallback) {

    TransportEvents events;

    events.onOpen = [this, onSuccess]() {
        // Connection established, wait for JOIN_ROOM message
        // onSuccess will be called when JOIN_ROOM is received
    };

    events.onMessage = [this](const std::vector<uint8_t>& data) {
        onMessageCallback(data);
    };

    events.onClose = [this, onErrorCallback](int code, const std::string& reason) {
        if (!hasJoined_) {
            std::cerr << "Room connection closed unexpectedly: " << reason << std::endl;
            this->onError.invoke(code, reason);
            if (onErrorCallback) {
                onErrorCallback(code, reason);
            }
        } else {
            this->onLeave.invoke(code, reason);
            removeAllListeners();
        }
    };

    events.onError = [this, onErrorCallback](const std::string& error) {
        std::cerr << "Room connection error: " << error << std::endl;
        this->onError.invoke(-1, error);
        if (onErrorCallback) {
            onErrorCallback(-1, error);
        }
    };

    transport_ = transportFactory_(events);
    transport_->connect(endpoint);
}

void Room::leave(bool consented) {
    if (transport_ && transport_->isOpen()) {
        if (consented) {
            std::vector<uint8_t> leaveMsg = { static_cast<uint8_t>(Protocol::LEAVE_ROOM) };
            transport_->send(leaveMsg);
        } else {
            transport_->close();
        }
    } else {
        this->onLeave.invoke(static_cast<int>(CloseCode::CONSENTED), "Already left");
    }
}

void Room::send(const std::string& type, const std::vector<uint8_t>& message) {
    if (!transport_ || !transport_->isOpen()) {
        return;
    }

    std::vector<uint8_t> data;
    data.push_back(static_cast<uint8_t>(Protocol::ROOM_DATA));

    // Encode type as string
    // TODO: Implement proper encoding (msgpack or schema encode)
    for (char c : type) {
        data.push_back(static_cast<uint8_t>(c));
    }

    // Append message
    data.insert(data.end(), message.begin(), message.end());

    transport_->send(data);
}

void Room::send(int type, const std::vector<uint8_t>& message) {
    if (!transport_ || !transport_->isOpen()) {
        return;
    }

    std::vector<uint8_t> data;
    data.push_back(static_cast<uint8_t>(Protocol::ROOM_DATA));

    // Encode type as number
    // TODO: Implement proper encoding
    data.push_back(static_cast<uint8_t>(type));

    // Append message
    data.insert(data.end(), message.begin(), message.end());

    transport_->send(data);
}

void Room::onMessage(const std::string& type, std::function<void(const std::vector<uint8_t>&)> callback) {
    messageHandlers_[getMessageHandlerKey(type)] = callback;
}

void Room::onMessage(int type, std::function<void(const std::vector<uint8_t>&)> callback) {
    messageHandlers_[getMessageHandlerKey(type)] = callback;
}

void Room::onMessageAny(std::function<void(const std::string&, const std::vector<uint8_t>&)> callback) {
    anyMessageHandler_ = callback;
}

void Room::onMessageCallback(const std::vector<uint8_t>& data) {
    if (data.empty()) {
        return;
    }

    Protocol code = static_cast<Protocol>(data[0]);
    size_t offset = 1;

    switch (code) {
        case Protocol::JOIN_ROOM: {
            // TODO: Decode reconnection token and serializer ID
            hasJoined_ = true;
            this->onJoin.invoke();

            // Acknowledge JOIN_ROOM
            std::vector<uint8_t> ack = { static_cast<uint8_t>(Protocol::JOIN_ROOM) };
            transport_->send(ack);
            break;
        }

        case Protocol::ERROR: {
            // TODO: Decode error code and message
            int errorCode = -1;
            std::string message = "Unknown error";
            this->onError.invoke(errorCode, message);
            break;
        }

        case Protocol::LEAVE_ROOM: {
            leave(false);
            break;
        }

        case Protocol::ROOM_STATE: {
            // TODO: Handle full state
            this->onStateChange.invoke();
            break;
        }

        case Protocol::ROOM_STATE_PATCH: {
            // TODO: Handle state patch
            this->onStateChange.invoke();
            break;
        }
        
        case Protocol::ROOM_DATA: {
            // TODO: Decode type and message properly
            std::string type = "unknown";
            std::vector<uint8_t> message(data.begin() + offset, data.end());
            dispatchMessage(type, message);
            break;
        }
        
        case Protocol::ROOM_DATA_BYTES: {
            // TODO: Decode type and bytes
            std::string type = "unknown";
            std::vector<uint8_t> message(data.begin() + offset, data.end());
            dispatchMessage(type, message);
            break;
        }
        
        default:
            std::cerr << "Unknown protocol message: " << static_cast<int>(code) << std::endl;
            break;
    }
}

void Room::dispatchMessage(const std::string& type, const std::vector<uint8_t>& message) {
    std::string key = getMessageHandlerKey(type);
    
    auto it = messageHandlers_.find(key);
    if (it != messageHandlers_.end()) {
        it->second(message);
    } else if (anyMessageHandler_) {
        anyMessageHandler_(type, message);
    } else {
        std::cerr << "No handler for message type: " << type << std::endl;
    }
}

std::string Room::getMessageHandlerKey(const std::string& type) {
    return type;
}

std::string Room::getMessageHandlerKey(int type) {
    return "i" + std::to_string(type);
}

void Room::removeAllListeners() {
    onJoin.clear();
    onError.clear();
    onLeave.clear();
    onStateChange.clear();
    messageHandlers_.clear();
    anyMessageHandler_ = nullptr;
}

} // namespace Colyseus`