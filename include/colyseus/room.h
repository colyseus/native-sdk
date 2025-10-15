#pragma once
#include "colyseus/transport.h"
#include "colyseus/protocol.h"
#include <string>
#include <map>
#include <functional>
#include <memory>
#include <vector>

namespace Colyseus {

template<typename T>
class Signal {
public:
    void invoke(T... args) {
        if (callback_) callback_(args...);
    }
    
    void connect(std::function<void(T...)> callback) {
        callback_ = callback;
    }
    
    void clear() {
        callback_ = nullptr;
    }
    
private:
    std::function<void(T...)> callback_;
};

class Room {
public:
    Room(const std::string& name, TransportFactory transportFactory);
    ~Room();
    
    // Connection
    void connect(const std::string& endpoint,
                 std::function<void()> onSuccess,
                 std::function<void(int, const std::string&)> onError);
    
    void leave(bool consented = true);
    
    // Messaging
    void send(const std::string& type, const std::vector<uint8_t>& message = {});
    void send(int type, const std::vector<uint8_t>& message = {});
    
    void onMessage(const std::string& type, std::function<void(const std::vector<uint8_t>&)> callback);
    void onMessage(int type, std::function<void(const std::vector<uint8_t>&)> callback);
    void onMessageAny(std::function<void(const std::string&, const std::vector<uint8_t>&)> callback);
    
    // Signals/Events
    Signal<> onJoin;
    Signal<int, std::string> onError;
    Signal<int, std::string> onLeave;
    Signal<> onStateChange;
    
    // Getters/Setters
    std::string getRoomId() const { return roomId_; }
    void setRoomId(const std::string& roomId) { roomId_ = roomId; }
    
    std::string getSessionId() const { return sessionId_; }
    void setSessionId(const std::string& sessionId) { sessionId_ = sessionId; }
    
    std::string getName() const { return name_; }
    
    bool hasJoined() const { return hasJoined_; }
    
private:
    std::string name_;
    std::string roomId_;
    std::string sessionId_;
    std::string reconnectionToken_;
    
    bool hasJoined_;
    
    ITransport* transport_;
    TransportFactory transportFactory_;
    
    // Message handlers
    std::map<std::string, std::function<void(const std::vector<uint8_t>&)>> messageHandlers_;
    std::function<void(const std::string&, const std::vector<uint8_t>&)> anyMessageHandler_;
    
    // Internal methods
    void onMessageCallback(const std::vector<uint8_t>& data);
    void dispatchMessage(const std::string& type, const std::vector<uint8_t>& message);
    std::string getMessageHandlerKey(const std::string& type);
    std::string getMessageHandlerKey(int type);
    
    void removeAllListeners();
};

} // namespace Colyseus