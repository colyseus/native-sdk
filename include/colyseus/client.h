//
// Created by Bharath Sharama on 14/10/25.
//

#pragma once
#include "colyseus/settings.h"
#include <string>
#include <map>
#include <functional>
#include <memory>

namespace NativeSDK {

    class Room;
    class HTTP;
    class Auth;

    struct SeatReservation {
        std::string sessionId;
        std::string reconnectionToken;
        struct RoomData {
            std::string name;
            std::string roomId;
            std::string processId;
            std::string publicAddress;
        } room;
    };

    class Client {
    public:
        // Default: uses WebSocketTransport
        Client(const Settings& settings);
        // Custom transport factory
        Client(const Settings& settings, TransportFactory transportFactory);
        ~Client();

        // Matchmaking
        void joinOrCreate(const std::string& roomName, const std::map<std::string, std::string>& options = {});
        void create(const std::string& roomName, const std::map<std::string, std::string>& options = {});
        void join(const std::string& roomName, const std::map<std::string, std::string>& options = {});
        void joinById(const std::string& roomId, const std::map<std::string, std::string>& options = {});
        void reconnect(const std::string& reconnectionToken);

        // Auth
        std::shared_ptr<Auth> getAuth();

    private:
        Settings settings_;
        TransportFactory transportFactory_;
        std::shared_ptr<HTTP> http_;
        std::shared_ptr<Auth> auth_;

        std::string buildEndpoint(const SeatReservation::RoomData& room, const std::map<std::string, std::string>& options);
        std::string getHttpEndpoint(const std::string& segments = "");
        std::string getEndpointPort();

        void consumeSeatReservation(const SeatReservation& reservation);
    };

}