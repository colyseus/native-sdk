#pragma once
#include "colyseus/settings.h"
#include "colyseus/transport.h"
#include "colyseus/protocol.h"
#include <string>
#include <map>
#include <functional>
#include <memory>

namespace Colyseus {

class Room;
class HTTP;

class Client {
public:
    Client(const Settings& settings);
    Client(const Settings& settings, TransportFactory transportFactory);
    ~Client();

    // Matchmaking with callbacks
    void joinOrCreate(const std::string& roomName,
                      const std::map<std::string, std::string>& options,
                      std::function<void(Room*)> onSuccess,
                      std::function<void(int, const std::string&)> onError);

    void create(const std::string& roomName,
                const std::map<std::string, std::string>& options,
                std::function<void(Room*)> onSuccess,
                std::function<void(int, const std::string&)> onError);

    void join(const std::string& roomName,
              const std::map<std::string, std::string>& options,
              std::function<void(Room*)> onSuccess,
              std::function<void(int, const std::string&)> onError);

    void joinById(const std::string& roomId,
                  const std::map<std::string, std::string>& options,
                  std::function<void(Room*)> onSuccess,
                  std::function<void(int, const std::string&)> onError);

    void reconnect(const std::string& reconnectionToken,
                   std::function<void(Room*)> onSuccess,
                   std::function<void(int, const std::string&)> onError);

    std::shared_ptr<HTTP> getHTTP();

private:
    Settings settings_;
    TransportFactory transportFactory_;
    std::shared_ptr<HTTP> http_;

    void createMatchMakeRequest(const std::string& method,
                                const std::string& roomName,
                                const std::map<std::string, std::string>& options,
                                std::function<void(Room*)> onSuccess,
                                std::function<void(int, const std::string&)> onError);

    void consumeSeatReservation(const SeatReservation& reservation,
                                std::function<void(Room*)> onSuccess,
                                std::function<void(int, const std::string&)> onError);

    std::string buildRoomEndpoint(const SeatReservation::RoomData& room,
                                  const std::map<std::string, std::string>& options);
};

}