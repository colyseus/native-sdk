#include "colyseus/client.h"
#include <sstream>

namespace NativeSDK {

    Client::Client(const Settings& settings)
        : settings_(settings) {
    }

    Client::~Client() {
    }

    void Client::joinOrCreate(const std::string& roomName, const std::map<std::string, std::string>& options) {
        // TODO: HTTP POST to settings_.getWebRequestEndpoint() + /matchmake/joinOrCreate/{roomName}
    }

    void Client::create(const std::string& roomName, const std::map<std::string, std::string>& options) {
        // TODO: HTTP POST
    }

    void Client::join(const std::string& roomName, const std::map<std::string, std::string>& options) {
        // TODO: HTTP POST
    }

    void Client::joinById(const std::string& roomId, const std::map<std::string, std::string>& options) {
        // TODO: HTTP POST
    }

    void Client::reconnect(const std::string& reconnectionToken) {
        size_t pos = reconnectionToken.find(':');
        if (pos == std::string::npos) {
            throw std::runtime_error("Invalid reconnection token format");
        }

        std::string roomId = reconnectionToken.substr(0, pos);
        std::string token = reconnectionToken.substr(pos + 1);

        // TODO: HTTP POST
    }

    std::string Client::buildRoomEndpoint(const SeatReservation::RoomData& room, const std::map<std::string, std::string>& options) {
        // Use settings_.getWebSocketEndpoint() as base
        std::string base = settings_.getWebSocketEndpoint();

        std::stringstream ss;
        ss << base << "/" << room.processId << "/" << room.roomId;

        if (!options.empty()) {
            ss << "?";
            bool first = true;
            for (const auto& [key, value] : options) {
                if (!first) ss << "&";
                ss << key << "=" << value;
                first = false;
            }
        }

        return ss.str();
    }

}