#pragma once
#include <cstdint>
#include <string>

namespace Colyseus {

    // Protocol message types
    enum class Protocol : uint8_t {
        // Room-related (10~19)
        HANDSHAKE = 9,
        JOIN_ROOM = 10,
        ERROR = 11,
        LEAVE_ROOM = 12,
        ROOM_DATA = 13,
        ROOM_STATE = 14,
        ROOM_STATE_PATCH = 15,
        ROOM_DATA_SCHEMA = 16,
        ROOM_DATA_BYTES = 17,
    };

    // Error codes
    enum class ErrorCode : uint16_t {
        MATCHMAKE_NO_HANDLER = 4210,
        MATCHMAKE_INVALID_CRITERIA = 4211,
        MATCHMAKE_INVALID_ROOM_ID = 4212,
        MATCHMAKE_UNHANDLED = 4213,
        MATCHMAKE_EXPIRED = 4214,
        AUTH_FAILED = 4215,
        APPLICATION_ERROR = 4216,
    };

    struct RoomAvailable {
        std::string roomId;
        std::string name;
        std::string processId;
        std::string publicAddress;
        int clients;
        int maxClients;
        // metadata as JSON or map
    };

    struct SeatReservation {
        RoomAvailable room;
        std::string sessionId;
        std::string reconnectionToken;
        bool devMode;
        std::string protocol;
    };

}