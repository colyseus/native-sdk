#include "colyseus/client.h"
#include <sstream>

#include "colyseus/client.h"
#include <sstream>

namespace Colyseus {

Client::Client(const Settings& settings)
    : settings_(settings),
      transportFactory_(createWebSocketTransport) {
    http_ = std::make_shared<HTTP>(&settings_);
}

Client::Client(const Settings& settings, TransportFactory transportFactory)
    : settings_(settings),
      transportFactory_(transportFactory) {
    http_ = std::make_shared<HTTP>(&settings_);
}

Client::~Client() {
}

void Client::joinOrCreate(const std::string& roomName,
                          const std::map<std::string, std::string>& options,
                          std::function<void(Room*)> onSuccess,
                          std::function<void(int, const std::string&)> onError) {
    createMatchMakeRequest("joinOrCreate", roomName, options, onSuccess, onError);
}

void Client::create(const std::string& roomName,
                    const std::map<std::string, std::string>& options,
                    std::function<void(Room*)> onSuccess,
                    std::function<void(int, const std::string&)> onError) {
    createMatchMakeRequest("create", roomName, options, onSuccess, onError);
}

void Client::join(const std::string& roomName,
                  const std::map<std::string, std::string>& options,
                  std::function<void(Room*)> onSuccess,
                  std::function<void(int, const std::string&)> onError) {
    createMatchMakeRequest("join", roomName, options, onSuccess, onError);
}

void Client::joinById(const std::string& roomId,
                      const std::map<std::string, std::string>& options,
                      std::function<void(Room*)> onSuccess,
                      std::function<void(int, const std::string&)> onError) {
    createMatchMakeRequest("joinById", roomId, options, onSuccess, onError);
}

void Client::reconnect(const std::string& reconnectionToken,
                       std::function<void(Room*)> onSuccess,
                       std::function<void(int, const std::string&)> onError) {
    size_t pos = reconnectionToken.find(':');
    if (pos == std::string::npos) {
        onError(-1, "Invalid reconnection token format");
        return;
    }

    std::string roomId = reconnectionToken.substr(0, pos);
    std::string token = reconnectionToken.substr(pos + 1);

    std::map<std::string, std::string> options;
    options["reconnectionToken"] = token;

    createMatchMakeRequest("reconnect", roomId, options, onSuccess, onError);
}

std::shared_ptr<HTTP> Client::getHTTP() {
    return http_;
}

void Client::createMatchMakeRequest(const std::string& method,
                                    const std::string& roomName,
                                    const std::map<std::string, std::string>& options,
                                    std::function<void(Room*)> onSuccess,
                                    std::function<void(int, const std::string&)> onError) {
    // TODO: Convert options to JSON
    std::string jsonBody = "{}"; // Placeholder

    std::string path = "matchmake/" + method + "/" + roomName;

    http_->post(path, jsonBody,
        [this, onSuccess, onError](const HTTPResponse& response) {
            // TODO: Parse JSON response to SeatReservation
            SeatReservation reservation;
            // Parse response.body into reservation

            consumeSeatReservation(reservation, onSuccess, onError);
        },
        [onError](const HTTPException& error) {
            onError(error.getCode(), error.what());
        }
    );
}

void Client::consumeSeatReservation(const SeatReservation& reservation,
                                    std::function<void(Room*)> onSuccess,
                                    std::function<void(int, const std::string&)> onError) {
    // TODO: Create Room and connect
    // Room* room = new Room(reservation);
    // room->connect(buildRoomEndpoint(...));
}

std::string Client::buildRoomEndpoint(const SeatReservation::RoomData& room,
                                      const std::map<std::string, std::string>& options) {
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

}}